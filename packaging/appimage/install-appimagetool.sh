#!/usr/bin/env bash
# Download and install appimagetool (native binary, extracted from the AppImage
# to avoid FUSE dependency on CI runners).
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
  -o /tmp/appimagetool.AppImage "${URL}"
chmod +x /tmp/appimagetool.AppImage

echo "Extracting native binary..."
/tmp/appimagetool.AppImage --appimage-extract >/dev/null 2>&1
sudo mv squashfs-root/usr/bin/appimagetool /usr/local/bin/
rm -rf squashfs-root /tmp/appimagetool.AppImage

echo "appimagetool installed to /usr/local/bin/"