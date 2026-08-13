#!/bin/bash
# Packages build/Flick.app into a drag-to-Applications DMG for sharing.
# Run scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/Flick.app"
DMG="$ROOT/build/Flick.dmg"
STAGE="$ROOT/build/dmg-stage"

[ -d "$APP" ] || { echo "Install the app first: scripts/build-app.sh" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Flick.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Flick" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "DMG: $DMG"
echo "Note: ad-hoc signed — other Macs will need right-click → Open the first time."
