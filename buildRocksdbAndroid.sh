#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# shellcheck source=./build-rocksdb-common.sh
source "${PROJECT_ROOT}/build-rocksdb-common.sh"

usage() {
  cat <<USAGE
Usage: $0 --arch=<arm32|arm64|x86|x64> [--api-level <level>]

Builds the RocksDB static library for the requested Android architecture.
The script expects the Android NDK to be discoverable via ANDROID_NDK_ROOT,
ANDROID_NDK_HOME, the Android SDK, or the Kotlin/Native toolchain cache.
USAGE
}

ARCH=""
API_LEVEL="${ANDROID_API_LEVEL:-21}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch=*)
      ARCH="${1#*=}"
      shift
      ;;
    --arch)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 1
      fi
      ARCH="$2"
      shift 2
      ;;
    --api-level=*)
      API_LEVEL="${1#*=}"
      shift
      ;;
    --api-level)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 1
      fi
      API_LEVEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ARCH" ]]; then
  echo "Missing required --arch option" >&2
  usage >&2
  exit 1
fi

# shellcheck source=./scripts/android-ndk.sh
source "${PROJECT_ROOT}/scripts/android-ndk.sh"

normalize_arch() {
  local value="$1"
  case "$value" in
    arm32|armeabi-v7a|android_arm32)
      echo "android_arm32"
      ;;
    arm64|arm64-v8a|aarch64|android_arm64)
      echo "android_arm64"
      ;;
    x86|i686|android_x86)
      echo "android_x86"
      ;;
    x64|x86_64|android_x64|android_x86_64)
      echo "android_x64"
      ;;
    *)
      echo "Unsupported Android architecture: $value" >&2
      exit 1
      ;;
  esac
}

CONFIG_ARCH="$(normalize_arch "$ARCH")"
OUTPUT_SUBDIR="$CONFIG_ARCH"

if ! setup_android_ndk_toolchain "$CONFIG_ARCH" "$API_LEVEL"; then
  echo "Failed to configure Android toolchain for $CONFIG_ARCH" >&2
  exit 1
fi

BUILD_DIR="${PROJECT_ROOT}/build/lib/${OUTPUT_SUBDIR}"

if build_common::check_existing_artifacts "$BUILD_DIR"; then
  exit 0
fi

mkdir -p "$BUILD_DIR"

EXTRA_FLAGS="-fPIC -g0 -ffunction-sections -fdata-sections -DANDROID -I${PROJECT_ROOT}/build/include -I${PROJECT_ROOT}/build/include/dependencies"
EXTRA_FLAGS+=" -DZLIB -DBZIP2 -DSNAPPY -DLZ4 -DZSTD"
EXTRA_FLAGS+=" ${ANDROID_TOOLCHAIN_EXTRA_CFLAGS}"

if [[ "$CONFIG_ARCH" == "android_arm32" || "$CONFIG_ARCH" == "android_x86" ]]; then
  EXTRA_FLAGS+=" -Wno-shorten-64-to-32"
fi

CC_BIN="$CC"
CXX_BIN="$CXX"
AR_BIN="$AR"
RANLIB_BIN="$RANLIB"
STRIP_BIN="$STRIP"

if [[ "$CONFIG_ARCH" == "android_arm32" || "$CONFIG_ARCH" == "android_x86" ]]; then
  WRAPPER_DIR="${BUILD_DIR}/toolchain-wrappers"
  mkdir -p "$WRAPPER_DIR"
  build_common::create_flag_filter_wrapper \
    "${WRAPPER_DIR}/cc" \
    "$CC_BIN" \
    -Wshorten-64-to-32 \
    -Werror=shorten-64-to-32
  build_common::create_flag_filter_wrapper \
    "${WRAPPER_DIR}/cxx" \
    "$CXX_BIN" \
    -Wshorten-64-to-32 \
    -Werror=shorten-64-to-32
  CC_BIN="${WRAPPER_DIR}/cc"
  CXX_BIN="${WRAPPER_DIR}/cxx"
fi

NUM_CORES="$(build_common::default_parallel_jobs)"

cmake_args=(
  -DCMAKE_C_COMPILER="${CC_BIN}"
  -DCMAKE_CXX_COMPILER="${CXX_BIN}"
  -DCMAKE_AR="${AR_BIN}"
  -DCMAKE_RANLIB="${RANLIB_BIN}"
  -DCMAKE_STRIP="${STRIP_BIN}"
  -DCMAKE_ANDROID_STL_TYPE=c++_static
)

if [[ -n "${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE:-}" ]]; then
  cmake_args+=(-DCMAKE_TOOLCHAIN_FILE="${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE}")
fi

if [[ -n "${ANDROID_TOOLCHAIN_TRIPLE:-}" ]]; then
  cmake_args+=(-DCMAKE_C_COMPILER_TARGET="${ANDROID_TOOLCHAIN_TRIPLE}" -DCMAKE_CXX_COMPILER_TARGET="${ANDROID_TOOLCHAIN_TRIPLE}")
fi

if [[ -n "${ANDROID_TOOLCHAIN_CMAKE_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_CMAKE_FLAGS=(${ANDROID_TOOLCHAIN_CMAKE_FLAGS})
  cmake_args+=("${EXTRA_CMAKE_FLAGS[@]}")
fi

build_common::cmake_configure \
  "$PROJECT_ROOT" \
  "$BUILD_DIR" \
  "$EXTRA_FLAGS" \
  "$EXTRA_FLAGS" \
  "${cmake_args[@]}"

build_common::run_cmake_build "$BUILD_DIR" "$NUM_CORES"
