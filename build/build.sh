#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="YTGrab.app"
OUT="../$APP"

# Bootstrap: fetch the bundled tools and generate the icon if they're missing.
if [ ! -x Resources/yt-dlp ] || [ ! -x Resources/ffmpeg ] || [ ! -x Resources/deno ] \
    || [ ! -x Resources/realesrgan/realesrgan-ncnn-vulkan ]; then
    echo "== Fetching dependencies =="
    ./fetch-deps.sh
fi
if [ ! -f AppIcon.icns ]; then
    echo "== Generating app icon =="
    swiftc -O -o icongen icongen.swift -framework AppKit
    mkdir -p YTGrab.iconset && ./icongen YTGrab.iconset
    iconutil -c icns YTGrab.iconset -o AppIcon.icns
fi

echo "== Cleaning =="
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "== Compiling Swift (optimized, arm64) =="
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
    -framework SwiftUI -framework AppKit \
    -o "$OUT/Contents/MacOS/YTGrab" \
    main.swift

echo "== Assembling bundle =="
cp Info.plist "$OUT/Contents/Info.plist"
cp AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
cp Resources/yt-dlp "$OUT/Contents/Resources/yt-dlp"
cp Resources/ffmpeg "$OUT/Contents/Resources/ffmpeg"
cp Resources/deno "$OUT/Contents/Resources/deno"
cp -R Resources/realesrgan "$OUT/Contents/Resources/realesrgan"
cp upscale.sh "$OUT/Contents/Resources/upscale.sh"
chmod +x "$OUT/Contents/Resources/yt-dlp" "$OUT/Contents/Resources/ffmpeg" \
    "$OUT/Contents/Resources/deno"

echo "== Ad-hoc code signing =="
# Sign nested binaries first, then the whole bundle, so Gatekeeper is happy.
codesign --force -s - "$OUT/Contents/Resources/yt-dlp"
codesign --force -s - "$OUT/Contents/Resources/ffmpeg"
# deno ships with the entitlements its JIT needs; keep them when re-signing.
codesign --force --preserve-metadata=entitlements -s - "$OUT/Contents/Resources/deno"
codesign --force -s - "$OUT/Contents/Resources/realesrgan/realesrgan-ncnn-vulkan"
codesign --force -s - "$OUT/Contents/MacOS/YTGrab"
codesign --force --deep -s - "$OUT"

echo "== Done =="
du -sh "$OUT"
