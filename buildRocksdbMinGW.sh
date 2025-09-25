#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# shellcheck source=./build-rocksdb-common.sh
source "${REPO_ROOT}/build-rocksdb-common.sh"

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

declare -a cmake_toolchain_flags=()
USING_CLANG=0

if [[ -n "${MINGW_GCC_SYSROOT:-}" ]]; then
  build_common::prepend_unique_path PATH "${MINGW_GCC_SYSROOT}/bin"
  if [[ -z "${LLVM_MINGW_ROOT:-}" ]]; then
    export LLVM_MINGW_ROOT="${MINGW_GCC_SYSROOT}"
  fi
fi

if [[ -n "${LLVM_MINGW_ROOT:-}" ]]; then
  build_common::prepend_unique_path PATH "${LLVM_MINGW_ROOT}/bin"
fi

case "$ARCH" in
  x86_64)
    TOOLCHAIN_TRIPLE="x86_64-w64-mingw32"
    CC="${TOOLCHAIN_TRIPLE}-gcc"
    CXX="${TOOLCHAIN_TRIPLE}-g++"
    cmake_toolchain_flags=(
      "-DCMAKE_SYSTEM_NAME=Windows"
      "-DCMAKE_SYSTEM_PROCESSOR=x86_64"
    )
    EXTRA_C_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_x86_64"
    if ! command -v "$CC" >/dev/null 2>&1; then
      echo "Missing GCC toolchain binary: $CC" >&2
      echo "Ensure a GCC-based MinGW-w64 toolchain (e.g. Kotlin/Native's msys2 bundle) is on PATH." >&2
      exit 1
    fi
    if ! command -v "$CXX" >/dev/null 2>&1; then
      echo "Missing GCC toolchain binary: $CXX" >&2
      echo "Ensure a GCC-based MinGW-w64 toolchain (e.g. Kotlin/Native's msys2 bundle) is on PATH." >&2
      exit 1
    fi
    ;;
  i686)
    TOOLCHAIN_TRIPLE="i686-w64-mingw32"
    CC="${TOOLCHAIN_TRIPLE}-gcc"
    CXX="${TOOLCHAIN_TRIPLE}-g++"
    cmake_toolchain_flags=(
      "-DCMAKE_SYSTEM_NAME=Windows"
      "-DCMAKE_SYSTEM_PROCESSOR=i686"
    )
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
    cmake_toolchain_flags=(
      "-DCMAKE_SYSTEM_NAME=Windows"
      "-DCMAKE_SYSTEM_PROCESSOR=ARM64"
    )
    EXTRA_C_FLAGS="${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_arm64"
    ;;
  *)
    echo "Unsupported ARCH: $ARCH"
    exit 1
    ;;
esac

if [[ -n "${TOOLCHAIN_TRIPLE:-}" ]]; then
  build_common::ensure_mingw_environment "${TOOLCHAIN_TRIPLE}" "${CC:-}"
  export MINGW_TRIPLE="${TOOLCHAIN_TRIPLE}"

  if (( USING_CLANG )); then
    build_common::append_unique_flag EXTRA_C_FLAGS "--target=${TOOLCHAIN_TRIPLE}"
    build_common::append_unique_flag EXTRA_CXX_FLAGS "--target=${TOOLCHAIN_TRIPLE}"
  fi

  if [[ -n "${MINGW_SYSROOT:-}" ]]; then
    build_common::apply_mingw_sysroot_flags "${TOOLCHAIN_TRIPLE}" EXTRA_C_FLAGS EXTRA_CXX_FLAGS "" cmake_toolchain_flags
  fi

  if (( USING_CLANG )); then
    build_common::append_unique_array_flag cmake_toolchain_flags "-DCMAKE_C_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
    build_common::append_unique_array_flag cmake_toolchain_flags "-DCMAKE_CXX_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
  fi
fi

echo "Building RocksDB for Windows (MinGW) with ARCH=${ARCH}"
echo "Compiler: $CC / $CXX"

# Ensure we run from the repository root so relative paths resolve correctly
cd "${REPO_ROOT}" || { echo "Failed to navigate to repository root"; exit 1; }

BUILD_DIR="${REPO_ROOT}/${BUILD_DIR}"

# Check if the output library already exists
if build_common::check_existing_artifacts "$BUILD_DIR"; then
  exit 0
fi

mkdir -p "$BUILD_DIR"

NUM_CORES="$(build_common::default_parallel_jobs)"

cmake_args=()
if ((${#cmake_toolchain_flags[@]})); then
  cmake_args+=("${cmake_toolchain_flags[@]}")
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
