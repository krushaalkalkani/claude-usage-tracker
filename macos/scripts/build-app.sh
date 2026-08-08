#!/usr/bin/env bash
#
# Builds ClaudeUsage.app from the SwiftPM package.
#
# Xcode is NOT required — this uses `swift build` plus a hand-rolled bundle, so the whole
# thing works with Command Line Tools alone.
#
#   ./build-app.sh                 release build → macos/build/ClaudeUsage.app
#   ./build-app.sh --debug         debug build
#   ./build-app.sh --install       also copy to /Applications
#   ./build-app.sh --run           launch it when done
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="release"
INSTALL=0
RUN=0

for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --release) CONFIG="release" ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="ClaudeUsage"
BUILD_DIR="$PKG_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
cd "$PKG_DIR"
swift build -c "$CONFIG" --product ClaudeUsageApp

BIN="$(swift build -c "$CONFIG" --product ClaudeUsageApp --show-bin-path)/ClaudeUsageApp"
if [ ! -x "$BIN" ]; then
  echo "build produced no executable at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# `ditto --noextattr --norsrc --noacl` rather than `cp`: a plain copy carries extended
# attributes that make codesign fail with "resource fork, Finder information, or similar
# detritus not allowed", and `xattr -c` cannot strip com.apple.provenance.
ditto --noextattr --norsrc --noacl "$BIN" "$APP/Contents/MacOS/$APP_NAME"
ditto --noextattr --norsrc --noacl \
  "$PKG_DIR/ClaudeUsage/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. UNUserNotificationCenter and SMAppService both want a signed bundle
# with a stable identifier; without this the app still runs but falls back to the osascript
# notification path and cannot register as a login item.
echo "==> codesign (ad-hoc)"
if codesign --force --sign - \
     --identifier "com.krushal.claude-usage-tracker" \
     "$APP" 2>&1 | grep -qi "error\|not allowed"; then
  echo "    (signing failed — the app still runs, but notifications will use the"
  echo "     osascript fallback and 'Launch at login' will be unavailable)"
else
  codesign --verify "$APP" 2>/dev/null \
    && echo "    signed: $(codesign -dv "$APP" 2>&1 | awk -F= '/^Identifier/{print $2}')" \
    || echo "    (signature did not verify)"
fi

echo "==> built $APP"

if [ "$INSTALL" -eq 1 ]; then
  echo "==> installing to /Applications"
  # Quit a running copy first so the replace does not race a live process.
  osascript -e 'tell application "ClaudeUsage" to quit' 2>/dev/null || true
  pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto --noextattr --norsrc --noacl "$APP" "/Applications/$APP_NAME.app"
  APP="/Applications/$APP_NAME.app"
  echo "    installed to $APP"
fi

if [ "$RUN" -eq 1 ]; then
  echo "==> launching"
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi

cat <<EOF

Done.

  App:      $APP
  Launch:   open "$APP"
  Hooks:    $SCRIPT_DIR/install-hooks.sh

The icon appears in the menu bar; there is no Dock icon by design.
EOF
