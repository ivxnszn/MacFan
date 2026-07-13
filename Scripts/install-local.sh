#!/bin/zsh
# Build and install MacFan plus its private, manually installed root helper.
# Run this script as your normal administrator account; it invokes sudo only
# for root-owned helper/launchd files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/DerivedData"
INSTALL_DIR="${MACFAN_INSTALL_DIR:-/Applications}"
CONFIGURATION="${CONFIGURATION:-Release}"
INSTALL_HELPER=1
REPLACE_MACS_FAN_CONTROL=0
OPEN_APP=1

for argument in "$@"; do
  case "$argument" in
    --app-only) INSTALL_HELPER=0 ;;
    --replace-macs-fan-control) REPLACE_MACS_FAN_CONTROL=1 ;;
    --no-open) OPEN_APP=0 ;;
    --help)
      print "Usage: zsh Scripts/install-local.sh [--replace-macs-fan-control] [--app-only] [--no-open]"
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $argument"
      exit 2
      ;;
  esac
done

if [[ "$EUID" -eq 0 ]]; then
  print -u2 "Run this script as your normal Mac user, not with sudo. It will ask once when root access is needed."
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "XcodeGen is required (for example: brew install xcodegen)."
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  print -u2 "Xcode command-line tools are required. Open Xcode once and try again."
  exit 1
fi

MFC_HELPER="/Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite"
MFC_PLIST="/Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist"
MFC_APP="/Applications/Macs Fan Control.app"
if [[ "$INSTALL_HELPER" -eq 1 && ( -e "$MFC_HELPER" || -e "$MFC_PLIST" || -e "$MFC_APP" ) && "$REPLACE_MACS_FAN_CONTROL" -ne 1 ]]; then
  print -u2 "Macs Fan Control is still installed. Two fan controllers must not run together."
  print -u2 "Re-run with --replace-macs-fan-control to back it up, unload it, and install MacFan's helper."
  exit 1
fi

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project MacFan.xcodeproj \
  -scheme MacFan \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacFan.app"
HELPER="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacFanHelper"
if [[ ! -d "$APP" ]]; then
  print -u2 "MacFan.app was not produced at $APP"
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"; then
  print -u2 "The built app failed code-signature verification."
  exit 1
fi
if ! /usr/bin/file "$APP/Contents/MacOS/MacFan" | /usr/bin/grep -q 'arm64'; then
  print -u2 "The built app is not arm64-native."
  exit 1
fi
if [[ "$INSTALL_HELPER" -eq 1 ]]; then
  if [[ ! -x "$HELPER" ]]; then
    print -u2 "MacFanHelper was not produced at $HELPER"
    exit 1
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$HELPER"
  /usr/bin/file "$HELPER" | /usr/bin/grep -q 'arm64'
fi

INSTALL_REQUIRES_ROOT=0
if [[ "$INSTALL_DIR" == "/Applications" || "$INSTALL_DIR" == /Applications/* ]]; then
  INSTALL_REQUIRES_ROOT=1
  print "Administrator access is required once to install MacFan in /Applications."
  /usr/bin/sudo -v
fi
if [[ "$INSTALL_REQUIRES_ROOT" -eq 1 ]]; then
  /usr/bin/sudo /bin/mkdir -p "$INSTALL_DIR"
else
  /bin/mkdir -p "$INSTALL_DIR"
fi
if [[ -d "$INSTALL_DIR/MacFan.app" ]]; then
  /usr/bin/osascript -e 'tell application id "local.macfan" to quit' >/dev/null 2>&1 || true
  # Keep rollback copies out of Applications and remove the .app suffix so
  # Spotlight/LaunchServices expose exactly one installable MacFan app.
  BACKUP_DIR="$HOME/Library/Application Support/MacFan/Backups"
  /bin/mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/MacFan-backup-$(/bin/date +%Y%m%d-%H%M%S)"
  if [[ "$INSTALL_REQUIRES_ROOT" -eq 1 ]]; then
    /usr/bin/sudo /bin/mv "$INSTALL_DIR/MacFan.app" "$BACKUP"
    /usr/bin/sudo /usr/sbin/chown -R "$USER":staff "$BACKUP"
  else
    /bin/mv "$INSTALL_DIR/MacFan.app" "$BACKUP"
  fi
  print "Previous MacFan.app preserved outside Applications at $BACKUP"
fi
if [[ "$INSTALL_REQUIRES_ROOT" -eq 1 ]]; then
  /usr/bin/sudo /usr/bin/ditto --rsrc --extattr "$APP" "$INSTALL_DIR/MacFan.app"
  /usr/bin/sudo /usr/sbin/chown -R "$USER":staff "$INSTALL_DIR/MacFan.app"
else
  /usr/bin/ditto --rsrc --extattr "$APP" "$INSTALL_DIR/MacFan.app"
fi
print "Installed app at $INSTALL_DIR/MacFan.app"

# Keep one canonical binary. A stale per-user copy can be opened from Finder
# and will not match the helper's pinned path/hash.
if [[ "$INSTALL_DIR" == "/Applications" && -d "$HOME/Applications/MacFan.app" ]]; then
  STALE_BACKUP="$HOME/Library/Application Support/MacFan/Backups/MacFan-user-backup-$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mkdir -p "${STALE_BACKUP:h}"
  /bin/mv "$HOME/Applications/MacFan.app" "$STALE_BACKUP"
  print "Stale per-user copy preserved outside Applications at $STALE_BACKUP"
fi

if [[ "$INSTALL_HELPER" -eq 1 ]]; then
  # The /Applications install path already authenticated above. Reuse that
  # sudo timestamp instead of prompting a second time in a hidden Terminal.

  if [[ "$REPLACE_MACS_FAN_CONTROL" -eq 1 && ( -e "$MFC_HELPER" || -e "$MFC_PLIST" || -e "$MFC_APP" ) ]]; then
    /usr/bin/osascript -e 'tell application "Macs Fan Control" to quit' >/dev/null 2>&1 || true
    if [[ -e "$MFC_PLIST" ]]; then
      /usr/bin/sudo /bin/launchctl bootout system "$MFC_PLIST" >/dev/null 2>&1 || true
    fi
    /usr/bin/sudo /bin/launchctl bootout system/com.crystalidea.macsfancontrol.smcwrite >/dev/null 2>&1 || true
    if /usr/bin/sudo /bin/launchctl print system/com.crystalidea.macsfancontrol.smcwrite >/dev/null 2>&1; then
      print -u2 "Macs Fan Control's daemon is still loaded. Nothing was moved; restart the Mac and try again."
      exit 1
    fi
    MFC_BACKUP="/Library/Application Support/MacFan/Backups/MacsFanControl-$(/bin/date +%Y%m%d-%H%M%S)"
    /usr/bin/sudo /bin/mkdir -p "$MFC_BACKUP"
    [[ ! -e "$MFC_HELPER" ]] || /usr/bin/sudo /bin/mv "$MFC_HELPER" "$MFC_BACKUP/"
    [[ ! -e "$MFC_PLIST" ]] || /usr/bin/sudo /bin/mv "$MFC_PLIST" "$MFC_BACKUP/"
    [[ ! -e "$MFC_APP" ]] || /usr/bin/sudo /bin/mv "$MFC_APP" "$MFC_BACKUP/"
    print "Macs Fan Control was unloaded and preserved at $MFC_BACKUP"
  fi

  if [[ -x "/Library/PrivilegedHelperTools/local.macfan.helper" ]]; then
    if ! /usr/bin/sudo "/Library/PrivilegedHelperTools/local.macfan.helper" --restore-system; then
      print -u2 "The existing MacFan helper could not confirm Auto. It was preserved for recovery."
      exit 1
    fi
  fi
  if /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
    /usr/bin/sudo /bin/launchctl kill SIGTERM system/local.macfan.helper >/dev/null 2>&1 || true
    /bin/sleep 1
    /usr/bin/sudo /bin/launchctl bootout system/local.macfan.helper >/dev/null 2>&1 || true
    if /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
      print -u2 "The existing MacFan helper could not be unloaded. Its files were not replaced."
      exit 1
    fi
  fi

  HELPER_DIR="/Library/PrivilegedHelperTools"
  SUPPORT_DIR="/Library/Application Support/MacFan"
  CONFIG_TMP="$(/usr/bin/mktemp -t macfan-helper-config)"
  trap '/bin/rm -f "$CONFIG_TMP"' EXIT
  APP_DIGEST="$(/usr/bin/shasum -a 256 "$INSTALL_DIR/MacFan.app/Contents/MacOS/MacFan" | /usr/bin/awk '{print $1}')"
  /usr/bin/plutil -create xml1 "$CONFIG_TMP"
  /usr/bin/plutil -insert AllowedUID -integer "$UID" "$CONFIG_TMP"
  /usr/bin/plutil -insert ExecutableSHA256 -string "$APP_DIGEST" "$CONFIG_TMP"
  /usr/bin/plutil -insert AppExecutablePath -string "$INSTALL_DIR/MacFan.app/Contents/MacOS/MacFan" "$CONFIG_TMP"
  /usr/bin/plutil -insert ProtocolVersion -integer 1 "$CONFIG_TMP"

  /usr/bin/sudo /bin/mkdir -p "$HELPER_DIR" "$SUPPORT_DIR"
  /usr/bin/sudo /usr/sbin/chown root:wheel "$SUPPORT_DIR"
  /usr/bin/sudo /bin/chmod 755 "$SUPPORT_DIR"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$HELPER" "/Library/PrivilegedHelperTools/local.macfan.helper"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 600 "$CONFIG_TMP" "$SUPPORT_DIR/helper-config.plist"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 644 "$ROOT/Scripts/local.macfan.helper.plist" "/Library/LaunchDaemons/local.macfan.helper.plist"
  /usr/bin/sudo /usr/bin/codesign --verify --strict --verbose=2 "/Library/PrivilegedHelperTools/local.macfan.helper"
  /usr/bin/sudo /bin/launchctl bootstrap system "/Library/LaunchDaemons/local.macfan.helper.plist"
  /usr/bin/sudo /bin/launchctl enable system/local.macfan.helper
  /usr/bin/sudo /bin/launchctl kickstart -k system/local.macfan.helper
  /bin/sleep 1
  if ! /usr/bin/sudo /bin/launchctl print system/local.macfan.helper >/dev/null 2>&1; then
    print -u2 "The new helper did not remain loaded. Its files were preserved for diagnosis."
    exit 1
  fi
  if ! /usr/bin/sudo "/Library/PrivilegedHelperTools/local.macfan.helper" --check; then
    /usr/bin/sudo /bin/launchctl bootout system/local.macfan.helper >/dev/null 2>&1 || true
    print -u2 "The read-only hardware check failed. The helper was unloaded without attempting control."
    exit 1
  fi
  print "Installed root helper. It starts in Auto and releases on disconnect, sleep, or a 12-second heartbeat timeout."
fi

if [[ "$OPEN_APP" -eq 1 ]]; then
  /usr/bin/open "$INSTALL_DIR/MacFan.app"
fi
print "MacFan installation complete."
