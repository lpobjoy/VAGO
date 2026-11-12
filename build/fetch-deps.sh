#!/bin/bash
# Downloads the bundled command-line tools (yt-dlp, static ffmpeg, deno) into
# build/Resources. These are large binaries and are intentionally NOT committed
# to git — run this once before building.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Resources
cd Resources

if [ ! -x yt-dlp ]; then
    echo "== Downloading yt-dlp (universal standalone) =="
    curl -L --fail -o yt-dlp \
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    chmod +x yt-dlp
else
    echo "yt-dlp already present, skipping."
fi

if [ ! -x ffmpeg ]; then
    echo "== Downloading static ffmpeg (Apple Silicon) =="
    curl -L --fail -o ff.zip "https://www.osxexperts.net/ffmpeg71arm.zip"
    unzip -o ff.zip >/dev/null
    rm -rf ff.zip __MACOSX
    chmod +x ffmpeg
else
    echo "ffmpeg already present, skipping."
fi

# yt-dlp needs a JavaScript runtime to download from YouTube; deno is the one
# it supports out of the box.
if [ ! -x deno ]; then
    echo "== Downloading deno (Apple Silicon) =="
    curl -L --fail -o deno.zip \
        "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
    unzip -o deno.zip >/dev/null
    rm -f deno.zip
    chmod +x deno
else
    echo "deno already present, skipping."
fi

echo "== Versions =="
./yt-dlp --version
./ffmpeg -version | head -1
./deno --version | head -1
echo "✅ Dependencies ready."
