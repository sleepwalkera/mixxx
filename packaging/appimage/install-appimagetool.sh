#!/usr/bin/env bash
# Install appimagetool (native binary, extracted from the AppImage).
#
# The extracted binary may depend on shared libraries that are not present on
# all runner images (e.g. libgpgme.so.11).  We keep the entire extracted
# directory tree and use a wrapper that sets LD_LIBRARY_PATH so the binary
# finds its bundled libraries without polluting the system library path.
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

echo "Extracting..."
/tmp/appimagetool.AppImage --appimage-extract >/dev/null 2>&1

# Keep the entire extracted tree under /opt/appimagetool so the binary can
# find its bundled libraries via LD_LIBRARY_PATH.
sudo rm -rf /opt/appimagetool
sudo mv squashfs-root /opt/appimagetool

# Create a wrapper that sets the library path before invoking the binary.
cat > /usr/local/bin/appimagetool <<'WRAPPER'
#!/bin/bash
APPIMAGETOOL_ROOT="/opt/appimagetool"
exec env LD_LIBRARY_PATH="${APPIMAGETOOL_ROOT}/usr/lib:${LD_LIBRARY_PATH}" \
  "${APPIMAGETOOL_ROOT}/usr/bin/appimagetool" "$@"
WRAPPER
chmod +x /usr/local/bin/appimagetool

rm -rf /tmp/appimagetool.AppImage

echo "appimagetool installed to /usr/local/bin/appimagetool"