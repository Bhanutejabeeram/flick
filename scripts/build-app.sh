#!/bin/bash
# Builds Flick.app and the flick CLI.
#
# MenuBarExtra and UserNotifications both need a real bundle with an
# identifier, so the SwiftPM executable is wrapped into an .app here rather
# than run bare.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/build/Flick.app"
BUNDLE_ID="com.flick.Flick"
VERSION="0.2.0"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/FlickApp" "$APP/Contents/MacOS/Flick"
cp "$BUILD_DIR/flick"    "$APP/Contents/Resources/flick"
cp "$ROOT/assets/claude.png" "$APP/Contents/Resources/claude.png"

echo "==> Generating icons"
swift "$ROOT/scripts/make-icons.swift" "$ROOT/assets/flick.png" "$ROOT/build/icons"
iconutil -c icns "$ROOT/build/icons/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/build/icons/MenuIcon.png" "$ROOT/build/icons/MenuIcon@2x.png" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Flick</string>
    <key>CFBundleDisplayName</key>       <string>Flick</string>
    <key>CFBundleExecutable</key>        <string>Flick</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu-bar only: no Dock icon, no window on launch. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local-only agent control plane.</string>
    <!-- Focusing the right terminal tab needs AppleScript. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Flick brings the terminal window running your agent to the front.</string>
</dict>
</plist>
PLIST

cat > "$ROOT/build/entitlements.plist" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key> <true/>
</dict>
</plist>
ENT

echo "==> Signing (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ROOT/build/entitlements.plist" \
    --timestamp=none \
    "$APP/Contents/Resources/flick" >/dev/null 2>&1 || true
codesign --force --deep --sign - \
    --entitlements "$ROOT/build/entitlements.plist" \
    --timestamp=none \
    "$APP" >/dev/null

echo "==> Installing to /Applications/Flick.app"
if pgrep -xq Flick; then
    echo "    (quitting running Flick first)"
    pkill -x Flick || true
    sleep 1
fi
rm -rf "/Applications/Flick.app"
ditto "$APP" "/Applications/Flick.app"
# Remove the staging copy so Launchpad/Spotlight only ever see one Flick.
rm -rf "$APP"

echo "==> Installing CLI to ~/.local/bin/flick"
mkdir -p "$HOME/.local/bin"
ln -sf "/Applications/Flick.app/Contents/Resources/flick" "$HOME/.local/bin/flick"

echo ""
echo "App:  /Applications/Flick.app"
echo "CLI:  $HOME/.local/bin/flick"
echo ""
echo "Next:"
echo "  open /Applications/Flick.app"
echo "  ~/.local/bin/flick install    # wire up Claude Code hooks"
