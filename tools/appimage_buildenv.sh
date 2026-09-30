#!/usr/bin/env bash
# Ignored in case of a source call, but needed for bash specific sourcing detection

# shellcheck disable=SC2091
if [ -z "${GITHUB_ENV}" ] && ! $(return 0 2>/dev/null); then
  echo "This script must be run by sourcing it:"
  echo "source $0 $*"
  exit 1
fi

# CI runs this script as a child process (GITHUB_ENV is set), where `return`
# is invalid outside of a function; use this helper so failures actually
# fail the run instead of letting it succeed silently.
if $(return 0 2>/dev/null); then
  _mixxx_fail() { return 1; }
else
  _mixxx_fail() { exit 1; }
fi

# GitHub Actions containers (e.g. rockylinux:8) run as root and have no
# sudo; use it on non-root machines only.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

mixxx_realpath() {
    # Local helper; a plain "realpath" would shadow the system command for
    # the sourced shell session.  return instead of exit so a failure does
    # not terminate the caller's shell.
    OLDPWD="${PWD}"
    cd "$1" || return 1
    pwd
    cd "${OLDPWD}" || return 1
}

# Get script file location, compatible with bash and zsh
if [ -n "$BASH_VERSION" ]; then
  THIS_SCRIPT_NAME="${BASH_SOURCE[0]}"
elif [ -n "$ZSH_VERSION" ]; then
  # shellcheck disable=SC2296
  THIS_SCRIPT_NAME="${(%):-%N}"
else
  THIS_SCRIPT_NAME="$0"
fi

HOST_ARCH=$(uname -m)  # One of x86_64, aarch64, etc.

# Buildenv defaults for the current Mixxx release.  Override any of these
# via environment variables when building a different version so the script
# does not need to be edited per release:
#   BUILDENV_BRANCH  — release series, also the download path segment ("2.6")
#   BUILDENV_NAME    — full archive basename
#                      ("mixxx-deps-2.6-arm64-linux-")
#   VCPKG_TARGET_TRIPLET — vcpkg triplet for the host arch

case "$HOST_ARCH" in
    x86_64)
        if [ -n "${BUILDENV_RELEASE}" ]; then
            : "${VCPKG_TARGET_TRIPLET:=x64-linux-release}"
            : "${BUILDENV_BRANCH:=2.6-rel}"
            : "${BUILDENV_NAME:=mixxx-deps-2.6-x64-linux-rel-}"
            : "${BUILDENV_SHA256:=}"
        else
            : "${VCPKG_TARGET_TRIPLET:=x64-linux}"
            : "${BUILDENV_BRANCH:=2.6}"
            : "${BUILDENV_NAME:=mixxx-deps-2.6-x64-linux-}"
            # [TEMP rocky8] Test scaffold buildenvs are fetched from the
            # vcpkg fork CI artifact, so no checksum is pinned yet; fill in
            # once a buildenv is published to downloads.mixxx.org.
            : "${BUILDENV_SHA256:=}"
        fi
        ;;
    aarch64)
        if [ -n "${BUILDENV_RELEASE}" ]; then
            : "${VCPKG_TARGET_TRIPLET:=arm64-linux-release}"
            : "${BUILDENV_BRANCH:=2.6-rel}"
            : "${BUILDENV_NAME:=mixxx-deps-2.6-arm64-linux-rel-}"
            : "${BUILDENV_SHA256:=}"
        else
            : "${VCPKG_TARGET_TRIPLET:=arm64-linux}"
            : "${BUILDENV_BRANCH:=2.6}"
            : "${BUILDENV_NAME:=mixxx-deps-2.6-arm64-linux-}"
            # [TEMP rocky8] See the x86_64 entry.  The vcpkg #91 arm64
            # artifact has no sha suffix (empty sha_short in the vcpkg CI).
            : "${BUILDENV_SHA256:=}"
        fi
        ;;
    *)
        echo "ERROR: Unsupported architecture detected: $HOST_ARCH"
        echo "The AppImage buildenv is currently only available for x86_64 and aarch64."
        exit 1
        ;;
esac

# Allow overriding the buildenv download URL (e.g. to point at a CI artifact
# while testing a not-yet-published buildenv).
: "${BUILDENV_URL:=https://downloads.mixxx.org/dependencies/${BUILDENV_BRANCH}/Linux/${BUILDENV_NAME}.zip}"
MIXXX_ROOT="$(mixxx_realpath "$(dirname "$THIS_SCRIPT_NAME")/..")"

[ -z "$BUILDENV_BASEPATH" ] && BUILDENV_BASEPATH="${MIXXX_ROOT}/buildenv"

case "$1" in
    name)
        echo "$BUILDENV_NAME"
        if [ -n "${GITHUB_ENV}" ]; then
            echo "BUILDENV_NAME=$BUILDENV_NAME" >> "${GITHUB_ENV}"
        fi
        ;;

    setup)
        BUILDENV_PATH="${BUILDENV_BASEPATH}/${BUILDENV_NAME}"

        # vcpkg.cmake is at BUILDENV_PATH/scripts/buildsystems/, matching the
        # macos/android buildenv pattern.  Export the full variable set so a
        # child cmake process sees BUILDENV_URL too — it gates the buildenv
        # download in CMakeLists.txt — and VCPKG_TARGET_TRIPLET.
        export MIXXX_VCPKG_ROOT="${BUILDENV_PATH}"
        export BUILDENV_NAME="${BUILDENV_NAME}"
        export BUILDENV_BASEPATH="${BUILDENV_BASEPATH}"
        export BUILDENV_URL="${BUILDENV_URL}"
        export BUILDENV_SHA256="${BUILDENV_SHA256}"
        export VCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET}"
        export CMAKE_PREFIX_PATH="${BUILDENV_PATH}/installed/${VCPKG_TARGET_TRIPLET}"

        # The CPack AppImage generator requires CMake >= 4.2 (added in CMake
        # 4.2).  Resolve this before installing any system packages, so a
        # machine that cannot provide CMake >= 4.2 fails fast without
        # touching anything.  Priority: system CMake >= 4.2, then a snap
        # CMake, then apt-get satisfy, then fail with an install hint.  CI
        # provides CMake via jwlawson/actions-setup-cmake@v2.2 in build.yml,
        # so this only matters for local builds.
        if cmake --version 2>/dev/null | awk -F'[ .]' 'NR==1 {ok=($3>4 || ($3==4 && $4>=2)); exit !ok} END {if (NR==0) exit 1}'; then
            echo "Using system CMake (>= 4.2)"
        elif /snap/bin/cmake --version 2>/dev/null | awk -F'[ .]' 'NR==1 {ok=($3>4 || ($3==4 && $4>=2)); exit !ok} END {if (NR==0) exit 1}'; then
            # snap installs to /snap/bin, which comes after /usr/bin in the
            # default PATH, so a snap-installed CMake does not shadow the
            # system one; put it on PATH explicitly.
            export PATH="/snap/bin:$PATH"
            echo "Using Snap CMake (>= 4.2)"
        elif command -v apt-get >/dev/null 2>&1 && $SUDO apt-get update && $SUDO apt-get satisfy "cmake (>= 4.2)"; then
            echo "CMake >= 4.2 installed via apt"
        else
            echo "CMake >= 4.2 is required for the AppImage CPack generator, but no"
            echo "version >= 4.2 is available in the system package manager."
            echo ""
            if command -v snap >/dev/null 2>&1; then
                echo "On Ubuntu, install it via snap:"
                echo "  sudo snap install cmake --channel=4.2/stable --classic"
            else
                echo "Please install CMake >= 4.2 (e.g. from https://cmake.org/download/)"
            fi
            echo "and re-source this script."
            _mixxx_fail
        fi

        # System packages required for the build: build tools plus X11/Mesa/GL
        # headers and utilities (Qt platform). All other third-party libraries
        # come from the VCPKG buildenv. (The vcpkg toolchain prepends the
        # buildenv to CMAKE_PREFIX_PATH, so identical system packages are not used.)
        if command -v dnf >/dev/null 2>&1; then
            # RHEL-family (Rocky 8 / CentOS 8): mirror the apt list below.  The
            # buildenv itself is built in a glibc-2.28 Rocky 8 container, so
            # compiling on the same base keeps the AppImage at glibc 2.28.
            $SUDO dnf install -y epel-release dnf-plugins-core >/dev/null 2>&1 || true
            $SUDO dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
                || $SUDO dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
            # XCB packages needed to link the static Qt plugin from the
            # buildenv; keep in sync with the buildenv's Qt build.
            $SUDO dnf install -y \
                gcc-toolset-12 \
                ccache \
                make \
                pkgconfig \
                patchelf \
                file \
                desktop-file-utils \
                fuse-libs \
                unzip \
                squashfs-tools \
                libsecret-devel \
                libgcrypt-devel \
                libgpg-error-devel \
                mesa-libGL-devel \
                mesa-libGLU-devel \
                mesa-libEGL-devel \
                libX11-devel \
                libXrender-devel \
                libXi-devel \
                libxkbcommon-devel \
                libxkbcommon-x11-devel \
                libSM-devel \
                libXrandr-devel \
                libXext-devel \
                libudev-devel \
                libxcb-devel \
                xcb-util-devel \
                xcb-util-wm-devel \
                xcb-util-image-devel \
                xcb-util-keysyms-devel \
                xcb-util-renderutil-devel \
                xcb-util-cursor-devel \
                glibc-devel \
                kernel-headers \
                pipewire-libs \
                || { echo "ERROR: Failed to install AppImage system packages"; _mixxx_fail; }
            # The gcc-toolset-12 toolchain provides the compiler used for the
            # buildenv; enable it so mixxx is compiled with the same one.  In
            # CI the script runs as a child process, so persist the toolchain
            # PATH/LD_LIBRARY_PATH into GITHUB_ENV for the later build steps.
            # shellcheck disable=SC1091
            source /opt/rh/gcc-toolset-12/enable
            if [ -n "${GITHUB_ENV}" ]; then
                echo "PATH=${PATH}" >> "${GITHUB_ENV}"
                echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> "${GITHUB_ENV}"
            fi
        elif command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update
            # libfuse2t64 is the t64-transitioned name (Debian 13 / Ubuntu 24.04+);
            # libfuse2 is the older name (Ubuntu 22.04).  Install whichever is available.
            FUSE_PKG="libfuse2t64"
            if ! apt-cache show libfuse2t64 &>/dev/null; then
                FUSE_PKG="libfuse2"
            fi
            # XCB packages needed to link the static Qt plugin from the
            # buildenv; keep in sync with the buildenv's Qt build.
            $SUDO apt-get install -y --no-install-recommends \
                ccache \
                g++ \
                make \
                pkg-config \
                patchelf \
                file \
                desktop-file-utils \
                "${FUSE_PKG}" \
                unzip \
                squashfs-tools \
                libsecret-1-dev \
                libgcrypt20-dev \
                libgpg-error-dev \
                libgl1-mesa-dev \
                libx11-xcb-dev \
                libglu1-mesa-dev \
                libxrender-dev \
                libxi-dev \
                libxkbcommon-dev \
                libxkbcommon-x11-dev \
                libegl1-mesa-dev \
                libsm-dev \
                libxrandr-dev \
                libxext-dev \
                libudev-dev \
                libxcb1-dev \
                libxcb-cursor-dev \
                libxcb-glx0-dev \
                libxcb-icccm4-dev \
                libxcb-image0-dev \
                libxcb-keysyms1-dev \
                libxcb-randr0-dev \
                libxcb-render0-dev \
                libxcb-render-util0-dev \
                libxcb-shape0-dev \
                libxcb-shm0-dev \
                libxcb-sync-dev \
                libxcb-util-dev \
                libxcb-xfixes0-dev \
                libxcb-xkb-dev \
                libxcb-xinput-dev \
                || { echo "ERROR: Failed to install AppImage system packages"; _mixxx_fail; }
        else
            echo "WARNING: The AppImage buildenv system-dependency step currently only"
            echo "automates Debian-based systems. Please install the equivalent"
            echo "packages for your distribution, or consider contributing a"
            echo "script for it."
        fi

        # appimagetool is required by the CPack AppImage generator, which searches
        # for an executable named "appimagetool" in the PATH (or via
        # CPACK_APPIMAGE_TOOL_EXECUTABLE).  Install it to /usr/local/bin
        # which is in the default PATH.  Running it requires FUSE
        # (libfuse2t64 / fuse-libs is installed above), or
        # APPIMAGE_EXTRACT_AND_RUN=1 to run it extracted (CI containers have
        # no /dev/fuse).
        # Pinned to a tagged release — the "continuous" tag is a moving
        # target that would make builds non-reproducible.
        export APPIMAGE_EXTRACT_AND_RUN=1
        APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-${HOST_ARCH}.AppImage"
        $SUDO curl -fsSL --connect-timeout 15 --max-time 120 \
            -o /usr/local/bin/appimagetool \
            "${APPIMAGETOOL_URL}" \
            || { echo "ERROR: Failed to download appimagetool"; _mixxx_fail; }
        $SUDO chmod +x /usr/local/bin/appimagetool \
            || { echo "ERROR: Failed to make appimagetool executable"; _mixxx_fail; }

        echo_exported_variables() {
            echo "BUILDENV_NAME=${BUILDENV_NAME}"
            echo "BUILDENV_BASEPATH=${BUILDENV_BASEPATH}"
            echo "BUILDENV_URL=${BUILDENV_URL}"
            echo "BUILDENV_SHA256=${BUILDENV_SHA256}"
            echo "MIXXX_VCPKG_ROOT=${MIXXX_VCPKG_ROOT}"
            echo "VCPKG_TARGET_TRIPLET=${VCPKG_TARGET_TRIPLET}"
            echo "CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
        }

        if [ -n "${GITHUB_ENV}" ]; then
            echo_exported_variables >> "${GITHUB_ENV}"
        elif [ "$1" != "--profile" ]; then
            echo ""
            echo "Exported environment variables:"
            echo_exported_variables
            echo "You can now configure, build and package the Mixxx AppImage in an EMPTY build directory via:"
            echo "cmake -DCMAKE_TOOLCHAIN_FILE=${MIXXX_VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake -DCPACK_GENERATOR=AppImage ${MIXXX_ROOT}"
            echo "cmake --build ."
            echo "cpack"
        fi
        ;;
    *)
        echo "Usage: source appimage_buildenv.sh [options]"
        echo ""
        echo "options:"
        echo "   help       Displays this help."
        echo "   name       Displays the name of the required build environment."
        echo "   setup      Setup the build environment variables for download during CMake configuration."
        ;;
esac
