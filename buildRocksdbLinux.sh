#!/usr/bin/env bash

set -euo pipefail

ARCH=""
for arg in "$@"; do
  case $arg in
    --arch=*)
      ARCH="${arg#*=}"
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ARCH" ]]; then
  echo "Usage: $0 --arch=<arm64|x86_64>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
REPO_ROOT="$SCRIPT_DIR"

# shellcheck source=./scripts/build-rocksdb-common.sh
source "${REPO_ROOT}/scripts/build-rocksdb-common.sh"

HOST_OS="$(uname -s)"
if [[ "$HOST_OS" != "Linux" ]]; then
  echo "Error: buildRocksdbLinux.sh must run on a Linux host." >&2
  exit 1
fi
BUILD_SUBDIR=""
CC_BIN="${CC:-}"
CXX_BIN="${CXX:-}"
AR_BIN="${AR:-}"
RANLIB_BIN="${RANLIB:-}"
EXTRA_C_FLAGS="-fPIC"
CMAKE_SYSTEM_PROCESSOR=""
DEFAULT_CC=""
DEFAULT_CXX=""
DEFAULT_AR=""
DEFAULT_RANLIB=""

case "$ARCH" in
  arm64)
    BUILD_SUBDIR="linux_arm64"
    EXTRA_C_FLAGS+=" -march=armv8-a"
    CMAKE_SYSTEM_PROCESSOR="aarch64"
    DEFAULT_CC="aarch64-linux-gnu-gcc"
    DEFAULT_CXX="aarch64-linux-gnu-g++"
    DEFAULT_AR="aarch64-linux-gnu-ar"
    DEFAULT_RANLIB="aarch64-linux-gnu-ranlib"
    ;;
  x86_64)
    BUILD_SUBDIR="linux_x86_64"
    EXTRA_C_FLAGS+=" -m64"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    DEFAULT_CC="gcc"
    DEFAULT_CXX="g++"
    DEFAULT_AR="ar"
    DEFAULT_RANLIB="ranlib"
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
 esac

resolve_tool() {
  local current="$1"
  local fallback="$2"
  if [[ -n "$current" ]]; then
    echo "$current"
    return
  fi
  if [[ -n "$fallback" ]]; then
    command -v "$fallback" 2>/dev/null || true
  else
    echo ""
  fi
}

CC_BIN="$(resolve_tool "$CC_BIN" "$DEFAULT_CC")"
CXX_BIN="$(resolve_tool "$CXX_BIN" "$DEFAULT_CXX")"
AR_BIN="$(resolve_tool "$AR_BIN" "$DEFAULT_AR")"
RANLIB_BIN="$(resolve_tool "$RANLIB_BIN" "$DEFAULT_RANLIB")"

if [[ -z "$CC_BIN" || -z "$CXX_BIN" ]]; then
  echo "Missing cross-compilation toolchain for linux_${ARCH}." >&2
  exit 1
fi

if [[ -z "$AR_BIN" || -z "$RANLIB_BIN" ]]; then
  echo "Missing archiver toolchain for linux_${ARCH}." >&2
  exit 1
fi

BUILD_DIR="${REPO_ROOT}/build/lib/${BUILD_SUBDIR}"

if build_common::check_existing_artifacts "$BUILD_DIR"; then
  exit 0
fi

mkdir -p "$BUILD_DIR"

NUM_CORES="$(build_common::default_parallel_jobs)"
if [[ -n "${ROCKSDB_MAKE_JOBS:-}" ]]; then
  NUM_CORES="${ROCKSDB_MAKE_JOBS}"
elif [[ "$ARCH" == "arm64" && "$NUM_CORES" -gt 2 ]]; then
  NUM_CORES=2
fi

cmake_args=(-DCMAKE_SYSTEM_NAME=Linux)
if [[ -n "$CMAKE_SYSTEM_PROCESSOR" ]]; then
  cmake_args+=(-DCMAKE_SYSTEM_PROCESSOR="${CMAKE_SYSTEM_PROCESSOR}")
fi

cmake_args+=(
  -DCMAKE_C_COMPILER="${CC_BIN}"
  -DCMAKE_CXX_COMPILER="${CXX_BIN}"
  -DCMAKE_AR="${AR_BIN}"
  -DCMAKE_RANLIB="${RANLIB_BIN}"
)

EXTRA_CXX_FLAGS="$EXTRA_C_FLAGS"

build_common::cmake_configure \
  "$REPO_ROOT" \
  "$BUILD_DIR" \
  "$EXTRA_C_FLAGS" \
  "$EXTRA_CXX_FLAGS" \
  "${cmake_args[@]}"

build_common::run_cmake_build "$BUILD_DIR" "$NUM_CORES"
