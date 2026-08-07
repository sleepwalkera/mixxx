#!/usr/bin/env bash
# Install appimagetool (native binary, extracted from the AppImage).
#
# The extracted binary may depend on shared libraries that are not present on
# all runner images (e.g. libgpgme.so.11).  To handle this, we also copy any
# bundled libraries from the AppImage into /usr/local/lib so that the dynamic
# linker can find them.
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

echo "Extracting native binary and bundled libraries..."
/tmp/appimagetool.AppImage --appimage-extract >/dev/null 2>&1

# Install the main binary.
sudo mv squashfs-root/usr/bin/appimagetool /usr/local/bin/

# If the AppImage bundles any shared libraries, copy them too so the binary
# can find them at runtime (e.g. libgpgme.so.11 on newer Ubuntu runners).
if [ -d squashfs-root/usr/lib ]; then
  sudo mkdir -p /usr/local/lib
  # Copy only actual shared libraries (files and symlinks), not the whole tree.
  find squashfs-root/usr/lib \( -name '*.so*' -type f -o -name '*.so*' -type l \) 2>/dev/null \
    | while read -r lib; do
        sudo cp -a "$lib" /usr/local/lib/
      done
  # Update the dynamic linker cache so the libraries are found.
  sudo ldconfig 2>/dev/null || true
fi

rm -rf squashfs-root /tmp/appimagetool.AppImage

echo "appimagetool installed to /usr/local/bin/"

# Verify the binary works.
/usr/local/bin/appimagetool --version 2>/dev/null && echo "appimagetool is functional" \
  || echo "Warning: appimagetool may have missing dependencies (see errors above). Check the build." >&2