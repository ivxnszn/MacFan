#!/bin/zsh
# Safely restore Auto, unload the helper, and remove the private installation.
set -euo pipefail

PURGE_HISTORY=0
for argument in "$@"; do
  case "$argument" in
    --purge-history) PURGE_HISTORY=1 ;;
    --help)
      print "Usage: zsh Scripts/uninstall-local.sh [--purge-history]"
      exit 0
      ;;
    *) print -u2 "Unknown option: $argument"; exit 2 ;;
  esac
done

if [[ "$EUID" -eq 0 ]]; then
  print -u2 "Run this script as your normal user, not with sudo."
  exit 1
fi

/usr/bin/osascript -e 'tell application id "local.macfan" to quit' >/dev/null 2>&1 || true
/usr/bin/sudo -v

HELPER="/Library/PrivilegedHelperTools/local.macfan.helper"
PLIST="/Library/LaunchDaemons/local.macfan.helper.plist"
if [[ -x "$HELPER" ]]; then
  if ! /usr/bin/sudo "$HELPER" --restore-system; then
    print -u2 "Auto restoration could not be confirmed. The helper is being kept in place for recovery."
    exit 1
  fi
elif /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
  print -u2 "The helper job is loaded but its recovery executable is missing. Files were not removed."
  exit 1
fi
if /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
  /usr/bin/sudo /bin/launchctl kill SIGTERM system/local.macfan.helper >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/sudo /bin/launchctl bootout system/local.macfan.helper >/dev/null 2>&1 || true
  if /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
    print -u2 "The helper is still loaded. Its recovery files were not removed."
    exit 1
  fi
fi
/usr/bin/sudo /bin/rm -f "$HELPER" "$PLIST"
/usr/bin/sudo /bin/rm -f "/Library/Application Support/MacFan/helper-config.plist"
/bin/rm -rf "${MACFAN_INSTALL_DIR:-/Applications}/MacFan.app"

if [[ "$PURGE_HISTORY" -eq 1 ]]; then
  /bin/rm -rf "$HOME/Library/Application Support/MacFan"
fi
print "MacFan and its helper were removed. macOS Auto fan control was requested before unload."
