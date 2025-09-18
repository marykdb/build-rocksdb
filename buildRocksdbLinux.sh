#!/usr/bin/env bash

ARCH="" # e.g. arm64, x86_64, etc.

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

# Validate
if [ -z "$ARCH" ]; then
  echo "Usage: $0 --arch=<arm64|x86_64>"
  exit 1
fi

echo "Building RocksDB for $ARCH..."

# Optional: navigate to the rocksdb directory
cd "rocksdb" || { echo "Failed to navigate to rocksdb"; exit 1; }

# Simple function to check build output
check_build() {
  local output="$1"
  local folder="$2"

  if echo "$output" | grep -q "AR       build/$folder/librocksdb.a"; then
      echo "** BUILD SUCCEEDED for $ARCH **"
  elif echo "$output" | grep -q "make: Nothing to be done for 'static_lib'."; then
      echo "** BUILD NOT NEEDED for $ARCH (Already up to date) **"
  else
      echo "** BUILD FAILED for $ARCH **"
      echo "$output"
      exit 1
  fi
}

EXTRA_FLAGS="-I../lib/include -DZLIB -DBZIP2 -DSNAPPY -DLZ4 -DZSTD "
HOST_OS="$(uname -s)"
ar_bin=""
ranlib_bin=""
MAKE_JOBS_DEFAULT="$(nproc)"

if [[ "$ARCH" == "arm64" ]]; then
  folder="linux_arm64"
  if [[ "$HOST_OS" == "Linux" ]]; then
    cc="${cc:-$(command -v aarch64-linux-gnu-gcc 2>/dev/null || true)}"
    cxx="${cxx:-$(command -v aarch64-linux-gnu-g++ 2>/dev/null || true)}"
    ar_bin="${ar_bin:-$(command -v aarch64-linux-gnu-ar 2>/dev/null || true)}"
    ranlib_bin="${ranlib_bin:-$(command -v aarch64-linux-gnu-ranlib 2>/dev/null || true)}"
    if [[ -z "$cc" || -z "$cxx" ]]; then
      echo "Missing aarch64-linux-gnu cross compiler. Install it or run on a host with Konan installed." >&2
      exit 1
    fi
  else
    konan_deps_dir="${HOME}/.konan/dependencies"
    if [[ -d "$konan_deps_dir" ]]; then
      konan_cc=("${konan_deps_dir}"/aarch64-unknown-linux-gnu-gcc-*/bin/aarch64-unknown-linux-gnu-gcc)
      konan_cxx=("${konan_deps_dir}"/aarch64-unknown-linux-gnu-gcc-*/bin/aarch64-unknown-linux-gnu-g++)
      if [[ -x "${konan_cc[0]}" && -x "${konan_cxx[0]}" ]]; then
        cc="${konan_cc[0]}"
        cxx="${konan_cxx[0]}"
      fi
    fi
    if [[ -z "${cc:-}" || -z "${cxx:-}" ]]; then
      echo "Missing Kotlin/Native cross-compilation toolchain for linux_arm64." >&2
      exit 1
    fi
  fi
  EXTRA_FLAGS+="-march=armv8-a"
else
  folder="linux_x86_64"
  if [[ "$HOST_OS" == "Linux" ]]; then
    cc="${cc:-$(command -v gcc)}"
    cxx="${cxx:-$(command -v g++)}"
  else
    konan_deps_dir="${HOME}/.konan/dependencies"
    if [[ -d "$konan_deps_dir" ]]; then
      konan_cc=("${konan_deps_dir}"/x86_64-unknown-linux-gnu-gcc-*/bin/x86_64-unknown-linux-gnu-gcc)
      konan_cxx=("${konan_deps_dir}"/x86_64-unknown-linux-gnu-gcc-*/bin/x86_64-unknown-linux-gnu-g++)
      if [[ -x "${konan_cc[0]}" && -x "${konan_cxx[0]}" ]]; then
        cc="${konan_cc[0]}"
        cxx="${konan_cxx[0]}"
      fi
    fi
    if [[ -z "${cc:-}" || -z "${cxx:-}" ]]; then
      echo "Missing Kotlin/Native cross-compilation toolchain for linux_x86_64." >&2
      exit 1
    fi
  fi
  EXTRA_FLAGS+="-march=x86-64"
fi

if [[ -z "${ROCKSDB_MAKE_JOBS:-}" ]]; then
  if [[ "$ARCH" == "arm64" ]]; then
    if (( MAKE_JOBS_DEFAULT > 2 )); then
      MAKE_JOBS_DEFAULT=2
    fi
  fi
  MAKE_JOBS="$MAKE_JOBS_DEFAULT"
else
  MAKE_JOBS="$ROCKSDB_MAKE_JOBS"
fi

# Check if the build output already exists
if [ -f "build/$folder/librocksdb.a" ]; then
  echo "** BUILD SKIPPED: build/$folder/librocksdb.a already exists **"
  exit 0
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  output=$(
    make -j"$MAKE_JOBS" \
      LIB_MODE=static \
      LIBNAME="build/$folder/librocksdb" \
      DEBUG_LEVEL=0 \
      CC=$cc \
      CXX=$cxx \
      AR=${ar_bin:-ar} \
      RANLIB=${ranlib_bin:-ranlib} \
      OBJ_DIR="build/$folder" \
      EXTRA_CXXFLAGS="$EXTRA_FLAGS" \
      EXTRA_CFLAGS="$EXTRA_FLAGS" \
      PORTABLE=1 \
      LD_FLAGS="-lbz2 -lz -lz4 -lsnappy" \
      static_lib
  )

  check_build "$output" "$folder"
else
  echo "Should only build on linux"
  exit 1
fi
