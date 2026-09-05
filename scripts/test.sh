#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
swift test -j "${PARROTLAB_BUILD_JOBS:-4}"
BIN_DIR=$(swift build --show-bin-path)
"$BIN_DIR/parrot-lab" --self-test
python3 scripts/test-integration.py "$BIN_DIR/parrot-lab"
python3 scripts/test-errors.py "$BIN_DIR/parrot-lab"
if [ "${1:-}" = --desktop ]; then
    python3 scripts/test-integration.py "$BIN_DIR/parrot-lab" --desktop
fi
