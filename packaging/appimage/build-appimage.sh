#!/usr/bin/env bash
# Build the Mixxx AppImage from an already-configured CMake build directory.
#
# Usage:
#   packaging/appimage/build-appimage.sh <build_dir> <arch> [appimagetool_path]
#
# Arguments:
#   build_dir         Path to the CMake build directory (e.g., build/)
#   arch              Architecture string for the output filename (e.g., x86_64)
#   appimagetool_path Path to the appimagetool binary (default: /usr/local/bin/appimagetool)
#
# Environment:
#   The Configure step must have set CMAKE_INSTALL_PREFIX=/ (the DESTDIR staging
#   approach relies on this).
set -euo pipefail

# ---- Argument parsing ----
BUILD_DIR="$1"
ARCH="$2"
APPIMAGETOOL="${3:-/usr/local/bin/appimagetool}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STAGING_DIR="${BUILD_DIR}/staging"
APPDIR="${STAGING_DIR}"

# ---- Step 1: Install to staging AppDir ----
echo "Installing to staging AppDir..."
mkdir -p "${APPDIR}"
DESTDIR="${APPDIR}" cmake --build "${BUILD_DIR}" --target install

# ---- Step 2: Locate / generate the desktop file ----
# appimagetool requires a .desktop file in the AppDir root.
# Prefer the CMake-generated AppImage desktop file, fall back to the
# standalone adapt-desktop-file.sh script.
DESKTOP_INSTALLED=$(find "${APPDIR}" -name "mixxx-appimage.desktop" -path "*/applications/*" 2>/dev/null | head -1)
if [ -n "${DESKTOP_INSTALLED}" ]; then
  echo "Using CMake-generated desktop file: ${DESKTOP_INSTALLED}"
  cp "${DESKTOP_INSTALLED}" "${APPDIR}/mixxx-appimage.desktop"
else
  echo "CMake-generated desktop file not found, adapting from source..."
  "${SCRIPT_DIR}/adapt-desktop-file.sh" \
    "${PROJECT_DIR}/res/linux/org.mixxx.Mixxx.desktop" \
    "${APPDIR}/mixxx-appimage.desktop"
fi

# ---- Step 3: Copy icon to AppDir root ----
# appimagetool needs both .DirIcon (AppImage file icon) and mixxx.png (for the
# desktop file's Icon= key) in the AppDir root. Prefer the 256x256 icon, fall
# back to any installed size.
ICON=$(find "${APPDIR}" -name "mixxx.png" -path "*256x256*" 2>/dev/null | head -1)
if [ -z "${ICON}" ]; then
  ICON=$(find "${APPDIR}" -name "mixxx.png" 2>/dev/null | head -1)
fi
if [ -n "${ICON}" ]; then
  cp "${ICON}" "${APPDIR}/.DirIcon"
  cp "${ICON}" "${APPDIR}/mixxx.png"
  echo "Copied icon from ${ICON}"
else
  echo "Warning: no mixxx.png icon found in staging" >&2
fi

# ---- Step 4: Strip debug symbols ----
# The vcpkg buildenv statically links all dependencies (Qt6, QML, ALSA, etc.)
# into a single binary, making it very large with debug symbols.
if [ -f "${APPDIR}/usr/bin/mixxx" ]; then
  echo "Stripping debug symbols from mixxx binary..."
  strip --strip-unneeded "${APPDIR}/usr/bin/mixxx"
fi

# ---- Step 5: Run appimagetool ----
echo "Running appimagetool..."
"${APPIMAGETOOL}" -v "${APPDIR}" "${BUILD_DIR}/Mixxx-${ARCH}.AppImage"

# ---- Step 6: Verify output ----
if [ -f "${BUILD_DIR}/Mixxx-${ARCH}.AppImage" ]; then
  ls -lh "${BUILD_DIR}/Mixxx-${ARCH}.AppImage"
else
  echo "Error: AppImage was not created" >&2
  exit 1
fi