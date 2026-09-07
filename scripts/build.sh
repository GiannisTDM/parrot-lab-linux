#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
if [ "$(uname -s)" != Linux ]; then
    echo "The desktop release must be built on Linux. The headless core can be built on macOS with swift build." >&2
    exit 1
fi
pkg-config --exists Qt6Widgets gstreamer-app-1.0 gstreamer-video-1.0
swift build -c release -j "${PARROTLAB_BUILD_JOBS:-4}"
BIN_DIR=$(swift build -c release --show-bin-path)
"$BIN_DIR/parrot-lab" --self-test
printf '%s\n' "$BIN_DIR/parrot-lab"
