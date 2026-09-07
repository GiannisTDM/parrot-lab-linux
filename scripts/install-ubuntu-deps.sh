#!/bin/sh
set -eu
# Ubuntu 26.04 packages include the Swift compiler and its runtime.
if [ ! -r /etc/os-release ]; then
    echo "This dependency installer is for Ubuntu 26.04." >&2
    exit 1
fi
. /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 26.04 ]; then
    echo "Expected Ubuntu 26.04; found $PRETTY_NAME. See README.md for manual setup." >&2
    exit 1
fi
sudo apt-get update
sudo apt-get install -y --no-install-recommends swiftlang swiftlang-dev clang pkg-config \
    qt6-base-dev qt6-qpa-plugins qt6-wayland libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-libav ffmpeg
