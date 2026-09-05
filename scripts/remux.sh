#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 capture.h264 output.mp4" >&2
    exit 2
fi
# Raw Annex-B has no container timestamps. This assumes the source is 30 FPS.
# No re-encode, no overwrite, and no shell interpretation of media paths.
exec ffmpeg -hide_banner -n -r 30 -i "$1" -c:v copy -movflags +faststart "$2"
