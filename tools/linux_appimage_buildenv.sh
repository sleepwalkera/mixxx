#!/usr/bin/env bash
# Ignored in case of a source call, but needed for bash specific sourcing detection

set -o pipefail

# shellcheck disable=SC2091
if [ -z "${GITHUB_ENV}" ] && ! $(return 0 2>/dev/null); then
  echo "This script must be run by sourcing it:"
  echo "source $0 $*"
  exit 1
fi

realpath() {
    OLDPWD="${PWD}"
    cd "$1" || exit 1
    pwd
    cd "${OLDPWD}" || exit 1
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

HOST_ARCH=$(uname -m)  # One of x86_64, arm64, i386, ppc or ppc64

if [ "$HOST_ARCH" == "x86_64" ]; then
    if [ -n "${BUILDENV_RELEASE}" ]; then
        VCPKG_TARGET_TRIPLET="x64-linux-release"
        BUILDENV_BRANCH="2.7-rel"
        BUILDENV_NAME="mixxx-deps-2.7-x64-linux-rel-1c20f84a"
        BUILDENV_SHA256=""
    else
        VCPKG_TARGET_TRIPLET="x64-linux"
        BUILDENV_BRANCH="2.7"
        BUILDENV_NAME="mixxx-deps-2.7-x64-linux-1c20f84a"
        BUILDENV_SHA256=""
    fi
else
    echo "ERROR: Unsupported architecture detected: $HOST_ARCH"
    echo "The AppImage buildenv is currently only available for x86_64."
    echo "Please refer to the following guide:"
    echo "https://github.com/mixxxdj/mixxx/wiki/Compiling-dependencies-for-Linux"
    exit 1
fi

BUILDENV_URL="https://downloads.mixxx.org/dependencies/${BUILDENV_BRANCH}/Linux/${BUILDENV_NAME}.zip"
MIXXX_ROOT="$(realpath "$(dirname "$THIS_SCRIPT_NAME")/..")"

[ -z "$BUILDENV_BASEPATH" ] && BUILDENV_BASEPATH="${MIXXX_ROOT}/buildenv"

case "$1" in
    name)
        if [ -n "${GITHUB_ENV}" ]; then
            echo "BUILDENV_NAME=$BUILDENV_NAME" >> "${GITHUB_ENV}"
        else
            echo "$BUILDENV_NAME"
        fi
        ;;

    setup)
        BUILDENV_PATH="${BUILDENV_BASEPATH}/${BUILDENV_NAME}"

        # Determine the vcpkg root (may be directly in BUILDENV_PATH or in a vcpkg/ subdirectory)
        if [ -n "${MIXXX_VCPKG_ROOT}" ]; then
            echo "MIXXX_VCPKG_ROOT already set to ${MIXXX_VCPKG_ROOT}, preserving"
        elif [ -d "${BUILDENV_PATH}/vcpkg" ]; then
            MIXXX_VCPKG_ROOT="${BUILDENV_PATH}/vcpkg"
            echo "MIXXX_VCPKG_ROOT set to ${MIXXX_VCPKG_ROOT}"
        elif [ -d "${BUILDENV_PATH}" ]; then
            MIXXX_VCPKG_ROOT="${BUILDENV_PATH}"
            echo "MIXXX_VCPKG_ROOT set to ${MIXXX_VCPKG_ROOT}"
        else
            echo "Warning: BUILDENV_PATH ${BUILDENV_PATH} does not exist"
            MIXXX_VCPKG_ROOT="${BUILDENV_PATH}"
        fi

        export BUILDENV_NAME
        export BUILDENV_BASEPATH
        export MIXXX_VCPKG_ROOT
        export VCPKG_TARGET_TRIPLET="${VCPKG_TARGET_TRIPLET}"

        echo_exported_variables() {
            echo "BUILDENV_NAME=${BUILDENV_NAME}"
            echo "BUILDENV_BASEPATH=${BUILDENV_BASEPATH}"
            echo "MIXXX_VCPKG_ROOT=${MIXXX_VCPKG_ROOT}"
            echo "VCPKG_TARGET_TRIPLET=${VCPKG_TARGET_TRIPLET}"
        }

        if [ -n "${GITHUB_ENV}" ]; then
            echo_exported_variables >> "${GITHUB_ENV}"
        elif [ "$1" != "--profile" ]; then
            echo ""
            echo "Exported environment variables:"
            echo_exported_variables
            echo "You can now configure cmake from the command line in an EMPTY build directory via:"
            echo "cmake -DCMAKE_TOOLCHAIN_FILE=${MIXXX_VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake ${MIXXX_ROOT}"
        fi
        ;;
    *)
        echo "Usage: source linux_appimage_buildenv.sh [options]"
        echo ""
        echo "options:"
        echo "   help       Displays this help."
        echo "   name       Displays the name of the required build environment."
        echo "   setup      Setup the build environment variables for download during CMake configuration."
        ;;
esac