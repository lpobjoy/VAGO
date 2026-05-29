#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="../YTGrab.app"
VOL="YTGrab"
FINAL="../YTGrab.dmg"
RW="/tmp/ytgrab-rw.dmg"
MNT="/Volumes/$VOL"

[ -d "$APP" ] || { echo "Build the app first (./build.sh)."; exit 1; }

if [ ! -f dmgbg.png ]; then
    echo "== Generating DMG background =="
    swiftc -O -o dmgbg dmgbg.swift -framework AppKit
    ./dmgbg dmgbg.png
fi

echo "== Creating read-write DMG =="
rm -f "$RW" "$FINAL"
# Size generously to fit the 84MB app plus background.
hdiutil create -srcfolder "$APP" -volname "$VOL" -fs HFS+ \
    -format UDRW -size 200m "$RW" >/dev/null

echo "== Mounting =="
hdiutil detach "$MNT" >/dev/null 2>&1 || true
hdiutil attach "$RW" -noautoopen -mountpoint "$MNT" >/dev/null

echo "== Adding Applications link + background =="
ln -sf /Applications "$MNT/Applications"
mkdir -p "$MNT/.background"
cp dmgbg.png "$MNT/.background/bg.png"

echo "== Styling Finder window =="
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 120
        set background picture of theViewOptions to file ".background:bg.png"
        set position of item "YTGrab.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
echo "== Detaching =="
hdiutil detach "$MNT" >/dev/null

echo "== Compressing to final DMG =="
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL" >/dev/null
rm -f "$RW"

echo "== Done =="
ls -lh "$FINAL" | awk '{print $9, $5}'
