#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_DIR"
./scripts/build.sh
BIN_DIR=$(swift build -c release --show-bin-path)
PACKAGE_ARCH=$(dpkg --print-architecture)
STAGING_DIR=$(mktemp -d -t parrotlab-package.XXXXXXXX)
install -d "$STAGING_DIR/DEBIAN" "$STAGING_DIR/usr/bin" \
    "$STAGING_DIR/usr/share/applications" "$STAGING_DIR/usr/share/doc/parrot-lab" dist
sed "s/@ARCH@/$PACKAGE_ARCH/" Resources/debian-control.in > "$STAGING_DIR/DEBIAN/control"
install -m 755 "$BIN_DIR/parrot-lab" "$STAGING_DIR/usr/bin/parrot-lab"
install -m 644 Resources/parrot-lab.desktop "$STAGING_DIR/usr/share/applications/parrot-lab.desktop"
install -m 644 README.md PORTING.md VALIDATION.md "$STAGING_DIR/usr/share/doc/parrot-lab/"
PACKAGE_PATH="$PROJECT_DIR/dist/parrot-lab_0.3.0-1_$PACKAGE_ARCH.deb"
dpkg-deb --root-owner-group --build "$STAGING_DIR" "$PACKAGE_PATH"
printf 'Package: %s\nTemporary staging directory: %s\n' "$PACKAGE_PATH" "$STAGING_DIR"
