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

determine_jobs() {
  local jobs=""
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc 2>/dev/null || true)"
  elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if [[ -z "$jobs" ]]; then
    jobs=4
  fi
  echo "$jobs"
}

cd "${PROJECT_ROOT}/rocksdb" || { echo "Could not enter rocksdb directory" >&2; exit 1; }

check_build() {
  local output="$1"
  local target_dir="$2"
  if echo "$output" | grep -q "AR       ${target_dir}/librocksdb.a"; then
    echo "** BUILD SUCCEEDED for ${target_dir} **"
  elif echo "$output" | grep -q "Nothing to be done for 'static_lib'."; then
    echo "** BUILD NOT NEEDED for ${target_dir} (Already up to date) **"
  else
    echo "** BUILD FAILED for ${target_dir} **"
    echo "$output"
    exit 1
  fi
}

MAKE_JOBS="$(determine_jobs)"

MAKE_DISABLE_WERROR=()
if [[ "$CONFIG_ARCH" == "android_arm32" || "$CONFIG_ARCH" == "android_x86" ]]; then
  MAKE_DISABLE_WERROR+=("DISABLE_WARNING_AS_ERROR=1")
fi

BUILD_OUTPUT=$(
  make -j"${MAKE_JOBS}" \
    "${MAKE_DISABLE_WERROR[@]}" \
    LIB_MODE=static \
    LIBNAME="${BUILD_DIR}/librocksdb" \
    DEBUG_LEVEL=0 \
    CC="$CC" \
    CXX="$CXX" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    STRIP="$STRIP" \
    OBJ_DIR="${BUILD_DIR}" \
    EXTRA_CXXFLAGS="${EXTRA_FLAGS}" \
    EXTRA_CFLAGS="${EXTRA_FLAGS}" \
    MACOSX_DEPLOYMENT_TARGET= \
    TARGET_OS=OS_ANDROID_CROSSCOMPILE \
    PLATFORM=OS_ANDROID \
    PORTABLE=1 \
    static_lib
)

check_build "$BUILD_OUTPUT" "$BUILD_DIR"

echo "✅ RocksDB build completed successfully for ${CONFIG_ARCH}"
