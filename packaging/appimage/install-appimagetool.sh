#!/usr/bin/env bash
# Install appimagetool.
#
# Rather than extracting the raw binary (whose shared-library dependencies vary
# across runner images), we keep the AppImage and wrap it with
# --appimage-extract-and-run. This runs the embedded runtime which bundles its
# own libraries, avoiding issues like a missing libgpgme.so.11 on newer runners.
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

# Create a wrapper that runs the AppImage via --appimage-extract-and-run.
# This avoids extracting the raw binary and depending on system libs.
cat > /usr/local/bin/appimagetool <<'EOF'
#!/bin/bash
# Run appimagetool from its AppImage using the embedded runtime.
# APPIMAGE_EXTRACT_AND_RUN=1 forces extraction to a temp dir (no FUSE needed).
exec env APPIMAGE_EXTRACT_AND_RUN=1 /opt/appimagetool.AppImage --appimage-extract-and-run "$@"
EOF
chmod +x /usr/local/bin/appimagetool

echo "appimagetool installed to /usr/local/bin/appimagetool"