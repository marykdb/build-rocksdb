#!/usr/bin/env bash

# Common helper functions shared across buildRocksdb*.sh scripts.

build_common::warn_missing_snappy() {
  local config_path="$1"
  if [[ -n "$config_path" && ! -f "$config_path" ]]; then
    echo "Warning: Expected Snappy CMake package at ${config_path} not found. The build may fail if dependencies have not been prepared." >&2
  fi
}

build_common::check_existing_artifacts() {
  local build_dir="$1"
  if [[ -f "${build_dir}/librocksdb.a" ]]; then
    echo "** BUILD SKIPPED: ${build_dir}/librocksdb.a already exists **"
    return 0
  fi
  if [[ -f "${build_dir}/rocksdb-build/librocksdb.a" ]]; then
    echo "** BUILD SKIPPED: ${build_dir}/rocksdb-build/librocksdb.a already exists **"
    return 0
  fi
  return 1
}

build_common::default_parallel_jobs() {
  local count=""
  if command -v nproc >/dev/null 2>&1; then
    count="$(nproc 2>/dev/null || true)"
    if [[ -n "$count" ]]; then
      echo "$count"
      return
    fi
  fi
  if command -v sysctl >/dev/null 2>&1; then
    count="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)"
    if [[ -n "$count" ]]; then
      echo "$count"
      return
    fi
  fi
  if [[ -n "${NUMBER_OF_PROCESSORS:-}" ]]; then
    echo "${NUMBER_OF_PROCESSORS}"
    return
  fi
  echo 4
}

build_common::create_flag_filter_wrapper() {
  local output_path="$1"
  local real_binary="$2"
  shift 2
  local -a filtered_flags=("$@")

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'args=()\n'
    printf 'for arg in "$@"; do\n'
    if ((${#filtered_flags[@]} > 0)); then
      local pattern=""
      local escaped=""
      for flag in "${filtered_flags[@]}"; do
        if [[ -n "$pattern" ]]; then
          pattern+='|'
        fi
        printf -v escaped '%q' "$flag"
        pattern+="$escaped"
      done
      if [[ -n "$pattern" ]]; then
        printf '  case "$arg" in\n'
        printf '    %s)\n' "$pattern"
        printf '      continue\n'
        printf '      ;;\n'
        printf '  esac\n'
      fi
    fi
    printf '  args+=("$arg")\n'
    printf 'done\n'
    printf 'exec %q "${args[@]}"\n' "$real_binary"
  } >"$output_path"
  chmod +x "$output_path"
}

build_common::cmake_configure() {
  local repo_root="$1"
  local build_dir="$2"
  local extra_c_flags="$3"
  local extra_cxx_flags="$4"
  shift 4

  local source_dir="${repo_root}/rocksdb"
  local dependency_include_root="${repo_root}/build/include"
  local dependency_headers_dir="${dependency_include_root}/dependencies"
  local dependency_lib_dir="$build_dir"
  local snappy_prefix="${build_dir}/deps/snappy"
  local snappy_cmake_dir="${snappy_prefix}/lib/cmake/Snappy"
  local snappy_config_path="${snappy_cmake_dir}/SnappyConfig.cmake"

  build_common::warn_missing_snappy "$snappy_config_path"

  local -a cmake_args=(
    -S "$source_dir"
    -B "$build_dir"
    -DCMAKE_PREFIX_PATH="$snappy_prefix"
    -DSnappy_DIR="$snappy_cmake_dir"
    -DCMAKE_INCLUDE_PATH="${dependency_include_root};${dependency_headers_dir}"
    -DCMAKE_LIBRARY_PATH="$dependency_lib_dir"
    -DZLIB_INCLUDE_DIR="$dependency_headers_dir"
    -DZLIB_LIBRARY="${dependency_lib_dir}/libz.a"
    -DZLIB_USE_STATIC_LIBS=ON
    -DBZIP2_INCLUDE_DIR="$dependency_headers_dir"
    -DBZIP2_LIBRARIES="${dependency_lib_dir}/libbz2.a"
    -Dlz4_INCLUDE_DIRS="$dependency_headers_dir"
    -Dlz4_LIBRARIES="${dependency_lib_dir}/liblz4.a"
    -DZSTD_INCLUDE_DIRS="$dependency_headers_dir"
    -DZSTD_LIBRARIES="${dependency_lib_dir}/libzstd.a"
    -DCMAKE_C_FLAGS="$extra_c_flags"
    -DCMAKE_CXX_FLAGS="$extra_cxx_flags"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$build_dir"
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

  cmake_args+=("$@")

  cmake "${cmake_args[@]}"
}

build_common::run_cmake_build() {
  local build_dir="$1"
  local parallel_jobs="$2"
  local target="${3:-rocksdb}"
  (( $# >= 3 )) && shift 3
  (( $# == 2 )) && shift 2
  local build_log="${build_dir}/build.log"

  echo "Building RocksDB with CMake..."
  set +e
  cmake --build "$build_dir" --config Release --target "$target" --parallel "$parallel_jobs" 2>&1
  local build_status=$?
  set -e

  if [[ -f "${build_dir}/librocksdb.a" ]]; then
    echo "** BUILD SUCCEEDED for ${build_dir} **"
    return 0
  elif [[ -f "${build_dir}/rocksdb-build/librocksdb.a" ]]; then
    echo "** BUILD SUCCEEDED for ${build_dir} **"
    return 0
  elif grep -q "up-to-date" "$build_log"; then
    echo "** BUILD NOT NEEDED for ${build_dir} (Already up to date) **"
    return 0
  elif [[ $build_status -ne 0 ]]; then
    echo "** BUILD FAILED for ${build_dir} **"
    return 1
  else
    echo "** BUILD RESULT UNKNOWN; neither artifact nor explicit failure detected (check $build_log) **"
    return 1
  fi
}
