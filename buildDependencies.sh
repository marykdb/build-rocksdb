#!/usr/bin/env bash

#
# buildDependencies.sh
#
# This script downloads, verifies, and builds static libraries
# for zlib, bzip2, zstd, snappy, and lz4 into a specified output directory.
#
# Usage:
#   chmod +x buildDependencies.sh
#   ./buildDependencies.sh [--extra-cflags "FLAGS"] [--extra-cmakeflags "FLAGS"] [--output-dir "/path/to/dir"]
#
# Options:
#   --extra-cflags       Additional CFLAGS to pass to the compiler.
#   --extra-cmakeflags   Additional CFLAGS to pass to the compiler.
#   --output-dir         Directory where libz.a, libbz2.a, libzstd.a, libsnappy.a, and liblz4.a will be placed.
#                        Defaults to the current directory.
#   -h, --help           Display this help message.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


if [[ -n "${LLVM_MINGW_ROOT:-}" && -d "${LLVM_MINGW_ROOT}/bin" ]]; then
  export PATH="${LLVM_MINGW_ROOT}/bin:${PATH}"
fi

# shellcheck source=./scripts/android-ndk.sh
source "${SCRIPT_DIR}/scripts/android-ndk.sh"

# ---------------------------------------------------------
# Default Values
# ---------------------------------------------------------
BUILD_ROOT="${SCRIPT_DIR}/build"
DOWNLOAD_DIR="${BUILD_ROOT}/dependencies"
INCLUDE_OUTPUT_DIR="${BUILD_ROOT}/include"
DEPENDENCY_INCLUDE_DIR="${INCLUDE_OUTPUT_DIR}/dependencies"
TOOLCHAIN_FILE=null

# iOS Toolchain
IOS_TOOLCHAIN_URL="https://github.com/leetal/ios-cmake/archive/refs/tags/4.5.0.tar.gz"
IOS_TOOLCHAIN_ARCHIVE="${DOWNLOAD_DIR}/ios-cmake-4.5.0.tar.gz"
IOS_TOOLCHAIN_DIR="${DOWNLOAD_DIR}/ios-toolchain"

# zlib
DEFAULT_ZLIB_VER="1.3.1"
DEFAULT_ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
DEFAULT_ZLIB_DOWNLOAD_BASE="http://zlib.net"

# bzip2
DEFAULT_BZIP2_VER="1.0.8"
DEFAULT_BZIP2_SHA256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
DEFAULT_BZIP2_DOWNLOAD_BASE="http://sourceware.org/pub/bzip2"

# zstd
DEFAULT_ZSTD_VER="1.5.7"
DEFAULT_ZSTD_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
DEFAULT_ZSTD_DOWNLOAD_BASE="https://github.com/facebook/zstd/releases/download/v${DEFAULT_ZSTD_VER}"

# snappy
DEFAULT_SNAPPY_VER="1.2.2"
DEFAULT_SNAPPY_SHA256="90f74bc1fbf78a6c56b3c4a082a05103b3a56bb17bca1a27e052ea11723292dc"
DEFAULT_SNAPPY_DOWNLOAD_BASE="https://github.com/google/snappy/archive"

# lz4
DEFAULT_LZ4_VER="1.10.0"
DEFAULT_LZ4_SHA256="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
DEFAULT_LZ4_DOWNLOAD_BASE="https://github.com/lz4/lz4/archive"


# Build Flags (can be overridden by environment variables)
ARCHFLAG="${ARCHFLAG:-}"
EXTRA_CMAKEFLAGS="${EXTRA_CMAKEFLAGS:-}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:-}"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:-}"
PLATFORM_CMAKE_FLAGS="${PLATFORM_CMAKE_FLAGS:-}"
SNAPPY_MAKE_TARGET="${SNAPPY_MAKE_TARGET:-}"
# CROSS_PREFIX is only set for mingw builds but is referenced unconditionally.
# Provide an empty default to avoid "unbound variable" errors under `set -u`.
CROSS_PREFIX="${CROSS_PREFIX:-}"

# ---------------------------------------------------------
# Minimal size defaults and strippers
# ---------------------------------------------------------
# Prefer size-optimised code and hidden visibility by default; can be overridden via OPT_CFLAGS env
OPT_CFLAGS="${OPT_CFLAGS:--Os -fPIC -fvisibility=hidden -DNDEBUG}"

# Detect a suitable strip tool for static archives (optional)
STRIP_BIN="${STRIP_BIN:-}"
if [[ -z "$STRIP_BIN" ]]; then
  if command -v "${CROSS_PREFIX}strip" >/dev/null 2>&1; then
    STRIP_BIN="${CROSS_PREFIX}strip"
  elif command -v llvm-strip >/dev/null 2>&1; then
    STRIP_BIN="llvm-strip"
  elif command -v strip >/dev/null 2>&1; then
    STRIP_BIN="strip"
  else
    STRIP_BIN=""
  fi
fi

strip_archive() {
  local archive="$1"
  if [[ -n "$STRIP_BIN" && -f "$archive" ]]; then
    "$STRIP_BIN" -S -x "$archive" || true
  fi
}

apply_android_toolchain_flags() {
  EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }${ANDROID_TOOLCHAIN_EXTRA_CFLAGS}"
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:+${EXTRA_CXXFLAGS} }${ANDROID_TOOLCHAIN_EXTRA_CXXFLAGS}"
  PLATFORM_CMAKE_FLAGS="${PLATFORM_CMAKE_FLAGS:+${PLATFORM_CMAKE_FLAGS} }${ANDROID_TOOLCHAIN_CMAKE_FLAGS}"
  if [[ -n "${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE}" ]]; then
    TOOLCHAIN_FILE="${ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE}"
  fi
}

DEFAULT_OUTPUT_DIR="$(pwd)"

# ---------------------------------------------------------
# Function to Display Help
# ---------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --extra-cflags "FLAGS"        Additional CFLAGS to pass to the compiler.
  --extra-cmakeflags "FLAGS"    Additional flags to pass to CMAKE.
  --output-dir "/path"          Directory where libz.a, libbz2.a, libzstd.a, libsnappy.a, and liblz4.a will be placed.
                                Defaults to the current directory.
  -h, --help                    Display this help message.

Example:
  ./buildDependencies.sh --extra-cflags "-O3 -march=native" --output-dir "./libs"
EOF
  exit 1
}

# ---------------------------------------------------------
# Parse Command-Line Arguments
# ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --extra-cflags)
      EXTRA_CFLAGS="$2"
      EXTRA_CXXFLAGS="$2"
      shift 2
      ;;
    --extra-cmakeflags)
      EXTRA_CMAKEFLAGS="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Set OUTPUT_DIR to DEFAULT_OUTPUT_DIR if not provided
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# watchOS arm64_32 keeps 32-bit pointers, which triggers abundant
# -Wshorten-64-to-32 diagnostics when warnings are treated as errors. Suppress
# them for this target until truncations can be audited individually.
if [[ "$OUTPUT_DIR" == *watchos_arm64_32* ]] || [[ "${EXTRA_CFLAGS}" == *arm64_32* ]] || [[ "${EXTRA_CXXFLAGS}" == *arm64_32* ]]; then
  arm64_32_warning_flag="-Wno-shorten-64-to-32"
  if [[ "${EXTRA_CFLAGS}" != *"${arm64_32_warning_flag}"* ]]; then
    EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }${arm64_32_warning_flag}"
  fi
  if [[ "${EXTRA_CXXFLAGS}" != *"${arm64_32_warning_flag}"* ]]; then
    EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:+${EXTRA_CXXFLAGS} }${arm64_32_warning_flag}"
  fi
fi

mkdir -p "$DOWNLOAD_DIR"
DOWNLOAD_DIR="$(cd "$DOWNLOAD_DIR" && pwd)"

mkdir -p "$DEPENDENCY_INCLUDE_DIR"
# ---------------------------------------------------------
# Toolchain configuration based on the requested output
# ---------------------------------------------------------
set +u
if [[ "$OUTPUT_DIR" == *linux_x86_64* ]]; then
  # Linux x86_64: rely on system toolchain or user-provided CC/CXX
  if [[ -z "${CC:-}" ]]; then export CC=gcc; fi
  if [[ -z "${CXX:-}" ]]; then export CXX=g++; fi
  EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }-m64"
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:+${EXTRA_CXXFLAGS} }-m64"
elif [[ "$OUTPUT_DIR" == *linux_arm64* ]]; then
  # Linux ARM64: prefer aarch64 cross-compiler if present; otherwise fall back
  if [[ -z "${CC:-}" ]]; then
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
      export CC=aarch64-linux-gnu-gcc
    else
      export CC=gcc
    fi
  fi
  if [[ -z "${CXX:-}" ]]; then
    if command -v aarch64-linux-gnu-g++ >/dev/null 2>&1; then
      export CXX=aarch64-linux-gnu-g++
    else
      export CXX=g++
    fi
  fi
  EXTRA_CFLAGS="${EXTRA_CFLAGS:+${EXTRA_CFLAGS} }-march=armv8-a"
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:+${EXTRA_CXXFLAGS} }-march=armv8-a"
elif [[ "$OUTPUT_DIR" == *android_arm32* ]]; then
  if ! setup_android_ndk_toolchain "android_arm32"; then
    echo "❌ Failed to configure Android NDK toolchain for arm32" >&2
    exit 1
  fi
  apply_android_toolchain_flags
elif [[ "$OUTPUT_DIR" == *android_arm64* ]]; then
  if ! setup_android_ndk_toolchain "android_arm64"; then
    echo "❌ Failed to configure Android NDK toolchain for arm64" >&2
    exit 1
  fi
  apply_android_toolchain_flags
elif [[ "$OUTPUT_DIR" == *android_x86* ]]; then
  if ! setup_android_ndk_toolchain "android_x86"; then
    echo "❌ Failed to configure Android NDK toolchain for x86" >&2
    exit 1
  fi
  apply_android_toolchain_flags
elif [[ "$OUTPUT_DIR" == *android_x64* ]]; then
  if ! setup_android_ndk_toolchain "android_x64"; then
    echo "❌ Failed to configure Android NDK toolchain for x86_64" >&2
    exit 1
  fi
  apply_android_toolchain_flags
elif [[ "$OUTPUT_DIR" == *macos_x86_64* ]]; then
  export CC="clang"
  export CXX="clang++"
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
elif [[ "$OUTPUT_DIR" == *macos_arm64* ]]; then
  export CC="clang"
  export CXX="clang++"
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
elif [[ "$OUTPUT_DIR" == *mingw_x86_64* ]]; then
  export CC="x86_64-w64-mingw32-gcc"
  export CXX="x86_64-w64-mingw32-g++"
  export AR="x86_64-w64-mingw32-ar"
  export uname="mingw32"
  export CROSS_PREFIX="x86_64-w64-mingw32-"
elif [[ "$OUTPUT_DIR" == *mingw_arm64* ]]; then
  TOOLCHAIN_TRIPLE="aarch64-w64-mingw32"
  if command -v "${TOOLCHAIN_TRIPLE}-gcc" >/dev/null 2>&1; then
    export CC="${TOOLCHAIN_TRIPLE}-gcc"
    export CXX="${TOOLCHAIN_TRIPLE}-g++"
  elif command -v "${TOOLCHAIN_TRIPLE}-clang" >/dev/null 2>&1; then
    export CC="${TOOLCHAIN_TRIPLE}-clang"
    if command -v "${TOOLCHAIN_TRIPLE}-clang++" >/dev/null 2>&1; then
      export CXX="${TOOLCHAIN_TRIPLE}-clang++"
    else
      export CXX="${TOOLCHAIN_TRIPLE}-clang"
    fi
  else
    echo "❌ Missing Windows ARM64 cross compiler (${TOOLCHAIN_TRIPLE}-gcc or ${TOOLCHAIN_TRIPLE}-clang)." >&2
    echo "   Install an ARM64 MinGW toolchain or expose it via LLVM_MINGW_ROOT." >&2
    exit 1
  fi

  if command -v "${TOOLCHAIN_TRIPLE}-ar" >/dev/null 2>&1; then
    export AR="${TOOLCHAIN_TRIPLE}-ar"
  elif command -v llvm-ar >/dev/null 2>&1; then
    export AR="llvm-ar"
  fi

  if command -v "${TOOLCHAIN_TRIPLE}-ranlib" >/dev/null 2>&1; then
    export RANLIB="${TOOLCHAIN_TRIPLE}-ranlib"
  elif command -v llvm-ranlib >/dev/null 2>&1; then
    export RANLIB="llvm-ranlib"
  fi

  export uname="mingw32"
  if command -v "${TOOLCHAIN_TRIPLE}-ar" >/dev/null 2>&1 || command -v "${TOOLCHAIN_TRIPLE}-ranlib" >/dev/null 2>&1; then
    export CROSS_PREFIX="${TOOLCHAIN_TRIPLE}-"
  else
    export CROSS_PREFIX=""
  fi
fi
set -u

# Create the output directory if it doesn't exist
# ---------------------------------------------------------
# Versions and checksums
# ---------------------------------------------------------
ZLIB_VER="${ZLIB_VER:-$DEFAULT_ZLIB_VER}"
ZLIB_SHA256="${ZLIB_SHA256:-$DEFAULT_ZLIB_SHA256}"
ZLIB_DOWNLOAD_BASE="${ZLIB_DOWNLOAD_BASE:-$DEFAULT_ZLIB_DOWNLOAD_BASE}"

BZIP2_VER="${BZIP2_VER:-$DEFAULT_BZIP2_VER}"
BZIP2_SHA256="${BZIP2_SHA256:-$DEFAULT_BZIP2_SHA256}"
BZIP2_DOWNLOAD_BASE="${BZIP2_DOWNLOAD_BASE:-$DEFAULT_BZIP2_DOWNLOAD_BASE}"

ZSTD_VER="${ZSTD_VER:-$DEFAULT_ZSTD_VER}"
ZSTD_SHA256="${ZSTD_SHA256:-$DEFAULT_ZSTD_SHA256}"
ZSTD_DOWNLOAD_BASE="${ZSTD_DOWNLOAD_BASE:-$DEFAULT_ZSTD_DOWNLOAD_BASE}"

SNAPPY_VER="${SNAPPY_VER:-$DEFAULT_SNAPPY_VER}"
SNAPPY_SHA256="${SNAPPY_SHA256:-$DEFAULT_SNAPPY_SHA256}"
SNAPPY_DOWNLOAD_BASE="${SNAPPY_DOWNLOAD_BASE:-$DEFAULT_SNAPPY_DOWNLOAD_BASE}"

LZ4_VER="${LZ4_VER:-$DEFAULT_LZ4_VER}"
LZ4_SHA256="${LZ4_SHA256:-$DEFAULT_LZ4_SHA256}"
LZ4_DOWNLOAD_BASE="${LZ4_DOWNLOAD_BASE:-$DEFAULT_LZ4_DOWNLOAD_BASE}"

# Ensure DOWNLOAD_DIR exists (idempotent if already created)
mkdir -p "$DOWNLOAD_DIR"

download_ios_toolchain() {
  if [ -d "${IOS_TOOLCHAIN_DIR}" ]; then
    return
  fi

  mkdir -p "${DOWNLOAD_DIR}"
  if curl --silent --fail --location -o "${IOS_TOOLCHAIN_ARCHIVE}" "${IOS_TOOLCHAIN_URL}"; then
    echo "✅ Downloaded iOS toolchain successfully."
  else
    echo "❌ Error downloading iOS toolchain from ${IOS_TOOLCHAIN_URL}" >&2
    exit 1
  fi
  mkdir -p "${IOS_TOOLCHAIN_DIR}"
  tar -xzf "${IOS_TOOLCHAIN_ARCHIVE}" -C "${DOWNLOAD_DIR}"
  mv "${DOWNLOAD_DIR}/ios-cmake-4.5.0/ios.toolchain.cmake" "${IOS_TOOLCHAIN_DIR}/"
  rm -rf "${DOWNLOAD_DIR}/ios-cmake-4.5.0"
}

if [[ "${EXTRA_CFLAGS}" == *"-isysroot"* ]]; then
  download_ios_toolchain
  TOOLCHAIN_FILE="${IOS_TOOLCHAIN_DIR}/ios.toolchain.cmake"
fi

# ---------------------------------------------------------
# Function to Download and Verify Tarball
# ---------------------------------------------------------
download_and_verify() {
  local name="$1"
  local version="$2"
  local url_base="$3"
  local sha256="$4"
  local tarball
  if [ "$name" == "snappy" ]; then
    tarball="${version}.tar.gz"
  elif [ "$name" == "lz4" ]; then
    tarball="v${version}.tar.gz"
  else
    tarball="${name}-${version}.tar.gz"
  fi
  local target_path="${DOWNLOAD_DIR}/${name}-${version}.tar.gz"
  local vendor_path="${SCRIPT_DIR}/lib/${name}-${version}.tar.gz"

  if [[ -f "$vendor_path" ]]; then
    echo "Using vendored ${name}-${version} from ${vendor_path}";
    cp "$vendor_path" "$target_path"
  else
    echo "Downloading ${name}-${version}..."
    if ! curl --silent --fail --location -o "${target_path}" "${url_base}/${tarball}"; then
      echo "Error downloading ${name}-${version}!" >&2
      exit 1
    fi
  fi

  echo "Verifying ${name}-${version}..."
  local sha256_actual
  sha256_actual="$(shasum -a 256 "${target_path}" | awk '{print $1}')"
  if [[ "${sha256}" != "${sha256_actual}" ]]; then
    echo "Error: ${tarball} checksum mismatch!" >&2
    echo "  expected: ${sha256}" >&2
    echo "  actual:   ${sha256_actual}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------
# Function to Build zlib
# ---------------------------------------------------------
build_zlib() {
  local tarball="${DOWNLOAD_DIR}/zlib-${ZLIB_VER}.tar.gz"
  local src_dir="${DOWNLOAD_DIR}/zlib-${ZLIB_VER}"
  local cflags="${OPT_CFLAGS} -DNO_GZCOMPRESS -DNO_GZIP"
  [[ -n "${EXTRA_CFLAGS:-}" ]] && cflags="${EXTRA_CFLAGS} ${cflags}"

  tar xzf "${tarball}" -C "${DOWNLOAD_DIR}"  > /dev/null
  pushd "${src_dir}" > /dev/null

  local -a configure_env=(
    "CC=${CC:-cc}"
    "CFLAGS=${cflags}"
    "CROSS_PREFIX=${CROSS_PREFIX}"
  )
  local -a make_args=("CC=${CC:-cc}")

  if [[ -n "${AR:-}" ]]; then
    configure_env+=("AR=${AR}")
    make_args+=("AR=${AR}")
    make_args+=("ARFLAGS=rcs")
    configure_env+=("ARFLAGS=rcs")
  fi
  if [[ -n "${RANLIB:-}" ]]; then
    configure_env+=("RANLIB=${RANLIB}")
    make_args+=("RANLIB=${RANLIB}")
  fi

  if ! env "${configure_env[@]}" ./configure --static; then
    if [[ -f configure.log ]]; then
      echo "⚠️ zlib configure failed, dumping configure.log:" >&2
      cat configure.log >&2
    fi
    return 1
  fi

  make "${make_args[@]}" clean > /dev/null
  make "${make_args[@]}" static

  cp "zlib.h" "zconf.h" "${DEPENDENCY_INCLUDE_DIR}/"
  cp "libz.a" "${OUTPUT_DIR}/"
  strip_archive "${OUTPUT_DIR}/libz.a"
  popd > /dev/null
  echo "✅ Finished building libz.a into ${OUTPUT_DIR}!"
}

# ---------------------------------------------------------
# Function to Build bzip2
# ---------------------------------------------------------
build_bzip2() {
  local tarball="${DOWNLOAD_DIR}/bzip2-${BZIP2_VER}.tar.gz"
  local src_dir="${DOWNLOAD_DIR}/bzip2-${BZIP2_VER}"
  tar xzf "${tarball}" -C "${DOWNLOAD_DIR}"  > /dev/null
  pushd "${src_dir}" > /dev/null
  make CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" clean > /dev/null
  make CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" \
    CFLAGS="${EXTRA_CFLAGS} ${OPT_CFLAGS} -D_FILE_OFFSET_BITS=64" libbz2.a > /dev/null
  cp "bzlib.h" "${DEPENDENCY_INCLUDE_DIR}/"
  cp "libbz2.a" "${OUTPUT_DIR}/"
  strip_archive "${OUTPUT_DIR}/libbz2.a"
  popd > /dev/null
  echo "✅ Finished building libbz2.a into ${OUTPUT_DIR}!"
}

# ---------------------------------------------------------
# Function to Build zstd
# ---------------------------------------------------------
build_zstd() {
  local tarball="${DOWNLOAD_DIR}/zstd-${ZSTD_VER}.tar.gz"
  local src_dir="${DOWNLOAD_DIR}/zstd-${ZSTD_VER}"
  tar xzf "${tarball}" -C "${DOWNLOAD_DIR}"  > /dev/null
  pushd "${src_dir}/lib" > /dev/null
  make CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" clean > /dev/null
  make CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" \
    HAVE_PTHREAD=0 ZSTD_LEGACY_SUPPORT=0 \
    CFLAGS="${EXTRA_CFLAGS} ${OPT_CFLAGS}" \
    CPPFLAGS="${EXTRA_CFLAGS} -DDEBUGLEVEL=0" \
    libzstd.a > /dev/null
  popd > /dev/null
  cp "${src_dir}/lib/zstd.h" "${src_dir}/lib/zdict.h" "${src_dir}/lib/zstd_errors.h" "${DEPENDENCY_INCLUDE_DIR}/"
  cp "${src_dir}/lib/libzstd.a" "${OUTPUT_DIR}/"
  strip_archive "${OUTPUT_DIR}/libzstd.a"
  echo "✅ Finished building libzstd.a into ${OUTPUT_DIR}!"
}

# ---------------------------------------------------------
# Function to Build snappy
# ---------------------------------------------------------
build_snappy() {
  local tarball="${DOWNLOAD_DIR}/snappy-${SNAPPY_VER}.tar.gz"
  local src_dir="${DOWNLOAD_DIR}/snappy-${SNAPPY_VER}"
  local install_prefix="${OUTPUT_DIR}/deps/snappy"

  rm -rf $src_dir

  tar xzf "${tarball}" -C "${DOWNLOAD_DIR}"  > /dev/null
  pushd "${src_dir}" > /dev/null

  mkdir -p "${install_prefix}"

  if [ "${TOOLCHAIN_FILE}" != null ]; then
    EXTRA_CMAKEFLAGS+=" -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE}"
  else
    local toolchain_file="toolchain.cmake"
    echo "set(CMAKE_C_FLAGS \"\${CMAKE_CXX_FLAGS} ${EXTRA_CFLAGS}\")" > "${toolchain_file}"
    echo "set(CMAKE_CXX_FLAGS \"\${CMAKE_CXX_FLAGS} ${EXTRA_CXXFLAGS}\")" >> "${toolchain_file}"
    echo "set(CMAKE_POSITION_INDEPENDENT_CODE ON)" >> "${toolchain_file}"
    echo "set(CMAKE_BUILD_TYPE Release)" >> "${toolchain_file}"
    echo "set(CMAKE_C_COMPILER_WORKS ON)" >> "${toolchain_file}"
    echo "set(CMAKE_CXX_COMPILER_WORKS ON)" >> "${toolchain_file}"
    echo "set(CMAKE_16BIT_TYPE \"unsigned long\")" >> "${toolchain_file}"

    EXTRA_CMAKEFLAGS+=""" -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_TOOLCHAIN_FILE=$toolchain_file"""
    if [[ "$OUTPUT_DIR" == *mingw_* ]]; then
      EXTRA_CMAKEFLAGS+=" -DCMAKE_SYSTEM_NAME=Windows"
      EXTRA_CMAKEFLAGS+=" -DSNAPPY_IS_BIG_ENDIAN=0"
    fi
  fi

  if [[ "$OUTPUT_DIR" == *android_arm32* ]]; then
    EXTRA_CMAKEFLAGS+=" -DSNAPPY_HAVE_NEON=0"
  fi

  cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        ${EXTRA_CMAKEFLAGS} \
        -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
        -DCMAKE_C_FLAGS="${EXTRA_CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${EXTRA_CXXFLAGS}" \
        -DSNAPPY_BUILD_BENCHMARKS=OFF \
        -DSNAPPY_BUILD_TESTS=OFF \
        -Wno-dev ${PLATFORM_CMAKE_FLAGS} .

  make CC="${CC:-cc}" CXX="${CXX:-c++}" clean > /dev/null
  make CC="${CC:-cc}" CXX="${CXX:-c++}" \
    CXXFLAGS="${EXTRA_CXXFLAGS} ${OPT_CFLAGS}" CFLAGS="${EXTRA_CFLAGS} ${OPT_CFLAGS}" ${SNAPPY_MAKE_TARGET} > /dev/null
  cmake --install . --prefix "${install_prefix}" > /dev/null
  cp "snappy.h" "snappy-stubs-public.h" "${DEPENDENCY_INCLUDE_DIR}/"
  cp "libsnappy.a" "${OUTPUT_DIR}/"
  strip_archive "${OUTPUT_DIR}/libsnappy.a"
  popd > /dev/null
  echo "✅ Finished building libsnappy.a into ${OUTPUT_DIR}!"
}

# ---------------------------------------------------------
# Function to Build LZ4
# ---------------------------------------------------------
build_lz4() {
  local tarball="${DOWNLOAD_DIR}/lz4-${LZ4_VER}.tar.gz"
  local src_dir="${DOWNLOAD_DIR}/lz4-${LZ4_VER}"

  echo "Building LZ4 version ${LZ4_VER}..."
  tar xzf "${tarball}" -C "${DOWNLOAD_DIR}" > /dev/null
  pushd "${src_dir}/lib" > /dev/null
  make CC="${CC:-cc}" clean > /dev/null

  TARGET_OS=null
  if [[ "$OUTPUT_DIR" == *mingw_* ]]; then
    # Because we use linux cross compiler, we need to set it to linux
    TARGET_OS="Linux"
  fi

  make CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" \
    TARGET_OS=$TARGET_OS CFLAGS="${EXTRA_CFLAGS} ${OPT_CFLAGS}" LDFLAGS="${EXTRA_LDFLAGS}" liblz4.a > /dev/null
  cp "lz4.h" "lz4hc.h" "${DEPENDENCY_INCLUDE_DIR}/"
  cp "liblz4.a" "${OUTPUT_DIR}/"
  strip_archive "${OUTPUT_DIR}/liblz4.a"
  popd > /dev/null
  echo "✅ Finished building liblz4.a into ${OUTPUT_DIR}!"
}

# ---------------------------------------------------------
# Main Execution Flow
# ---------------------------------------------------------
# Build bzip2
if [ -f "${OUTPUT_DIR}/libbz2.a" ]; then
  echo "libbz2.a already exists in ${OUTPUT_DIR}, skipping bzip2 build."
else
  # Download, verify, and build bzip2
  download_and_verify "bzip2" "$BZIP2_VER" "$BZIP2_DOWNLOAD_BASE" "$BZIP2_SHA256"
  build_bzip2
fi

# Build zlib
if [ -f "${OUTPUT_DIR}/libz.a" ]; then
  echo "libz.a already exists in ${OUTPUT_DIR}, skipping zlib build."
else
  # Download, verify, and build zlib
  download_and_verify "zlib" "$ZLIB_VER" "$ZLIB_DOWNLOAD_BASE" "$ZLIB_SHA256"
  build_zlib
fi

# Build zstd
if [ -f "${OUTPUT_DIR}/libzstd.a" ]; then
  echo "libzstd.a already exists in ${OUTPUT_DIR}, skipping zstd build."
else
  # Download, verify, and build zstd
  download_and_verify "zstd" "$ZSTD_VER" "$ZSTD_DOWNLOAD_BASE" "$ZSTD_SHA256"
  build_zstd
fi

# Build snappy
if [ -f "${OUTPUT_DIR}/libsnappy.a" ]; then
  echo "libsnappy.a already exists in ${OUTPUT_DIR}, skipping snappy build."
else
  # Download, verify, and build snappy
  download_and_verify "snappy" "$SNAPPY_VER" "$SNAPPY_DOWNLOAD_BASE" "$SNAPPY_SHA256"
  build_snappy
fi

# Build LZ4
if [ -f "${OUTPUT_DIR}/liblz4.a" ]; then
  echo "liblz4.a already exists in ${OUTPUT_DIR}, skipping LZ4 build."
else
  # Download, verify, and build LZ4
  download_and_verify "lz4" "$LZ4_VER" "$LZ4_DOWNLOAD_BASE" "$LZ4_SHA256"
  build_lz4
fi

echo "All dependencies have been successfully built and are located in ${OUTPUT_DIR}!"
