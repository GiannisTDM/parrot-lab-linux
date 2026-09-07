#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
swift test -j "${PARROTLAB_BUILD_JOBS:-4}"
BIN_DIR=$(swift build --show-bin-path)
"$BIN_DIR/parrot-lab" --self-test
python3 scripts/test-integration.py "$BIN_DIR/parrot-lab"
python3 scripts/test-errors.py "$BIN_DIR/parrot-lab"
python3 scripts/test-ground.py "$BIN_DIR/parrot-lab"
python3 scripts/test-ground.py "$BIN_DIR/parrot-lab" --no-video-ack
if [ "${1:-}" = --desktop ]; then
    python3 scripts/test-theme.py "$BIN_DIR/parrot-lab"
    PARROTLAB_REDUCE_MOTION=1 python3 scripts/test-theme.py "$BIN_DIR/parrot-lab"
    python3 scripts/test-integration.py "$BIN_DIR/parrot-lab" --desktop
    python3 scripts/test-ground.py "$BIN_DIR/parrot-lab" --desktop
    python3 scripts/test-ground.py "$BIN_DIR/parrot-lab" --desktop --window-close
    python3 scripts/test-ground.py "$BIN_DIR/parrot-lab" --desktop --sc2-controls
    python3 scripts/test-integration.py "$BIN_DIR/parrot-lab" --desktop --ground-sc2
fi
