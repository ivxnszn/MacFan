#!/bin/zsh
# Read-only helper/install diagnostics. This script never changes a fan target.
set -euo pipefail

HELPER="/Library/PrivilegedHelperTools/local.macfan.helper"
PLIST="/Library/LaunchDaemons/local.macfan.helper.plist"
CONFIG="/Library/Application Support/MacFan/helper-config.plist"

for path in "$HELPER" "$PLIST" "$CONFIG"; do
  if [[ -e "$path" ]]; then
    /bin/ls -ld "$path"
  else
    print "Missing: $path"
  fi
done

if /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
  print "LaunchDaemon: loaded"
else
  print "LaunchDaemon: not loaded"
fi

if [[ -x "$HELPER" ]]; then
  print "Read-only hardware check:"
  /usr/bin/sudo "$HELPER" --check
fi
