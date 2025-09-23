#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

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

EXTRA_C_FLAGS="${MIN_FLAG} ${TARGET_TRIPLE} -g0 -ffunction-sections -fdata-sections -isysroot ${SDK_PATH} -I${REPO_ROOT}/build/include -I${REPO_ROOT}/build/include/dependencies -DZLIB -DBZIP2 -DSNAPPY -DLZ4 -DZSTD"
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

mkdir -p "$BUILD_DIR"

CC_BIN="${CC:-}"
CXX_BIN="${CXX:-}"
if [[ -z "$CC_BIN" ]]; then
  CC_BIN="$(xcrun --sdk "$SDK_NAME" --find clang)"
fi
if [[ -z "$CXX_BIN" ]]; then
  CXX_BIN="$(xcrun --sdk "$SDK_NAME" --find clang++)"
fi

if [[ "$ARCH" == "arm64_32" ]]; then
  export APPLE_REAL_CC="$CC_BIN"
  export APPLE_REAL_CXX="$CXX_BIN"
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
exec "$APPLE_REAL_CC" "${args[@]}"
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
exec "$APPLE_REAL_CXX" "${args[@]}"
WRAP_CXX
  chmod +x "${WRAPPER_DIR}/cc" "${WRAPPER_DIR}/cxx"
  CC_BIN="${WRAPPER_DIR}/cc"
  CXX_BIN="${WRAPPER_DIR}/cxx"
fi

# Archive and strip tools (prefer Xcode's LLVM variants)
AR_BIN="${AR:-$(xcrun --sdk "$SDK_NAME" --find llvm-ar 2>/dev/null || command -v ar || true)}"
RANLIB_BIN="${RANLIB:-$(xcrun --sdk "$SDK_NAME" --find llvm-ranlib 2>/dev/null || command -v ranlib || true)}"
STRIP_BIN="${STRIP:-$(xcrun --sdk "$SDK_NAME" --find strip 2>/dev/null || true)}"

if [[ -f "${BUILD_DIR}/librocksdb.a" ]]; then
  echo "** BUILD SKIPPED: ${BUILD_DIR}/librocksdb.a already exists **"
  exit 0
fi

DEPENDENCY_HEADERS_DIR="${REPO_ROOT}/build/include/dependencies"
DEPENDENCY_INCLUDE_ROOT="${REPO_ROOT}/build/include"
DEPENDENCY_LIB_DIR="${BUILD_DIR}"
SNAPPY_PREFIX="${BUILD_DIR}/deps/snappy"
SNAPPY_CMAKE_DIR="${SNAPPY_PREFIX}/lib/cmake/Snappy"
SNAPPY_CONFIG_PATH="${SNAPPY_CMAKE_DIR}/SnappyConfig.cmake"

if [[ ! -f "${SNAPPY_CONFIG_PATH}" ]]; then
  echo "Warning: Expected Snappy CMake package at ${SNAPPY_CONFIG_PATH} not found. The build may fail if dependencies have not been prepared." >&2
fi

get_num_cores() {
  sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4
}

NUM_CORES="$(get_num_cores)"

CMAKE_TOOLCHAIN_ARGS=(-DCMAKE_SYSTEM_NAME="${CMAKE_SYSTEM_NAME}" -DCMAKE_OSX_SYSROOT="${SDK_PATH}" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_VERSION}")
if [[ "$ARCH" != "" ]]; then
  CMAKE_TOOLCHAIN_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="${ARCH}")
fi

CMAKE_ARGS=(
  -S "rocksdb"
  -B "$BUILD_DIR"
  "${CMAKE_TOOLCHAIN_ARGS[@]}"
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
  -DCMAKE_C_FLAGS="${EXTRA_C_FLAGS}"
  -DCMAKE_CXX_FLAGS="${EXTRA_CXX_FLAGS}"
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
