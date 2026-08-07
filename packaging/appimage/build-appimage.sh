#!/usr/bin/env bash
# Build the Mixxx AppImage from a configured CMake build directory.
# Usage: build-appimage.sh <build_dir> <arch> [appimagetool_path]
set -euo pipefail

BUILD_DIR="$(cd "$1" && pwd)"
ARCH="$2"
APPIMAGETOOL="${3:-/opt/appimagetool.AppImage}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING_DIR="${BUILD_DIR}/staging"
APPDIR="${STAGING_DIR}"

# Install to staging AppDir
mkdir -p "${APPDIR}"
DESTDIR="${APPDIR}" cmake --build "${BUILD_DIR}" --target install

# Copy the CMake-generated desktop file to the AppDir root
DESKTOP_SRC="${APPDIR}/usr/share/applications/mixxx-appimage.desktop"
if [ -f "${DESKTOP_SRC}" ]; then
  cp "${DESKTOP_SRC}" "${APPDIR}/mixxx-appimage.desktop"
else
  echo "Error: desktop file not found at ${DESKTOP_SRC}" >&2
  exit 1
fi

# Copy icon to AppDir root (appimagetool needs .DirIcon and mixxx.png)
ICON=$(find "${APPDIR}" -name "mixxx.png" -path "*256x256*" 2>/dev/null | head -1)
if [ -z "${ICON}" ]; then
  ICON=$(find "${APPDIR}" -name "mixxx.png" 2>/dev/null | head -1)
fi
if [ -n "${ICON}" ]; then
  cp "${ICON}" "${APPDIR}/.DirIcon"
  cp "${ICON}" "${APPDIR}/mixxx.png"
else
  echo "Warning: no mixxx.png icon found in staging" >&2
fi

# Strip debug symbols (static linking packs all deps into one binary)
if [ -f "${APPDIR}/usr/bin/mixxx" ]; then
  strip --strip-unneeded "${APPDIR}/usr/bin/mixxx"
fi

# Run appimagetool
"${APPIMAGETOOL}" -v "${APPDIR}" "${BUILD_DIR}/Mixxx-${ARCH}.AppImage"

# Verify output
if [ ! -f "${BUILD_DIR}/Mixxx-${ARCH}.AppImage" ]; then
  echo "Error: AppImage was not created" >&2
  exit 1
fi
ls -lh "${BUILD_DIR}/Mixxx-${ARCH}.AppImage"