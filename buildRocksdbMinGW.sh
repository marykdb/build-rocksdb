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

MINGW_LINK_FLAGS=""

declare -a cmake_toolchain_flags=()

if [[ -n "${LLVM_MINGW_ROOT:-}" ]]; then
  build_common::prepend_unique_path PATH "${LLVM_MINGW_ROOT}/bin"
fi

case "$ARCH" in
  x86_64)
    TOOLCHAIN_TRIPLE="x86_64-w64-mingw32"
    if command -v "${TOOLCHAIN_TRIPLE}-clang" >/dev/null 2>&1; then
      CC="${TOOLCHAIN_TRIPLE}-clang"
      if command -v "${TOOLCHAIN_TRIPLE}-clang++" >/dev/null 2>&1; then
        CXX="${TOOLCHAIN_TRIPLE}-clang++"
      else
        CXX="${TOOLCHAIN_TRIPLE}-clang"
      fi
    else
      CC="${TOOLCHAIN_TRIPLE}-gcc"
      CXX="${TOOLCHAIN_TRIPLE}-g++"
    fi
    cmake_toolchain_flags=(
      "-DCMAKE_SYSTEM_NAME=Windows"
      "-DCMAKE_SYSTEM_PROCESSOR=x86_64"
    )
    EXTRA_C_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="-march=x86-64 ${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    BUILD_DIR="build/lib/mingw_x86_64"
    ;;
  i686)
    TOOLCHAIN_TRIPLE="i686-w64-mingw32"
    if command -v "${TOOLCHAIN_TRIPLE}-clang" >/dev/null 2>&1; then
      CC="${TOOLCHAIN_TRIPLE}-clang"
      if command -v "${TOOLCHAIN_TRIPLE}-clang++" >/dev/null 2>&1; then
        CXX="${TOOLCHAIN_TRIPLE}-clang++"
      else
        CXX="${TOOLCHAIN_TRIPLE}-clang"
      fi
    else
      CC="${TOOLCHAIN_TRIPLE}-gcc"
      CXX="${TOOLCHAIN_TRIPLE}-g++"
    fi
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
    elif command -v "${TOOLCHAIN_TRIPLE}-clang" >/dev/null 2>&1; then
      CC="${TOOLCHAIN_TRIPLE}-clang"
      if command -v "${TOOLCHAIN_TRIPLE}-clang++" >/dev/null 2>&1; then
        CXX="${TOOLCHAIN_TRIPLE}-clang++"
      else
        CXX="${TOOLCHAIN_TRIPLE}-clang"
      fi
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

build_common::append_unique_flag EXTRA_C_FLAGS "-g"
build_common::append_unique_flag EXTRA_CXX_FLAGS "-g"

if [[ -n "${TOOLCHAIN_TRIPLE:-}" ]]; then
  build_common::ensure_mingw_environment "${TOOLCHAIN_TRIPLE}" "${CC:-}"
  export MINGW_TRIPLE="${TOOLCHAIN_TRIPLE}"

  use_clang=0
  if build_common::compiler_is_clang "${CC:-}"; then
    use_clang=1
  elif build_common::compiler_is_clang "${CXX:-}"; then
    use_clang=1
  fi

  if (( use_clang )); then
    build_common::append_unique_flag EXTRA_C_FLAGS "-femulated-tls"
    build_common::append_unique_flag EXTRA_CXX_FLAGS "-femulated-tls"
    if [[ -z "${MINGW_SYSROOT:-}" ]]; then
      build_common::prefer_llvm_mingw_sysroot "${TOOLCHAIN_TRIPLE}"
    else
      echo "Using preconfigured MinGW sysroot: ${MINGW_SYSROOT}"
    fi
    build_common::append_unique_flag EXTRA_C_FLAGS "--target=${TOOLCHAIN_TRIPLE}"
    build_common::append_unique_flag EXTRA_CXX_FLAGS "--target=${TOOLCHAIN_TRIPLE}"
    build_common::append_unique_flag EXTRA_CXX_FLAGS "-stdlib=libstdc++"
    build_common::append_unique_flag EXTRA_C_FLAGS "-Wno-#warnings"
    build_common::append_unique_flag EXTRA_CXX_FLAGS "-Wno-#warnings"
    build_common::append_unique_flag MINGW_LINK_FLAGS "-unwindlib=libgcc"
    mingw_sysroots=()
    if [[ -n "${MINGW_SYSROOT:-}" ]]; then
      mingw_sysroots+=("${MINGW_SYSROOT}")
    fi
    if [[ -n "${MINGW_FALLBACK_SYSROOT:-}" && "${MINGW_FALLBACK_SYSROOT}" != "${MINGW_SYSROOT:-}" ]]; then
      mingw_sysroots+=("${MINGW_FALLBACK_SYSROOT}")
    fi
    if (( ${#mingw_sysroots[@]} )); then
      mingw_link_dirs=()
      for current_sysroot in "${mingw_sysroots[@]}"; do
        [[ -n "$current_sysroot" ]] || continue
        current_sysroot_parent="$(cd "${current_sysroot}/.." 2>/dev/null && pwd 2>/dev/null || true)"
        candidate_libdirs=("${current_sysroot}/lib")
        if [[ -n "${TOOLCHAIN_TRIPLE:-}" ]]; then
          candidate_libdirs+=("${current_sysroot}/${TOOLCHAIN_TRIPLE}/lib")
        fi
        if [[ -n "$current_sysroot_parent" && "$current_sysroot_parent" != "$current_sysroot" ]]; then
          candidate_libdirs+=("${current_sysroot_parent}/lib")
          if [[ -n "${TOOLCHAIN_TRIPLE:-}" ]]; then
            candidate_libdirs+=("${current_sysroot_parent}/${TOOLCHAIN_TRIPLE}/lib")
          fi
        fi
        for libdir in "${candidate_libdirs[@]}"; do
          if [[ -d "$libdir" ]]; then
            build_common::prepend_unique_path LIBRARY_PATH "$libdir"
            libdir_tool="$(build_common::to_tool_path "$libdir")"
            if [[ -n "$libdir_tool" ]]; then
              build_common::append_unique_flag MINGW_LINK_FLAGS "-L${libdir_tool}"
            fi
          fi
        done

        gcc_search_roots=()
        if [[ -n "${TOOLCHAIN_TRIPLE:-}" && -d "${current_sysroot}/lib/gcc/${TOOLCHAIN_TRIPLE}" ]]; then
          gcc_search_roots+=("${current_sysroot}/lib/gcc/${TOOLCHAIN_TRIPLE}")
        fi
        if [[ -n "$current_sysroot_parent" && "$current_sysroot_parent" != "$current_sysroot" ]]; then
          if [[ -n "${TOOLCHAIN_TRIPLE:-}" && -d "${current_sysroot_parent}/lib/gcc/${TOOLCHAIN_TRIPLE}" ]]; then
            gcc_search_roots+=("${current_sysroot_parent}/lib/gcc/${TOOLCHAIN_TRIPLE}")
          fi
        fi
        for gcc_root in "${gcc_search_roots[@]}"; do
          gcc_version_dir="$(find "$gcc_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
          if [[ -n "$gcc_version_dir" && -d "$gcc_version_dir" ]]; then
            build_common::prepend_unique_path LIBRARY_PATH "$gcc_version_dir"
            gcc_version_tool="$(build_common::to_tool_path "$gcc_version_dir")"
            if [[ -n "$gcc_version_tool" ]]; then
              build_common::append_unique_flag MINGW_LINK_FLAGS "-L${gcc_version_tool}"
            fi
          fi
        done
      done
      export LIBRARY_PATH
    fi
    if [[ -n "${MINGW_LINK_FLAGS}" ]]; then
      cmake_toolchain_flags+=("-DCMAKE_EXE_LINKER_FLAGS=${MINGW_LINK_FLAGS}")
      cmake_toolchain_flags+=("-DCMAKE_SHARED_LINKER_FLAGS=${MINGW_LINK_FLAGS}")
      cmake_toolchain_flags+=("-DCMAKE_MODULE_LINKER_FLAGS=${MINGW_LINK_FLAGS}")
    fi
    echo "Using libstdc++"
  fi

  if (( use_clang )) && [[ -n "${MINGW_SYSROOT:-}" ]]; then
    build_common::apply_mingw_sysroot_flags "${TOOLCHAIN_TRIPLE}" EXTRA_C_FLAGS EXTRA_CXX_FLAGS "" cmake_toolchain_flags
  fi

  build_common::append_unique_array_flag cmake_toolchain_flags "-DCMAKE_C_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
  build_common::append_unique_array_flag cmake_toolchain_flags "-DCMAKE_CXX_COMPILER_TARGET=${TOOLCHAIN_TRIPLE}"
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
