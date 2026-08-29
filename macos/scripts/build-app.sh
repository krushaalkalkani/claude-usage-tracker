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
STAGING_ROOT="$(mktemp -d /private/tmp/claudeusage-build.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# `ditto --noextattr --norsrc --noacl` rather than `cp`: a plain copy carries extended
# attributes that make codesign fail with "resource fork, Finder information, or similar
# detritus not allowed", and `xattr -c` cannot strip com.apple.provenance.
ditto --noextattr --norsrc --noacl "$BIN" "$STAGED_APP/Contents/MacOS/$APP_NAME"
ditto --noextattr --norsrc --noacl \
  "$PKG_DIR/ClaudeUsage/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# ---- App icon --------------------------------------------------------------------
# Drawn by the binary we just built (`--render-appicon`) and packed with iconutil, which
# ships with Command Line Tools — so this still needs no Xcode. Without an icon the bundle
# falls back to the generic placeholder, and that placeholder is what shows up next to every
# notification the app posts.
echo "==> app icon"
ICONSET="$STAGING_ROOT/AppIcon.iconset"
if "$BIN" --render-appicon "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    AppIcon.icns"
else
  echo "    (icon generation failed — shipping without one)" >&2
fi

# ---- Signing identity ------------------------------------------------------------
# UNUserNotificationCenter refuses an ad-hoc signature outright: requestAuthorization fails
# with UNErrorDomain code 1, "Notifications are not allowed for this application", and every
# alert then goes out through the osascript fallback — posted as *Script Editor*, with Script
# Editor's icon and no thumbnail. That is why the app's notifications look like they belong to
# something else. So prefer a real identity whenever the machine has one; ad-hoc stays as the
# fallback so a clean checkout with no developer account still builds and runs.
#
# Override with CODESIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  for PREFIX in "Developer ID Application:" "Apple Development:"; do
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' -v p="$PREFIX" 'index($2, p) == 1 { print $2; exit }')"
    [ -n "$IDENTITY" ] && break
  done
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
fi

# SMAppService also wants a signed bundle with a stable identifier; without one the app still
# runs but cannot register as a login item. Sign in /private/tmp: Desktop can be managed by
# File Provider, which attaches provenance metadata quickly enough to make codesign reject an
# otherwise clean bundle. The verified signature is then copied into build/.
# ---- Notification Centre widget (opt-in: BUILD_WIDGET=1) --------------------------
# SwiftPM cannot emit an .appex, so the extension is hand-assembled: the widget is built as a
# plain executable, wrapped in the bundle layout WidgetKit expects, and nested under
# Contents/PlugIns of the *staged* app. It is signed first, because signing the host seals its
# PlugIns directory.
#
# OFF BY DEFAULT, and not because the bundle is wrong. It assembles cleanly and both
# signatures verify — but PlugInKit never registers it: `pluginkit -m` never lists it,
# `pluginkit -a` and `lsregister -f` both no-op, and pkd logs no rejection, i.e. the extension
# is never even considered. Ad-hoc signing is the blocker; WidgetKit extensions need a real
# signing identity. Shipping a silently dead .appex inside the app is worse than shipping
# none, so this only runs when asked for.
#
#   BUILD_WIDGET=1 ./scripts/build-app.sh --install
#
# With a Developer ID (or opening Package.swift in Xcode) the same code should register.
if [ "${BUILD_WIDGET:-0}" = "1" ]; then
  echo "==> widget extension"
  swift build -c "$CONFIG" --product ClaudeUsageWidget >/dev/null
  WIDGET_BIN="$(swift build -c "$CONFIG" --product ClaudeUsageWidget --show-bin-path)/ClaudeUsageWidget"
  APPEX="$STAGED_APP/Contents/PlugIns/ClaudeUsageWidget.appex"
  mkdir -p "$APPEX/Contents/MacOS"
  ditto --noextattr --norsrc --noacl "$WIDGET_BIN" "$APPEX/Contents/MacOS/ClaudeUsageWidget"
  cat > "$APPEX/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeUsageWidget</string>
  <key>CFBundleIdentifier</key><string>com.krushal.claude-usage-tracker.widget</string>
  <key>CFBundleName</key><string>ClaudeUsageWidget</string>
  <key>CFBundleDisplayName</key><string>Claude &amp; ChatGPT Usage</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST
  if codesign --force --sign "$IDENTITY" --timestamp=none "$APPEX" >/dev/null 2>&1; then
    echo "    widget: com.krushal.claude-usage-tracker.widget"
  else
    echo "    widget signing failed — removing it rather than shipping an unsigned appex" >&2
    rm -rf "$STAGED_APP/Contents/PlugIns"
  fi
fi

if [ "$IDENTITY" = "-" ]; then
  echo "==> codesign (ad-hoc — no signing identity found)"
else
  echo "==> codesign ($IDENTITY)"
fi
if codesign --force --sign "$IDENTITY" \
     --identifier "com.krushal.claude-usage-tracker" \
     "$STAGED_APP" >/dev/null 2>&1 \
   && codesign --verify --deep --strict "$STAGED_APP" >/dev/null 2>&1; then
  echo "    signed and verified: $(codesign -dv "$STAGED_APP" 2>&1 | awk -F= '/^Identifier/{print $2}')"
  if [ "$IDENTITY" = "-" ]; then
    echo "    note: an ad-hoc signature cannot use the system notification API. Alerts will"
    echo "          be posted through osascript instead, which shows Script Editor's icon"
    echo "          and drops the usage thumbnail."
  fi
else
  echo "    (signing failed — the app still runs, but notifications will use the"
  echo "     osascript fallback and 'Launch at login' will be unavailable)"
fi

ditto --noextattr --norsrc --noacl "$STAGED_APP" "$APP"
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
