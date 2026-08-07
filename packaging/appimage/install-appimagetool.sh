#!/usr/bin/env bash
# Install appimagetool.
#
# We simply download the appimagetool AppImage and make it executable.  AppImages
# run directly (via FUSE, which is provided by the libfuse2t64 system dependency),
# so no extraction or library handling is needed — the AppImage bundles its own
# runtime and libraries.
#
# Usage:
#   packaging/appimage/install-appimagetool.sh [arch]
#
# The arch argument defaults to the output of `uname -m`.  Supported values:
#   x86_64, aarch64
set -euo pipefail

ARCH="${1:-$(uname -m)}"

case "${ARCH}" in
  x86_64)  APPIMAGE_ARCH="x86_64"  ;;
  aarch64) APPIMAGE_ARCH="aarch64" ;;
  *)
    echo "Error: unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"

echo "Downloading appimagetool for ${APPIMAGE_ARCH}..."
curl -fsSL --connect-timeout 15 --max-time 120 \
  -o /opt/appimagetool.AppImage "${URL}"
chmod +x /opt/appimagetool.AppImage

echo "appimagetool installed to /opt/appimagetool.AppImage"