#!/usr/bin/env bash

set -euo pipefail

ARCH=""
for arg in "$@"; do
  case $arg in
    --arch=*)
      ARCH="${arg#*=}"
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

if [ -z "${ARCH}" ]; then
  echo "Usage: $0 --arch=x86_64|arm64"
  exit 1
fi

WINDOWS_MIN_VERSION_C_FLAGS="-U_WIN32_WINNT -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00 -pthread -include stdint.h"
WINDOWS_MIN_VERSION_CXX_FLAGS="${WINDOWS_MIN_VERSION_C_FLAGS} -include system_error"

if [[ -n "${LLVM_MINGW_ROOT:-}" && -d "${LLVM_MINGW_ROOT}/bin" ]]; then
  export PATH="${LLVM_MINGW_ROOT}/bin:${PATH}"
fi

case "$ARCH" in
  x86_64)
    CC="x86_64-w64-mingw32-gcc"
    CXX="x86_64-w64-mingw32-g++"
    CMAKE_TOOLCHAIN_FLAGS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64"
    EXTRA_C_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_x86_64"
    ;;
  i686)
    CC="i686-w64-mingw32-gcc"
    CXX="i686-w64-mingw32-g++"
    CMAKE_TOOLCHAIN_FLAGS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=i686"
    EXTRA_C_FLAGS="-march=i686 ${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="-march=i686 ${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_i686"
    ;;
  arm64|aarch64)
    TOOLCHAIN_TRIPLE="aarch64-w64-mingw32"
    if command -v "${TOOLCHAIN_TRIPLE}-gcc" >/dev/null 2>&1; then
      CC="${TOOLCHAIN_TRIPLE}-gcc"
      CXX="${TOOLCHAIN_TRIPLE}-g++"
      USING_CLANG=0
    elif command -v "${TOOLCHAIN_TRIPLE}-clang" >/dev/null 2>&1; then
      CC="${TOOLCHAIN_TRIPLE}-clang"
      if command -v "${TOOLCHAIN_TRIPLE}-clang++" >/dev/null 2>&1; then
        CXX="${TOOLCHAIN_TRIPLE}-clang++"
      else
        CXX="${TOOLCHAIN_TRIPLE}-clang"
      fi
      USING_CLANG=1
    else
      echo "Unsupported ARM64 toolchain: expected ${TOOLCHAIN_TRIPLE}-gcc or ${TOOLCHAIN_TRIPLE}-clang in PATH" >&2
      exit 1
    fi
    CMAKE_TOOLCHAIN_FLAGS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64"
    if [[ "${USING_CLANG:-0}" -eq 1 ]]; then
      CMAKE_TOOLCHAIN_FLAGS+=" -DCMAKE_C_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
      CMAKE_TOOLCHAIN_FLAGS+=" -DCMAKE_CXX_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
    fi
    EXTRA_C_FLAGS="${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_arm64"
    ;;
  *)
    echo "Unsupported ARCH: $ARCH"
    exit 1
    ;;
esac

echo "Building RocksDB for Windows (MinGW) with ARCH=${ARCH}"
echo "Compiler: $CC / $CXX"

# Ensure we run from the repository root so relative paths resolve correctly
cd "$(dirname "$0")" || { echo "Failed to navigate to repository root"; exit 1; }
REPO_ROOT="$(pwd)"
# shellcheck source=./scripts/build-rocksdb-common.sh
source "${REPO_ROOT}/scripts/build-rocksdb-common.sh"

BUILD_DIR="${REPO_ROOT}/${BUILD_DIR}"

# Check if the output library already exists
if build_common::check_existing_artifacts "$BUILD_DIR"; then
  exit 0
fi

mkdir -p "$BUILD_DIR"

NUM_CORES="$(build_common::default_parallel_jobs)"

cmake_args=()
if [[ -n "${CMAKE_TOOLCHAIN_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  TOOLCHAIN_FLAGS=(${CMAKE_TOOLCHAIN_FLAGS})
  cmake_args+=("${TOOLCHAIN_FLAGS[@]}")
fi

cmake_args+=(
  -G "Ninja"
  -DCMAKE_MAKE_PROGRAM=ninja
)

cmake_args+=(
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
)

build_common::cmake_configure \
  "$REPO_ROOT" \
  "$BUILD_DIR" \
  "$EXTRA_C_FLAGS" \
  "$EXTRA_CXX_FLAGS" \
  "${cmake_args[@]}"

build_common::run_cmake_build "$BUILD_DIR" "$NUM_CORES"
