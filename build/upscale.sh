#!/bin/bash
# AI-upscales a video 2× with Real-ESRGAN, writing "<name> (upscaled 2x).mp4"
# next to the input. Bundled into the app and run by it after a download.
#
# Usage: FFMPEG=… UPSCALER=… MODELS=… upscale.sh INPUT
#
# The video is processed in chunks of frames so temporary disk use stays
# bounded no matter how long the video is.
set -euo pipefail

IN="$1"
: "${FFMPEG:?}" "${UPSCALER:?}" "${MODELS:?}"
CHUNK="${CHUNK_FRAMES:-150}"
OUT="${IN%.*} (upscaled 2x).mp4"

WORK="$(mktemp -d)"
child=""
cleanup() {
    [ -n "$child" ] && kill "$child" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# Runs a command in the background and waits for it, so that a TERM sent to
# this script (the app's Cancel button) is handled at once and the command
# is killed by cleanup instead of being left running.
run() {
    "$@" &
    child=$!
    wait "$child"
    child=""
}

INFO="$("$FFMPEG" -hide_banner -i "$IN" 2>&1 || true)"
FPS="$(sed -n 's/.*Video:.* \([0-9.]*\) fps.*/\1/p' <<<"$INFO" | head -1)"
[ -n "$FPS" ] || { echo "[upscale] no video stream found in $IN"; exit 1; }
# ffmpeg prints NTSC rates rounded; use the exact fraction to keep audio in sync.
case "$FPS" in
    23.98) FPS=24000/1001 ;;
    29.97) FPS=30000/1001 ;;
    59.94) FPS=60000/1001 ;;
esac
TOTAL="$(sed -n 's/.*Duration: \([0-9]*\):\([0-9]*\):\([0-9.]*\).*/\1 \2 \3/p' <<<"$INFO" | head -1 \
    | awk -v fps="$FPS" '{ split(fps, f, "/"); r = f[2] ? f[1] / f[2] : f[1];
                           printf "%d", ($1 * 3600 + $2 * 60 + $3) * r }')"

echo "[upscale] $(basename "$IN"): about ${TOTAL:-?} frames — this is slow"

start=0
part=0
while :; do
    rm -rf "$WORK/frames" "$WORK/up"
    mkdir "$WORK/frames" "$WORK/up"

    run "$FFMPEG" -nostdin -v error -i "$IN" -map 0:v:0 \
        -vf "select='between(n\,$start\,$((start + CHUNK - 1)))'" \
        -fps_mode passthrough -frames:v "$CHUNK" "$WORK/frames/%08d.png"
    count="$(find "$WORK/frames" -name '*.png' | wc -l | tr -d ' ')"
    [ "$count" -gt 0 ] || break

    # The upscaler prints a progress line per tile; keep that out of the log
    # unless it fails.
    if ! run "$UPSCALER" -i "$WORK/frames" -o "$WORK/up" -m "$MODELS" \
            -n realesr-animevideov3 -s 2 -f jpg >"$WORK/upscaler.log" 2>&1; then
        tail -20 "$WORK/upscaler.log"
        echo "[upscale] the upscaler failed"
        exit 1
    fi

    run "$FFMPEG" -nostdin -v error -framerate "$FPS" -i "$WORK/up/%08d.jpg" \
        -c:v libx264 -crf 18 -pix_fmt yuv420p "$WORK/part$part.mp4"
    echo "file 'part$part.mp4'" >>"$WORK/parts.txt"

    start=$((start + count))
    part=$((part + 1))
    echo "[upscale] $start of ~${TOTAL:-?} frames"
    [ "$count" -eq "$CHUNK" ] || break
done
[ "$part" -gt 0 ] || { echo "[upscale] no frames could be read from $IN"; exit 1; }

# Join the upscaled chunks and carry the original audio across untouched.
run "$FFMPEG" -nostdin -v error -f concat -safe 0 -i "$WORK/parts.txt" -i "$IN" \
    -map 0:v -map '1:a?' -c copy -movflags +faststart "$WORK/final.mp4"
mv -f "$WORK/final.mp4" "$OUT"
echo "[upscale] saved $(basename "$OUT")"
