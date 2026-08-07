#!/usr/bin/env bash
# Adapt the Mixxx desktop file for AppImage use.
# AppImage requires a simplified Exec line (no pasuspender wrapper).
#
# Usage:
#   packaging/appimage/adapt-desktop-file.sh <input.desktop> <output.desktop>
#
# Example:
#   packaging/appimage/adapt-desktop-file.sh \
#     res/linux/org.mixxx.Mixxx.desktop \
#     build/staging/mixxx-appimage.desktop
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <input.desktop> <output.desktop>" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="$2"

if [ ! -f "${INPUT}" ]; then
  echo "Error: input file not found: ${INPUT}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT}")"

# Replace the Exec line with a simple one suitable for AppImage.
# The original line is:   Exec=sh -c "pasuspender -- mixxx || mixxx"
# AppImage needs:         Exec=mixxx
sed -E 's/^Exec=.*/Exec=mixxx/' "${INPUT}" > "${OUTPUT}"

echo "Adapted desktop file for AppImage: ${OUTPUT}"