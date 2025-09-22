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
    OBJ_DIR="build/lib/mingw_x86_64"
    ;;
  i686)
    CC="i686-w64-mingw32-gcc"
    CXX="i686-w64-mingw32-g++"
    CMAKE_TOOLCHAIN_FLAGS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=i686"
    EXTRA_C_FLAGS="-march=i686 ${WINDOWS_MIN_VERSION_C_FLAGS}"
    EXTRA_CXX_FLAGS="-march=i686 ${WINDOWS_MIN_VERSION_CXX_FLAGS}"
    OBJ_DIR="build/lib/mingw_i686"
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
    OBJ_DIR="build/lib/mingw_arm64"
    ;;
  *)
    echo "Unsupported ARCH: $ARCH"
    exit 1
    ;;
esac

get_num_cores() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    sysctl -n hw.ncpu
  else
    echo "Error: Unable to determine the number of CPU cores for parallel build." >&2
    exit 1
  fi
}

echo "Building RocksDB for Windows (MinGW) with ARCH=${ARCH}"
echo "Compiler: $CC / $CXX"

# Ensure we run from the repository root so relative paths resolve correctly
cd "$(dirname "$0")" || { echo "Failed to navigate to repository root"; exit 1; }
REPO_ROOT="$(pwd)"
DEPENDENCY_DIR="$OBJ_DIR"
SNAPPY_PREFIX="${DEPENDENCY_DIR}/deps/snappy"
SNAPPY_CMAKE_DIR="${SNAPPY_PREFIX}/lib/cmake/Snappy"

DEPENDENCY_HEADERS_DIR="${REPO_ROOT}/build/include/dependencies"
DEPENDENCY_INCLUDE_ROOT="${REPO_ROOT}/build/include"
DEPENDENCY_LIB_DIR="${REPO_ROOT}/${OBJ_DIR}"

SNAPPY_CONFIG_PATH="${REPO_ROOT}/${SNAPPY_CMAKE_DIR}/SnappyConfig.cmake"
if [[ ! -f "${SNAPPY_CONFIG_PATH}" ]]; then
  echo "Warning: Expected Snappy CMake package at ${SNAPPY_CONFIG_PATH} not found. The build may fail if dependencies have not been prepared." >&2
fi

# Check if the output library already exists
if [ -f "${OBJ_DIR}/librocksdb.a" ]; then
  echo "** BUILD SKIPPED: ${OBJ_DIR}/librocksdb.a already exists **"
  exit 0
fi

if [ -f "${OBJ_DIR}/rocksdb-build/librocksdb.a" ]; then
  echo "** BUILD SKIPPED: ${OBJ_DIR}/rocksdb-build/librocksdb.a already exists **"
  exit 0
fi

# Create build directory if it doesn't exist
mkdir -p "$OBJ_DIR"

NUM_CORES=$(get_num_cores)

# Configure with CMake
echo "Configuring RocksDB with CMake..."
cmake -S "rocksdb" -B "$OBJ_DIR" \
  $CMAKE_TOOLCHAIN_FLAGS \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_PREFIX_PATH="${REPO_ROOT}/${SNAPPY_PREFIX}" \
  -DSnappy_DIR="${REPO_ROOT}/${SNAPPY_CMAKE_DIR}" \
  -DCMAKE_INCLUDE_PATH="${DEPENDENCY_INCLUDE_ROOT};${DEPENDENCY_HEADERS_DIR}" \
  -DCMAKE_LIBRARY_PATH="${DEPENDENCY_LIB_DIR}" \
  -DZLIB_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}" \
  -DZLIB_LIBRARY="${DEPENDENCY_LIB_DIR}/libz.a" \
  -DZLIB_USE_STATIC_LIBS=ON \
  -DBZIP2_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}" \
  -DBZIP2_LIBRARIES="${DEPENDENCY_LIB_DIR}/libbz2.a" \
  -DLZ4_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}" \
  -DLZ4_LIBRARY="${DEPENDENCY_LIB_DIR}/liblz4.a" \
  -DZSTD_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}" \
  -DZSTD_LIBRARY="${DEPENDENCY_LIB_DIR}/libzstd.a" \
  -DZSTD_LIBRARIES="${DEPENDENCY_LIB_DIR}/libzstd.a" \
  -DCMAKE_C_FLAGS="$EXTRA_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="$EXTRA_CXX_FLAGS" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPORTABLE=1 \
  -DCMAKE_INSTALL_PREFIX="$OBJ_DIR" \
  -DWITH_GFLAGS=OFF \
  -DWITH_SNAPPY=ON \
  -DWITH_LZ4=ON \
  -DWITH_ZLIB=ON \
  -DWITH_ZSTD=ON \
  -DWITH_BZ2=ON \
  -DROCKSDB_BUILD_SHARED=OFF \
  -DFAIL_ON_WARNINGS=OFF \
  -DWITH_TESTS=OFF \
  -DWITH_BENCHMARK_TOOLS=OFF \
  -DWITH_TOOLS=OFF \
  -DWITH_JNI=OFF \
  -DWITH_JEMALLOC=OFF \
  -DROCKSDB_BUILD_STATIC=ON

# Build with CMake
echo "Building RocksDB with CMake..."
output=$(cmake --build "$OBJ_DIR" --config Release -j --target rocksdb --parallel "${NUM_CORES}" 2>&1)

# Check if the library was built successfully
if [ -f "${OBJ_DIR}/librocksdb.a" ]; then
  echo "** BUILD SUCCEEDED for $ARCH **"
elif [ -f "${OBJ_DIR}/rocksdb-build/librocksdb.a" ]; then
  echo "** BUILD SUCCEEDED for $ARCH **"
elif echo "$output" | grep -q "up-to-date"; then
  echo "** BUILD NOT NEEDED for $ARCH (Already up to date) **"
else
  echo "** BUILD FAILED for $ARCH **"
  echo "$output"
  echo "Contents of ${OBJ_DIR} after failure:" >&2
  find "$OBJ_DIR" -maxdepth 2 -type f -print >&2 || true
  exit 1
fi
