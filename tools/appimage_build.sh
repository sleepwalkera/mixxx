#!/usr/bin/env bash
#
# Build the Mixxx AppImage in the same glibc-2.28 Rocky 8 container as CI.
#
# This one file is used in two ways. CI runs it inside its rockylinux:8
# container, so the container branch below just runs the build steps. Run on a
# normal host it starts a rockylinux:8 container itself and re-runs this same
# file inside it, so the build steps live in exactly one place and CI exercises
# them on every build.
#
# The paths are taken from the environment so the same steps run in both
# layouts. MIXXX_SOURCE_DIR is the repo checkout and MIXXX_BUILD_DIR the build
# directory, both defaulting to the local Docker mounts (/src, /build). CMake is
# reused from PATH when it is already 4.2 or newer (as the CI action provides),
# otherwise installed into MIXXX_CMAKE_DIR (default /opt/cmake).
#
# The build steps mirror .github/workflows/build.yml: install git/python39/curl,
# set up CMake 4.2.x, run tools/appimage_release_buildenv.sh setup, configure,
# build, ctest, cpack, tools/check_appimage_floor_deps.py and the smoke test.
#
# Usage (host):
#   appimage_build.sh [build|shell] [options]
# Options:
#   --build-dir DIR      build/output dir (default <repo>/build-appimage)
#   --cache-dir DIR      dnf/cmake/ccache/buildenv cache base
#                        (default ${XDG_CACHE_HOME:-$HOME/.cache}/mixxx-appimage)
#   --network MODE       docker --network value (e.g. host)
#   --proxy URL          HTTP(S)/SOCKS proxy for downloads inside the container
#   --image IMG          container image (default rockylinux:8)
#   --cmake-version VER  pin CMake instead of the newest 4.2.x
#   --help
#
# The caches persist between runs, so repeated builds only recompile what
# changed. The repo is mounted writable at /src, because ctest runs the tests
# with the source dir as the working directory, and the build dir at /build.

set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ===========================================================================
# Container branch: run inside the rockylinux:8 container.
# ===========================================================================
if [ "${MIXXX_APPIMAGE_IN_CONTAINER:-0}" = "1" ]; then
    MIXXX_SOURCE_DIR="${MIXXX_SOURCE_DIR:-/src}"
    MIXXX_BUILD_DIR="${MIXXX_BUILD_DIR:-/build}"
    MIXXX_CMAKE_DIR="${MIXXX_CMAKE_DIR:-/opt/cmake}"

    echo "---- [Rocky8] Install base tools ----"
    dnf install -y git python39 curl
    alternatives --set python3 /usr/bin/python3.9

    # The container is root but the checkout belongs to the host user; without
    # this git refuses the dubious ownership dir (e.g. the version describe).
    git config --global --add safe.directory "${MIXXX_SOURCE_DIR}"

    echo "---- [AppImage] Set up cmake (4.2.x, like actions-setup-cmake) ----"
    cmake_is_new_enough() {
        command -v cmake >/dev/null 2>&1 &&
            cmake --version 2>/dev/null |
                awk -F'[ .]' 'NR==1 {ok=($3>4||($3==4&&$4>=2)); exit !ok}'
    }
    if ! cmake_is_new_enough; then
        if [ -z "${CMAKE_VERSION:-}" ]; then
            if [ -f "${MIXXX_CMAKE_DIR}/.version" ]; then
                CMAKE_VERSION=$(cat "${MIXXX_CMAKE_DIR}/.version")
            else
                CMAKE_VERSION=$(python3 -c 'import json,urllib.request,sys
try:
    d = json.load(urllib.request.urlopen("https://api.github.com/repos/Kitware/CMake/tags?per_page=100", timeout=30))
    vs = [t["name"].lstrip("v") for t in d if t["name"].startswith("v4.2.")]
    # highest 4.2 patch, numeric sort
    sys.stdout.write(sorted(vs, key=lambda v: [int(x) for x in v.split(".")])[-1] if vs else "4.2.8")
except Exception:
    sys.stdout.write("4.2.8")')
            fi
        fi
        if [ ! -x "${MIXXX_CMAKE_DIR}/v${CMAKE_VERSION}/bin/cmake" ]; then
            arc=$(uname -m)
            cm_fname="cmake-${CMAKE_VERSION}-linux-${arc}.tar.gz"
            curl -fsSL --retry 3 --connect-timeout 15 -o /tmp/cmake.tar.gz \
                "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${cm_fname}"
            csha=$(curl -fsSL --retry 3 --connect-timeout 15 \
                "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-SHA-256.txt" \
                | awk -v a="${cm_fname}" '$2 == a {print $1}')
            [ -n "${csha}" ] || { echo "ERROR: no SHA-256 entry for ${cm_fname}" >&2; exit 1; }
            echo "${csha}  /tmp/cmake.tar.gz" | sha256sum -c -
            mkdir -p "${MIXXX_CMAKE_DIR}/v${CMAKE_VERSION}"
            tar -xzf /tmp/cmake.tar.gz -C "${MIXXX_CMAKE_DIR}/v${CMAKE_VERSION}" --strip-components=1
            rm /tmp/cmake.tar.gz
        fi
        echo "${CMAKE_VERSION}" > "${MIXXX_CMAKE_DIR}/.version"
        export PATH="${MIXXX_CMAKE_DIR}/v${CMAKE_VERSION}/bin:${PATH}"
    fi

    echo "---- [macOS/Linux] Set up build environment ----"
    # The release setup writes the exported variables to GITHUB_ENV; run it as a
    # child by absolute path so its dirname of $0 does not depend on how this
    # script was invoked, then source the throwaway file into this shell.
    GITHUB_ENV="$(mktemp)"
    export GITHUB_ENV
    "${MIXXX_SOURCE_DIR}/tools/appimage_release_buildenv.sh" setup
    set -a
    # shellcheck disable=SC1090
    . "${GITHUB_ENV}"
    set +a
    rm -f "${GITHUB_ENV}"
    unset GITHUB_ENV

    echo "---- [Rocky8] Config ALSA null device ----"
    printf 'pcm.!default {\n  type null\n}\npcm.sysdefault null\n' > /etc/asound.conf

    # The container runs as root; hand anything it wrote back to the caller on
    # exit (normal, aborted and interactive-shell runs).
    # shellcheck disable=SC2329
    fix_owner() {
        chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "${MIXXX_BUILD_DIR}" /cache 2>/dev/null || true
    }
    trap 'fix_owner' EXIT

    if [ "${WRAPPER_MODE:-build}" = shell ]; then
        mkdir -p "${MIXXX_BUILD_DIR}"
        cd "${MIXXX_BUILD_DIR}"
        bash || true # child, so the EXIT trap still chowns after the session
        exit 0
    fi

    echo "---- Configure (cmake_args mirror .github/workflows/build.yml) ----"
    mkdir -p "${MIXXX_BUILD_DIR}"
    cd "${MIXXX_BUILD_DIR}"
    cmake -S "${MIXXX_SOURCE_DIR}" -B "${MIXXX_BUILD_DIR}" \
        -DQT6=ON \
        -DQML=ON \
        -DMIXXX_APPIMAGE=ON \
        -DINSTALL_USER_UDEV_RULES=OFF \
        -DCMAKE_C_COMPILER=/opt/rh/gcc-toolset-12/root/usr/bin/cc \
        -DCMAKE_CXX_COMPILER=/opt/rh/gcc-toolset-12/root/usr/bin/c++ \
        -DCMAKE_CXX_FLAGS=-Wno-error=array-bounds \
        -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}" \
        -DWARNINGS_FATAL=ON \
        -DDEBUG_ASSERTIONS_FATAL=OFF \
        -DBATTERY=ON \
        -DBROADCAST=ON \
        -DDOWNLOAD_MANUAL=ON \
        -DHID=ON \
        -DKEYFINDER=ON \
        -DLILV=ON \
        -DOPUS=ON \
        -DQTKEYCHAIN=ON \
        -DVINYLCONTROL=ON \
        -DCMAKE_VERBOSE_MAKEFILE=OFF \
        -L

    echo "---- Build ----"
    ccache --zero-stats
    ccache --max-size=2G
    cmake --build "${MIXXX_BUILD_DIR}" --config RelWithDebInfo --parallel "$(nproc)"

    echo "---- ccache stats ----"
    ccache --show-stats
    ccache --cleanup

    echo "---- Test ----"
    cd "${MIXXX_BUILD_DIR}"
    GTEST_COLOR=1 CTEST_PARALLEL_LEVEL=3 CTEST_OUTPUT_ON_FAILURE=1 ctest --timeout 45

    echo "---- Package (cpack -G AppImage) ----"
    cd "${MIXXX_BUILD_DIR}"
    cpack -G AppImage -V

    echo "---- [AppImage] Check floor dependencies ----"
    # The container has no findutils, so pick the AppImage with a glob.
    APPIMAGE=
    for candidate in "${MIXXX_BUILD_DIR}"/*.AppImage; do
        if [ -e "${candidate}" ]; then
            APPIMAGE=${candidate}
            break
        fi
    done
    if [ -z "${APPIMAGE}" ]; then
        echo "ERROR: no AppImage found in ${MIXXX_BUILD_DIR}" >&2
        exit 1
    fi
    python3 "${MIXXX_SOURCE_DIR}/tools/check_appimage_floor_deps.py" "${APPIMAGE}"

    echo "---- [AppImage] Smoke test ----"
    set +e
    APPIMAGE_EXTRACT_AND_RUN=1 timeout 60 "${APPIMAGE}" --version >/tmp/smoke.log 2>&1
    rc=$?
    set -e
    if grep -qE "Inconsistency detected by ld.so|error while loading shared libraries|cannot open shared object file" /tmp/smoke.log; then
        echo "FAIL: AppImage failed at loader level (rc=${rc})"
        cat /tmp/smoke.log
        exit 1
    fi
    if ! grep -qE "Mixxx [0-9]|Using preferences|Selected Qt style|ConfigObject:" /tmp/smoke.log; then
        echo "FAIL: AppImage did not reach Mixxx startup (rc=${rc})"
        cat /tmp/smoke.log
        exit 1
    fi
    echo "SMOKE OK (rc=${rc})"
    ls -lh "${APPIMAGE}"
    echo "AppImage: ${APPIMAGE}"
    exit 0
fi

# ===========================================================================
# Host branch: start the container and re-run this same file inside it.
# ===========================================================================
usage() {
    awk '/^set -euo pipefail$/{exit} NR>1{print}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MIXXX_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

MODE=${1:-build}
BUILD_DIR=${MIXXX_ROOT}/build-appimage
CACHE_DIR=${XDG_CACHE_HOME:-${HOME}/.cache}/mixxx-appimage
NETWORK=
PROXY_URL=
IMAGE=rockylinux:8
CMAKE_VERSION=

while [ $# -gt 0 ]; do
    case "$1" in
        build|shell) MODE=$1 ;;
        --build-dir) BUILD_DIR=$2; shift ;;
        --cache-dir) CACHE_DIR=$2; shift ;;
        --network) NETWORK=$2; shift ;;
        --proxy) PROXY_URL=$2; shift ;;
        --image) IMAGE=$2; shift ;;
        --cmake-version) CMAKE_VERSION=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

HOST_ARCH=$(uname -m)
case "${HOST_ARCH}" in
    x86_64|aarch64) ;;
    *) echo "ERROR: unsupported architecture for the AppImage buildenv: ${HOST_ARCH}" >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 1; }

mkdir -p \
    "${BUILD_DIR}" \
    "${CACHE_DIR}/dnf" \
    "${CACHE_DIR}/cmake" \
    "${CACHE_DIR}/ccache" \
    "${CACHE_DIR}/buildenv"

# The daemon resolves bind sources in its own namespace; cd && pwd -P is
# portable and the dirs exist.
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd -P)"
CACHE_DIR="$(cd "${CACHE_DIR}" && pwd -P)"

netproxy_flags=()
[ -n "${NETWORK}" ] && netproxy_flags+=(--network "${NETWORK}")
if [ -n "${PROXY_URL}" ]; then
    netproxy_flags+=(-e ALL_PROXY="${PROXY_URL}" -e all_proxy="${PROXY_URL}")
    netproxy_flags+=(-e HTTP_PROXY="${PROXY_URL}" -e http_proxy="${PROXY_URL}")
    netproxy_flags+=(-e HTTPS_PROXY="${PROXY_URL}" -e https_proxy="${PROXY_URL}")
else
    for v in HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy; do
        [ -n "${!v:-}" ] && netproxy_flags+=(-e "${v}=${!v}")
    done
fi

# Docker auto-creates an empty dir for a bind source it cannot see (DinD or a
# remote daemon), so probe the repo with a marker file rather than test -d.
echo "== Preflight: docker daemon can see the mount sources =="
if ! docker run --rm ${netproxy_flags[@]+"${netproxy_flags[@]}"} \
        -v "${MIXXX_ROOT}:/p/src:ro" \
        -v "${BUILD_DIR}:/p/build:ro" \
        -v "${CACHE_DIR}:/p/cache:ro" \
        "${IMAGE}" bash -c 'test -f /p/src/CMakeLists.txt -a -d /p/build -a -d /p/cache' \
        >/dev/null 2>&1; then
    cat >&2 <<EOF

ERROR: cannot verify that the docker daemon can bind these host paths:
  ${MIXXX_ROOT}   -> /src
  ${BUILD_DIR}    -> /build
  ${CACHE_DIR}    -> /cache

Possible causes and fixes:
  * the docker daemon is not reachable / the socket is not accessible
  * a Docker-in-Docker (or remote) daemon cannot see these host paths, so pass
    them into the daemon container or point --build-dir/--cache-dir elsewhere
  * the '${IMAGE}' image cannot be pulled
EOF
    exit 2
fi

run_flags=(
    --rm
    --add-host host.docker.internal:host-gateway
    -v "${MIXXX_ROOT}:/src"
    -v "${BUILD_DIR}:/build"
    -v "${CACHE_DIR}/dnf:/var/cache/dnf"
    -v "${CACHE_DIR}/cmake:/opt/cmake"
    -v "${CACHE_DIR}/ccache:/cache/ccache"
    -v "${CACHE_DIR}/buildenv:/cache/buildenv"
    -e MIXXX_SOURCE_DIR=/src
    -e MIXXX_BUILD_DIR=/build
    -e MIXXX_CMAKE_DIR=/opt/cmake
    -e CCACHE_DIR=/cache/ccache
    -e "CCACHE_SLOPPINESS=pch_defines,time_macros"
    -e BUILDENV_BASEPATH=/cache/buildenv
    -e HOST_UID="$(id -u)"
    -e HOST_GID="$(id -g)"
    -e MIXXX_APPIMAGE_IN_CONTAINER=1
    -e "WRAPPER_MODE=${MODE}"
)
[ -n "${CMAKE_VERSION}" ] && run_flags+=(-e "CMAKE_VERSION=${CMAKE_VERSION}")
run_flags+=(${netproxy_flags[@]+"${netproxy_flags[@]}"})

echo "== Running ${IMAGE} (mode: ${MODE}) =="
echo "   sources: ${MIXXX_ROOT} (writable, like CI's checkout)"
echo "   build  : ${BUILD_DIR}"
echo "   cache  : ${CACHE_DIR}"
echo "   proxy  : ${PROXY_URL:-<none>}"

if [ "${MODE}" = shell ]; then
    docker run -it "${run_flags[@]}" "${IMAGE}" bash /src/tools/appimage_build.sh
else
    docker run -i "${run_flags[@]}" "${IMAGE}" bash /src/tools/appimage_build.sh
fi
