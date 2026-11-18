#!/bin/bash
# End-to-end smoke test of the built app: checks the bundle, then drives real
# downloads through the app's own --cli mode against sample files served from
# localhost (so it needs no internet and no video site).
set -euo pipefail
cd "$(dirname "$0")"

APP="$(cd .. && pwd)/YTGrab.app"
BIN="$APP/Contents/MacOS/YTGrab"
RES="$APP/Contents/Resources"
PORT=8765

[ -x "$BIN" ] || { echo "Build the app first (./build.sh)."; exit 1; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "❌ $*"; exit 1; }
# Asserts that a media file contains the given stream, e.g. "Video: h264".
has_stream() {
    # ffmpeg exits non-zero when given no output file, so don't let that (or
    # pipefail) decide the result — only the stream listing matters.
    local info
    info="$("$RES/ffmpeg" -hide_banner -i "$1" 2>&1 || true)"
    grep -q "$2" <<<"$info" || fail "$(basename "$1") has no '$2' stream"
}

echo "== Bundle =="
codesign --verify --deep --strict "$APP" || fail "code signature invalid"
"$RES/yt-dlp" --version
"$RES/ffmpeg" -version | head -1
"$RES/deno" --version | head -1
"$RES/deno" eval 'console.log("deno runs JavaScript: ok")'
[ -x "$RES/realesrgan/realesrgan-ncnn-vulkan" ] || fail "Real-ESRGAN missing from bundle"
[ -f "$RES/realesrgan/models/realesr-animevideov3-x2.bin" ] || fail "Real-ESRGAN model missing"

echo "== Generating samples =="
mkdir "$WORK/srv" "$WORK/out"
SRC=(-f lavfi -i "testsrc=d=2:s=320x240:r=15" -f lavfi -i "sine=d=2")
# Already QuickTime-friendly: must come through untouched.
"$RES/ffmpeg" -v error "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac "$WORK/srv/h264.mp4"
# Not QuickTime-friendly: the app must convert it to H.264/AAC MP4.
"$RES/ffmpeg" -v error "${SRC[@]}" -c:v mpeg4 -c:a mp2 "$WORK/srv/legacy.mkv"

(cd "$WORK/srv" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 20); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/h264.mp4" && break
    sleep 0.25
done

echo "== Video → MP4 (already H.264) =="
"$BIN" --cli -o "$WORK/out" "http://127.0.0.1:$PORT/h264.mp4"
has_stream "$WORK/out/h264.mp4" "Video: h264"
has_stream "$WORK/out/h264.mp4" "Audio: aac"

echo "== Video → MP4 (needs conversion) =="
"$BIN" --cli -o "$WORK/out" "http://127.0.0.1:$PORT/legacy.mkv"
[ ! -e "$WORK/out/legacy.mkv" ] || fail "legacy.mkv was left unconverted"
has_stream "$WORK/out/legacy.mp4" "Video: h264"
has_stream "$WORK/out/legacy.mp4" "Audio: aac"

echo "== Audio → MP3 =="
mkdir "$WORK/mp3"
"$BIN" --cli --mp3 -o "$WORK/mp3" "http://127.0.0.1:$PORT/legacy.mkv"
has_stream "$WORK/mp3/legacy.mp3" "Audio: mp3"

echo "== Video → MP4 + AI upscale =="
mkdir "$WORK/up"
# Small chunks so the 30-frame sample exercises the chunk joining too.
CHUNK_FRAMES=12 "$BIN" --cli --upscale -o "$WORK/up" "http://127.0.0.1:$PORT/h264.mp4"
has_stream "$WORK/up/h264.mp4" "320x240"
has_stream "$WORK/up/h264 (upscaled 2x).mp4" "Video: h264.* 640x480"
has_stream "$WORK/up/h264 (upscaled 2x).mp4" "Audio: aac"
FRAMES="$("$RES/ffmpeg" -v error -i "$WORK/up/h264 (upscaled 2x).mp4" -map 0:v -f null - -stats 2>&1 \
    | sed -n 's/.*frame= *\([0-9]*\).*/\1/p' | tail -1)"
[ "$FRAMES" = 30 ] || fail "upscaled copy has $FRAMES frames, expected 30"

echo "== Bad input is rejected =="
if "$BIN" --cli -o "$WORK/out" "--version" >/dev/null 2>&1; then
    fail "an option-like URL was accepted"
fi

echo "✅ All tests passed."
