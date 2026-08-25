#!/bin/bash
# Record the island and turn it into a GIF + MP4 for the README.
#
# Captures the app's own view, so it needs no Screen Recording permission and
# picks up nothing else on the desktop. All data is scripted — no real projects
# appear.
#
# Usage: make demo-media

set -euo pipefail

cd "$(dirname "$0")/.."

FRAMES=$(mktemp -d)
OUT="docs/media"
FPS=25

trap 'rm -rf "$FRAMES"' EXIT

echo "recording..."
swift build >/dev/null
pkill -f PipelineIsland 2>/dev/null || true
sleep 1
./.build/debug/PipelineIsland --record "$FRAMES" >/dev/null

COUNT=$(find "$FRAMES" -name 'frame-*.png' | wc -l | tr -d ' ')
if [ "$COUNT" -lt 10 ]; then
    echo "only $COUNT frames captured — something went wrong" >&2
    exit 1
fi
echo "  $COUNT frames"

mkdir -p "$OUT"

echo "encoding mp4..."
ffmpeg -y -loglevel error -framerate "$FPS" -i "$FRAMES/frame-%05d.png" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    -vf "scale=1200:-2" \
    "$OUT/demo.mp4"

echo "encoding gif..."
# Two-pass palette: a shared palette across all frames avoids the dithering
# noise a per-frame palette produces on flat dark backgrounds.
ffmpeg -y -loglevel error -framerate "$FPS" -i "$FRAMES/frame-%05d.png" \
    -vf "fps=20,scale=900:-1:flags=lanczos,palettegen=stats_mode=diff" \
    "$FRAMES/palette.png"

ffmpeg -y -loglevel error -framerate "$FPS" -i "$FRAMES/frame-%05d.png" \
    -i "$FRAMES/palette.png" \
    -lavfi "fps=20,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
    "$OUT/demo.gif"

echo "stills..."
# Pull a few representative frames out as PNGs.
cp "$FRAMES/frame-00150.png" "$OUT/expanded.png" 2>/dev/null || true
cp "$FRAMES/frame-00060.png" "$OUT/running.png" 2>/dev/null || true

ls -lh "$OUT" | awk 'NR>1 {print "  " $9 "  " $5}'
