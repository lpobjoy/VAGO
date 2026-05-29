#!/bin/bash
# Downloads the bundled command-line tools (yt-dlp + static ffmpeg) into
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

echo "== Versions =="
./yt-dlp --version
./ffmpeg -version | head -1
echo "✅ Dependencies ready."
