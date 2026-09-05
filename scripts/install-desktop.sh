#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
BIN_DIR=$(swift build -c release --show-bin-path)
if [ ! -x "$BIN_DIR/parrot-lab" ]; then
    echo "Build first with ./scripts/build.sh" >&2
    exit 1
fi
INSTALL_PREFIX=${PARROTLAB_INSTALL_PREFIX:-$HOME/.local}
install -d "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/share/applications"
install -m 755 "$BIN_DIR/parrot-lab" "$INSTALL_PREFIX/bin/parrot-lab"
install -m 644 Resources/parrot-lab.desktop "$INSTALL_PREFIX/share/applications/parrot-lab.desktop"
echo "Installed to $INSTALL_PREFIX. Ensure $INSTALL_PREFIX/bin is on your desktop session's PATH."
