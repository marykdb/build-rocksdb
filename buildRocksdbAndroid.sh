#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

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
mkdir -p "$BUILD_DIR"

if [[ -f "${BUILD_DIR}/librocksdb.a" ]]; then
  echo "** BUILD SKIPPED: ${BUILD_DIR}/librocksdb.a already exists **"
  exit 0
fi

EXTRA_FLAGS="-fPIC -DANDROID -I${PROJECT_ROOT}/build/include -I${PROJECT_ROOT}/build/include/dependencies"
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
  export ANDROID_REAL_CC="$CC_BIN"
  export ANDROID_REAL_CXX="$CXX_BIN"
  WRAPPER_DIR="${BUILD_DIR}/toolchain-wrappers"
  mkdir -p "$WRAPPER_DIR"
  cat >"${WRAPPER_DIR}/cc" <<'WRAP_CC'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    -Wshorten-64-to-32|-Werror=shorten-64-to-32)
      continue
      ;;
  esac
  args+=("$arg")
 done
exec "$ANDROID_REAL_CC" "${args[@]}"
WRAP_CC
  cat >"${WRAPPER_DIR}/cxx" <<'WRAP_CXX'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    -Wshorten-64-to-32|-Werror=shorten-64-to-32)
      continue
      ;;
  esac
  args+=("$arg")
 done
exec "$ANDROID_REAL_CXX" "${args[@]}"
WRAP_CXX
  chmod +x "${WRAPPER_DIR}/cc" "${WRAPPER_DIR}/cxx"
  CC_BIN="${WRAPPER_DIR}/cc"
  CXX_BIN="${WRAPPER_DIR}/cxx"
fi

DEPENDENCY_HEADERS_DIR="${PROJECT_ROOT}/build/include/dependencies"
DEPENDENCY_INCLUDE_ROOT="${PROJECT_ROOT}/build/include"
DEPENDENCY_LIB_DIR="${BUILD_DIR}"
SNAPPY_PREFIX="${BUILD_DIR}/deps/snappy"
SNAPPY_CMAKE_DIR="${SNAPPY_PREFIX}/lib/cmake/Snappy"
SNAPPY_CONFIG_PATH="${SNAPPY_CMAKE_DIR}/SnappyConfig.cmake"

if [[ ! -f "${SNAPPY_CONFIG_PATH}" ]]; then
  echo "Warning: Expected Snappy CMake package at ${SNAPPY_CONFIG_PATH} not found. The build may fail if dependencies have not been prepared." >&2
fi

get_num_cores() {
  if command -v nproc >/dev/null 2>&1; then
    nproc 2>/dev/null || echo 4
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

NUM_CORES="$(get_num_cores)"

CMAKE_ARGS=(
  -S "rocksdb"
  -B "$BUILD_DIR"
  -DCMAKE_C_COMPILER="${CC_BIN}"
  -DCMAKE_CXX_COMPILER="${CXX_BIN}"
  -DCMAKE_AR="${AR_BIN}"
  -DCMAKE_RANLIB="${RANLIB_BIN}"
  -DCMAKE_STRIP="${STRIP_BIN}"
  -DCMAKE_PREFIX_PATH="${SNAPPY_PREFIX}"
  -DSnappy_DIR="${SNAPPY_CMAKE_DIR}"
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
  -DCMAKE_C_FLAGS="${EXTRA_FLAGS}"
  -DCMAKE_CXX_FLAGS="${EXTRA_FLAGS}"
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
  -DCMAKE_ANDROID_STL_TYPE=c++_static
)

if [[ -n "${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE:-}" ]]; then
  CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE="${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE}")
fi

if [[ -n "${ANDROID_TOOLCHAIN_TRIPLE:-}" ]]; then
  CMAKE_ARGS+=(-DCMAKE_C_COMPILER_TARGET="${ANDROID_TOOLCHAIN_TRIPLE}" -DCMAKE_CXX_COMPILER_TARGET="${ANDROID_TOOLCHAIN_TRIPLE}")
fi

if [[ -n "${ANDROID_TOOLCHAIN_CMAKE_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_CMAKE_FLAGS=(${ANDROID_TOOLCHAIN_CMAKE_FLAGS})
  CMAKE_ARGS+=("${EXTRA_CMAKE_FLAGS[@]}")
fi

cmake "${CMAKE_ARGS[@]}"

echo "Building RocksDB with CMake..."
BUILD_LOG="${BUILD_DIR}/build.log"
set +e
cmake --build "$BUILD_DIR" --config Release --target rocksdb --parallel "${NUM_CORES}" >"$BUILD_LOG" 2>&1
build_status=$?
set -e

if [[ -f "${BUILD_DIR}/librocksdb.a" ]]; then
  echo "** BUILD SUCCEEDED for ${BUILD_DIR} **"
  exit 0
elif [[ -f "${BUILD_DIR}/rocksdb-build/librocksdb.a" ]]; then
  echo "** BUILD SUCCEEDED for ${BUILD_DIR} **"
  exit 0
elif grep -q "up-to-date" "$BUILD_LOG"; then
  echo "** BUILD NOT NEEDED for ${BUILD_DIR} (Already up to date) **"
  exit 0
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
