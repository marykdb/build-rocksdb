#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# shellcheck source=./build-rocksdb-common.sh
source "${REPO_ROOT}/build-rocksdb-common.sh"

PLATFORM="macos"
SIMULATOR=false
ARCH=""

for arg in "$@"; do
  case $arg in
    --platform=*)
      PLATFORM="${arg#*=}"
      ;;
    --simulator)
      SIMULATOR=true
      ;;
    --arch=*)
      ARCH="${arg#*=}"
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PLATFORM" || -z "$ARCH" ]]; then
  echo "Usage: $0 --platform=<ios|macos|watchos|tvos> [--simulator] --arch=<arch>" >&2
  exit 1
fi

echo "Building RocksDB for: $PLATFORM, Arch: $ARCH, Simulator?: $SIMULATOR"

SDK_NAME=""
MIN_VERSION=""
MIN_FLAG=""
TARGET_TRIPLE=""
CMAKE_SYSTEM_NAME="Darwin"

case "$PLATFORM" in
  ios)
    SDK_NAME=$([[ "$SIMULATOR" == true ]] && echo "iphonesimulator" || echo "iphoneos")
    MIN_VERSION="13.0"
    if [[ "$SIMULATOR" == true ]]; then
      MIN_FLAG="-mios-simulator-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-target ${ARCH}-apple-ios${MIN_VERSION}-simulator"
    else
      MIN_FLAG="-miphoneos-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-arch ${ARCH}"
    fi
    CMAKE_SYSTEM_NAME="iOS"
    ;;
  macos)
    SDK_NAME="macosx"
    MIN_VERSION="11.0"
    MIN_FLAG="-mmacosx-version-min=${MIN_VERSION}"
    TARGET_TRIPLE="-arch ${ARCH}"
    CMAKE_SYSTEM_NAME="Darwin"
    ;;
  watchos)
    SDK_NAME=$([[ "$SIMULATOR" == true ]] && echo "watchsimulator" || echo "watchos")
    MIN_VERSION="7.0"
    if [[ "$SIMULATOR" == true ]]; then
      MIN_FLAG="-mwatchos-simulator-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-target ${ARCH}-apple-watchos${MIN_VERSION}-simulator"
    else
      MIN_FLAG="-mwatchos-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-arch ${ARCH}"
    fi
    CMAKE_SYSTEM_NAME="watchOS"
    ;;
  tvos)
    SDK_NAME=$([[ "$SIMULATOR" == true ]] && echo "appletvsimulator" || echo "appletvos")
    MIN_VERSION="13.0"
    if [[ "$SIMULATOR" == true ]]; then
      MIN_FLAG="-mtvos-simulator-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-target ${ARCH}-apple-tvos${MIN_VERSION}-simulator"
    else
      MIN_FLAG="-mtvos-version-min=${MIN_VERSION}"
      TARGET_TRIPLE="-arch ${ARCH}"
    fi
    CMAKE_SYSTEM_NAME="tvOS"
    ;;
  *)
    echo "Unsupported platform: $PLATFORM" >&2
    exit 1
    ;;
esac

SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
if [[ -z "$SDK_PATH" ]]; then
  echo "Failed to get SDK path for $SDK_NAME" >&2
  exit 1
fi

SIM_SUFFIX=$([[ "$SIMULATOR" == true ]] && echo "_simulator" || echo "")
BUILD_DIR="${REPO_ROOT}/build/lib/${PLATFORM}${SIM_SUFFIX}_${ARCH}"

EXTRA_C_FLAGS="${MIN_FLAG} ${TARGET_TRIPLE} -g -ffunction-sections -fdata-sections -isysroot ${SDK_PATH} -I${REPO_ROOT}/build/include -I${REPO_ROOT}/build/include/dependencies -DZLIB -DBZIP2 -DSNAPPY -DLZ4 -DZSTD"
EXTRA_CXX_FLAGS="$EXTRA_C_FLAGS"

# Endianness and libc differences on Apple mobile platforms
if [[ "$PLATFORM" == "ios" || "$PLATFORM" == "tvos" || "$PLATFORM" == "watchos" ]]; then
  # Endianness: map glibc-style macros to Clang's Apple macros
  EXTRA_C_FLAGS+=" -D__BYTE_ORDER=__BYTE_ORDER__ -D__LITTLE_ENDIAN=__ORDER_LITTLE_ENDIAN__"
  EXTRA_CXX_FLAGS+=" -D__BYTE_ORDER=__BYTE_ORDER__ -D__LITTLE_ENDIAN=__ORDER_LITTLE_ENDIAN__"

  # libc differences on Apple SDKs:
  # - fread_unlocked is unavailable; use fread instead
  # - O_DIRECT is unsupported; define to 0 so flags |= O_DIRECT compiles to a no-op
  EXTRA_C_FLAGS+=" -Dfread_unlocked=fread -DO_DIRECT=0"
  EXTRA_CXX_FLAGS+=" -Dfread_unlocked=fread -DO_DIRECT=0"
fi

if [[ "$ARCH" == "arm64_32" ]]; then
  EXTRA_C_FLAGS+=" -Wno-shorten-64-to-32"
  EXTRA_CXX_FLAGS+=" -Wno-shorten-64-to-32"
fi

CC_BIN="${CC:-}"
CXX_BIN="${CXX:-}"
if [[ -z "$CC_BIN" ]]; then
  CC_BIN="$(xcrun --sdk "$SDK_NAME" --find clang)"
fi
if [[ -z "$CXX_BIN" ]]; then
  CXX_BIN="$(xcrun --sdk "$SDK_NAME" --find clang++)"
fi

# Archive and strip tools (prefer Xcode's LLVM variants)
AR_BIN="${AR:-$(xcrun --sdk "$SDK_NAME" --find llvm-ar 2>/dev/null || command -v ar || true)}"
RANLIB_BIN="${RANLIB:-$(xcrun --sdk "$SDK_NAME" --find llvm-ranlib 2>/dev/null || command -v ranlib || true)}"
STRIP_BIN="${STRIP:-$(xcrun --sdk "$SDK_NAME" --find strip 2>/dev/null || true)}"

if build_common::check_existing_artifacts "$BUILD_DIR"; then
  exit 0
fi

mkdir -p "$BUILD_DIR"

if [[ "$ARCH" == "arm64_32" ]]; then
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
  -DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}"
  -DCMAKE_OSX_SYSROOT="${SDK_PATH}"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_VERSION}"
  -DCMAKE_C_COMPILER="${CC_BIN}"
  -DCMAKE_CXX_COMPILER="${CXX_BIN}"
  -DCMAKE_AR="${AR_BIN}"
  -DCMAKE_RANLIB="${RANLIB_BIN}"
)

if [[ -n "$STRIP_BIN" ]]; then
  cmake_args+=(-DCMAKE_STRIP="${STRIP_BIN}")
fi

if [[ -n "$ARCH" ]]; then
  cmake_args+=(-DCMAKE_OSX_ARCHITECTURES="${ARCH}")
fi

build_common::cmake_configure \
  "$REPO_ROOT" \
  "$BUILD_DIR" \
  "$EXTRA_C_FLAGS" \
  "$EXTRA_CXX_FLAGS" \
  "${cmake_args[@]}"

build_common::run_cmake_build "$BUILD_DIR" "$NUM_CORES"
