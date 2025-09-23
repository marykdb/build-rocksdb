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

get_num_cores() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo "Error: Unable to determine the number of CPU cores for parallel build." >&2
    exit 1
  fi
}

HOST_OS="$(uname -s)"
BUILD_SUBDIR=""
CC_BIN="${CC:-}"
CXX_BIN="${CXX:-}"
AR_BIN="${AR:-}"
RANLIB_BIN="${RANLIB:-}"
EXTRA_C_FLAGS="-fPIC"
CMAKE_SYSTEM_PROCESSOR=""

case "$ARCH" in
  arm64)
    BUILD_SUBDIR="linux_arm64"
    EXTRA_C_FLAGS+=" -march=armv8-a"
    CMAKE_SYSTEM_PROCESSOR="aarch64"
    if [[ -z "$CC_BIN" || -z "$CXX_BIN" ]]; then
      if [[ "$HOST_OS" == "Linux" ]]; then
        CC_BIN="${CC_BIN:-$(command -v aarch64-linux-gnu-gcc 2>/dev/null || true)}"
        CXX_BIN="${CXX_BIN:-$(command -v aarch64-linux-gnu-g++ 2>/dev/null || true)}"
        AR_BIN="${AR_BIN:-$(command -v aarch64-linux-gnu-ar 2>/dev/null || true)}"
        RANLIB_BIN="${RANLIB_BIN:-$(command -v aarch64-linux-gnu-ranlib 2>/dev/null || true)}"
      else
        konan_deps_dir="${HOME}/.konan/dependencies"
        konan_cc=("${konan_deps_dir}"/aarch64-unknown-linux-gnu-gcc-*/bin/aarch64-unknown-linux-gnu-gcc)
        konan_cxx=("${konan_deps_dir}"/aarch64-unknown-linux-gnu-gcc-*/bin/aarch64-unknown-linux-gnu-g++)
        if [[ -z "$CC_BIN" && -x "${konan_cc[0]}" ]]; then
          CC_BIN="${konan_cc[0]}"
        fi
        if [[ -z "$CXX_BIN" && -x "${konan_cxx[0]}" ]]; then
          CXX_BIN="${konan_cxx[0]}"
        fi
      fi
    fi
    ;;
  x86_64)
    BUILD_SUBDIR="linux_x86_64"
    EXTRA_C_FLAGS+=" -march=x86-64"
    CMAKE_SYSTEM_PROCESSOR="x86_64"
    if [[ -z "$CC_BIN" || -z "$CXX_BIN" ]]; then
      if [[ "$HOST_OS" == "Linux" ]]; then
        CC_BIN="${CC_BIN:-$(command -v gcc 2>/dev/null || true)}"
        CXX_BIN="${CXX_BIN:-$(command -v g++ 2>/dev/null || true)}"
      else
        konan_deps_dir="${HOME}/.konan/dependencies"
        konan_cc=("${konan_deps_dir}"/x86_64-unknown-linux-gnu-gcc-*/bin/x86_64-unknown-linux-gnu-gcc)
        konan_cxx=("${konan_deps_dir}"/x86_64-unknown-linux-gnu-gcc-*/bin/x86_64-unknown-linux-gnu-g++)
        if [[ -z "$CC_BIN" && -x "${konan_cc[0]}" ]]; then
          CC_BIN="${konan_cc[0]}"
        fi
        if [[ -z "$CXX_BIN" && -x "${konan_cxx[0]}" ]]; then
          CXX_BIN="${konan_cxx[0]}"
        fi
      fi
    fi
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
 esac

if [[ -z "$CC_BIN" || -z "$CXX_BIN" ]]; then
  echo "Missing cross-compilation toolchain for linux_${ARCH}." >&2
  exit 1
fi

if [[ -z "$AR_BIN" ]]; then
  AR_BIN="ar"
fi
if [[ -z "$RANLIB_BIN" ]]; then
  RANLIB_BIN="ranlib"
fi

BUILD_DIR="build/lib/${BUILD_SUBDIR}"
SNAPPY_PREFIX="${BUILD_DIR}/deps/snappy"
SNAPPY_CMAKE_DIR="${SNAPPY_PREFIX}/lib/cmake/Snappy"
DEPENDENCY_HEADERS_DIR="${REPO_ROOT}/build/include/dependencies"
DEPENDENCY_INCLUDE_ROOT="${REPO_ROOT}/build/include"
DEPENDENCY_LIB_DIR="${REPO_ROOT}/${BUILD_DIR}"
SNAPPY_CONFIG_PATH="${REPO_ROOT}/${SNAPPY_CMAKE_DIR}/SnappyConfig.cmake"

if [[ ! -f "${SNAPPY_CONFIG_PATH}" ]]; then
  echo "Warning: Expected Snappy CMake package at ${SNAPPY_CONFIG_PATH} not found. The build may fail if dependencies have not been prepared." >&2
fi

if [[ -f "${BUILD_DIR}/librocksdb.a" ]]; then
  echo "** BUILD SKIPPED: ${BUILD_DIR}/librocksdb.a already exists **"
  exit 0
fi

if [[ -f "${BUILD_DIR}/rocksdb-build/librocksdb.a" ]]; then
  echo "** BUILD SKIPPED: ${BUILD_DIR}/rocksdb-build/librocksdb.a already exists **"
  exit 0
fi

mkdir -p "$BUILD_DIR"

NUM_CORES="$(get_num_cores)"
if [[ -n "${ROCKSDB_MAKE_JOBS:-}" ]]; then
  NUM_CORES="${ROCKSDB_MAKE_JOBS}"
elif [[ "$ARCH" == "arm64" && "$NUM_CORES" -gt 2 ]]; then
  NUM_CORES=2
fi

CMAKE_TOOLCHAIN_ARGS=(-DCMAKE_SYSTEM_NAME=Linux)
if [[ -n "$CMAKE_SYSTEM_PROCESSOR" ]]; then
  CMAKE_TOOLCHAIN_ARGS+=(-DCMAKE_SYSTEM_PROCESSOR="${CMAKE_SYSTEM_PROCESSOR}")
fi

CMAKE_ARGS=(
  -S "rocksdb"
  -B "$BUILD_DIR"
  "${CMAKE_TOOLCHAIN_ARGS[@]}"
  -DCMAKE_C_COMPILER="${CC_BIN}"
  -DCMAKE_CXX_COMPILER="${CXX_BIN}"
  -DCMAKE_AR="${AR_BIN}"
  -DCMAKE_RANLIB="${RANLIB_BIN}"
  -DCMAKE_PREFIX_PATH="${REPO_ROOT}/${SNAPPY_PREFIX}"
  -DSnappy_DIR="${REPO_ROOT}/${SNAPPY_CMAKE_DIR}"
  -DCMAKE_INCLUDE_PATH="${DEPENDENCY_INCLUDE_ROOT};${DEPENDENCY_HEADERS_DIR}"
  -DCMAKE_LIBRARY_PATH="${DEPENDENCY_LIB_DIR}"
  -DZLIB_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}"
  -DZLIB_LIBRARY="${DEPENDENCY_LIB_DIR}/libz.a"
  -DZLIB_USE_STATIC_LIBS=ON
  -DBZIP2_INCLUDE_DIR="${DEPENDENCY_HEADERS_DIR}"
  -DBZIP2_LIBRARIES="${DEPENDENCY_LIB_DIR}/libbz2.a"
  -Dlz4_INCLUDE_DIRS="${DEPENDENCY_HEADERS_DIR}"
  -Dlz4_LIBRARIES="${DEPENDENCY_LIB_DIR}/liblz4.a"
  -DZSTD_INCLUDE_DIRS="${DEPENDENCY_HEADERS_DIR}"
  -DZSTD_LIBRARIES="${DEPENDENCY_LIB_DIR}/libzstd.a"
  -DZSTD_LIBRARIES="${DEPENDENCY_LIB_DIR}/libzstd.a"
  -DCMAKE_C_FLAGS="${EXTRA_C_FLAGS}"
  -DCMAKE_CXX_FLAGS="${EXTRA_C_FLAGS}"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${BUILD_DIR}"
  -DPORTABLE=1
  -DWITH_GFLAGS=OFF
  -DWITH_SNAPPY=ON
  -DWITH_LZ4=ON
  -DWITH_ZLIB=ON
  -DWITH_ZSTD=ON
  -DWITH_BZ2=ON
  -DROCKSDB_BUILD_SHARED=OFF
  -DROCKSDB_BUILD_STATIC=ON
  -DWITH_TESTS=OFF
  -DWITH_BENCHMARK_TOOLS=OFF
  -DWITH_TOOLS=OFF
  -DWITH_JNI=OFF
  -DWITH_JEMALLOC=OFF
  -DFAIL_ON_WARNINGS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

cmake "${CMAKE_ARGS[@]}"

echo "Building RocksDB with CMake..."
BUILD_LOG="${BUILD_DIR}/build.log"
set +e
cmake --build "$BUILD_DIR" --config Release --target rocksdb --parallel "${NUM_CORES}" >"$BUILD_LOG" 2>&1
build_status=$?
set -e

if [[ -f "${BUILD_DIR}/librocksdb.a" ]]; then
  echo "** BUILD SUCCEEDED for ${BUILD_DIR} **"
elif [[ -f "${BUILD_DIR}/rocksdb-build/librocksdb.a" ]]; then
  echo "** BUILD SUCCEEDED for ${BUILD_DIR} **"
elif grep -q "up-to-date" "$BUILD_LOG"; then
  echo "** BUILD NOT NEEDED for ${BUILD_DIR} (Already up to date) **"
elif [[ $build_status -ne 0 ]]; then
  echo "** BUILD FAILED for ${BUILD_DIR} **"
  echo "—— Tail of build log ————————————————"
  tail -n 400 "$BUILD_LOG" || true
  echo "———————————————————————————————————"
  echo "Full log at: $BUILD_LOG"
  echo "Contents of ${BUILD_DIR} after failure:" >&2
  find "$BUILD_DIR" -maxdepth 2 -type f -print >&2 || true
  exit 1
else
  echo "** BUILD RESULT UNKNOWN; neither artifact nor explicit failure detected (check $BUILD_LOG) **"
  exit 1
fi

echo "✅ RocksDB build completed successfully for $PLATFORM"
