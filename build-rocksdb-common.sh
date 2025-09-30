#!/usr/bin/env bash

# Common helper functions shared across build scripts for RocksDB.

build_common::append_unique_flag() {
  local var_name="$1"
  local flag="$2"
  if [[ -z "$flag" ]]; then
    return
  fi
  # shellcheck disable=SC2140
  local current="${!var_name:-}"
  case " ${current} " in
    *" ${flag} "*)
      return
      ;;
  esac
  if [[ -n "$current" ]]; then
    current+=" ${flag}"
  else
    current="${flag}"
  fi
  printf -v "$var_name" '%s' "$current"
}

build_common::compiler_is_clang() {
  local compiler="$1"
  if [[ -z "$compiler" ]]; then
    return 1
  fi

  if [[ "$compiler" == *clang* ]]; then
    return 0
  fi

  local compiler_path
  compiler_path="$(command -v "$compiler" 2>/dev/null || true)"
  if [[ -z "$compiler_path" ]]; then
    return 1
  fi

  if [[ "$compiler_path" == *clang* ]]; then
    return 0
  fi

  local version_output
  version_output="$("$compiler_path" --version 2>/dev/null || true)"
  if [[ "$version_output" == *clang* || "$version_output" == *LLVM* ]]; then
    return 0
  fi

  return 1
}

build_common::is_windows_host() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

build_common::to_tool_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf ''
    return
  fi

  if build_common::is_windows_host; then
    if command -v cygpath >/dev/null 2>&1; then
      local converted
      converted="$(cygpath -m "$path" 2>/dev/null || true)"
      if [[ -n "$converted" ]]; then
        printf '%s' "$converted"
        return
      fi
    fi

    if [[ "$path" =~ ^/([a-zA-Z])/(.*)$ ]]; then
      local drive="${BASH_REMATCH[1]}"
      local remainder="${BASH_REMATCH[2]}"
      printf '%s:/%s' "${drive^}" "$remainder"
      return
    fi
  fi

  printf '%s' "$path"
}

build_common::shell_escape() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf ''
    return
  fi
  printf '%q' "$value"
}

build_common::append_unique_array_flag() {
  local array_name="$1"
  local flag="$2"
  if [[ -z "$flag" ]]; then
    return
  fi

  # shellcheck disable=SC1083
  eval "local -a current=(\"\${${array_name}[@]:-}\")"
  local existing
  for existing in "${current[@]}"; do
    if [[ "$existing" == "$flag" ]]; then
      return
    fi
  done

  # shellcheck disable=SC1083
  eval "${array_name}+=(\"\$flag\")"
}

build_common::read_cmake_version() {
  if [[ -n "${BUILD_COMMON_CMAKE_VERSION_AVAILABLE:-}" ]]; then
    [[ "${BUILD_COMMON_CMAKE_VERSION_AVAILABLE}" == "1" ]]
    return
  fi

  local version_line version major minor patch
  version_line="$(cmake --version 2>/dev/null | head -n 1 || true)"
  if [[ -z "$version_line" ]]; then
    BUILD_COMMON_CMAKE_VERSION_AVAILABLE=0
    return 1
  fi

  version="$(printf '%s' "$version_line" | sed -n 's/^cmake version \([0-9.]*\)$/\1/p')"
  if [[ -z "$version" ]]; then
    version="$(printf '%s' "$version_line" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1)"
  fi

  if [[ -z "$version" ]]; then
    BUILD_COMMON_CMAKE_VERSION_AVAILABLE=0
    return 1
  fi

  IFS='.' read -r major minor patch <<<"${version}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"

  BUILD_COMMON_CMAKE_VERSION_MAJOR="$major"
  BUILD_COMMON_CMAKE_VERSION_MINOR="$minor"
  BUILD_COMMON_CMAKE_VERSION_PATCH="$patch"
  BUILD_COMMON_CMAKE_VERSION_AVAILABLE=1
  return 0
}

build_common::cmake_supports_parallel() {
  if [[ -n "${BUILD_COMMON_CMAKE_PARALLEL_CACHE:-}" ]]; then
    [[ "${BUILD_COMMON_CMAKE_PARALLEL_CACHE}" == "1" ]]
    return
  fi

  if ! build_common::read_cmake_version; then
    BUILD_COMMON_CMAKE_PARALLEL_CACHE=0
    return 1
  fi

  local major minor
  major="${BUILD_COMMON_CMAKE_VERSION_MAJOR:-0}"
  minor="${BUILD_COMMON_CMAKE_VERSION_MINOR:-0}"

  if (( major > 3 )) || (( major == 3 && minor >= 12 )); then
    BUILD_COMMON_CMAKE_PARALLEL_CACHE=1
    return 0
  fi

  BUILD_COMMON_CMAKE_PARALLEL_CACHE=0
  return 1
}

build_common::cmake_supports_source_build_args() {
  if [[ -n "${BUILD_COMMON_CMAKE_SOURCE_ARGS_CACHE:-}" ]]; then
    [[ "${BUILD_COMMON_CMAKE_SOURCE_ARGS_CACHE}" == "1" ]]
    return
  fi

  if ! build_common::read_cmake_version; then
    BUILD_COMMON_CMAKE_SOURCE_ARGS_CACHE=0
    return 1
  fi

  local major minor
  major="${BUILD_COMMON_CMAKE_VERSION_MAJOR:-0}"
  minor="${BUILD_COMMON_CMAKE_VERSION_MINOR:-0}"

  if (( major > 3 )) || (( major == 3 && minor >= 13 )); then
    BUILD_COMMON_CMAKE_SOURCE_ARGS_CACHE=1
    return 0
  fi

  BUILD_COMMON_CMAKE_SOURCE_ARGS_CACHE=0
  return 1
}

build_common::cmake_generator_is_multi_config() {
  local build_dir="$1"
  local cache_file="${build_dir%/}/CMakeCache.txt"

  if [[ ! -f "$cache_file" ]]; then
    return 1
  fi

  local generator
  generator="$(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$cache_file" | head -n 1)"
  case "${generator}" in
    *"Visual Studio"*|*"Xcode"*|*"Multi-Config"*)
      return 0
      ;;
  esac

  local config_types
  config_types="$(sed -n 's/^CMAKE_CONFIGURATION_TYPES:STRING=//p' "$cache_file" | head -n 1)"
  config_types="${config_types//[[:space:]]/}"
  config_types="${config_types//;/}"
  if [[ -n "$config_types" ]]; then
    return 0
  fi

  return 1
}

build_common::prepend_unique_path() {
  local var_name="$1"
  local new_dir="$2"
  if [[ -z "$new_dir" || ! -d "$new_dir" ]]; then
    return
  fi
  local resolved_dir
  resolved_dir="$(cd "$new_dir" 2>/dev/null && pwd 2>/dev/null || printf '%s' "$new_dir")"
  # shellcheck disable=SC2140
  local current="${!var_name:-}"
  case ":${current}:" in
    *":${resolved_dir}:"*)
      return
      ;;
  esac
  if [[ -n "$current" ]]; then
    printf -v "$var_name" '%s' "${resolved_dir}:${current}"
  else
    printf -v "$var_name" '%s' "$resolved_dir"
  fi
}

build_common::detect_llvm_mingw_root() {
  local triple="$1"
  local compiler_path="${2:-}"

  if [[ -n "${LLVM_MINGW_ROOT:-}" && -d "${LLVM_MINGW_ROOT}/${triple}" ]]; then
    return 0
  fi

  local -a candidate_bins=()
  if [[ -n "$compiler_path" ]]; then
    local compiler_dir
    compiler_dir="$(cd "$(dirname "$compiler_path")" 2>/dev/null && pwd 2>/dev/null || dirname "$compiler_path")"
    candidate_bins+=("$compiler_dir")
  fi

  local triple_clang
  triple_clang="$(command -v "${triple}-clang" 2>/dev/null || true)"
  if [[ -n "$triple_clang" ]]; then
    local clang_dir
    clang_dir="$(cd "$(dirname "$triple_clang")" 2>/dev/null && pwd 2>/dev/null || dirname "$triple_clang")"
    candidate_bins+=("$clang_dir")
  fi

  local bin_dir
  for bin_dir in "${candidate_bins[@]}"; do
    [[ -z "$bin_dir" ]] && continue
    local candidate_root
    candidate_root="$(cd "${bin_dir}/.." 2>/dev/null && pwd 2>/dev/null || true)"
    if [[ -n "$candidate_root" && -d "${candidate_root}/${triple}" ]]; then
      export LLVM_MINGW_ROOT="$candidate_root"
      return 0
    fi
  done

  return 0
}

build_common::prefer_llvm_mingw_sysroot() { 
  local triple="$1"

  if [[ -z "${LLVM_MINGW_ROOT:-}" || -z "$triple" ]]; then
    return 1
  fi

  local previous_sysroot="${MINGW_SYSROOT:-}"
  local -a candidates=()
  candidates+=("${LLVM_MINGW_ROOT}/${triple}")
  candidates+=("${LLVM_MINGW_ROOT}")

  local candidate
  for candidate in "${candidates[@]}"; do
    if build_common::mingw_sysroot_has_includes "$candidate" "$triple"; then
      local chosen_sysroot="${MINGW_SYSROOT:-}"
      if [[ -n "$previous_sysroot" && "$previous_sysroot" != "$chosen_sysroot" ]]; then
        export MINGW_FALLBACK_SYSROOT="$previous_sysroot"
      else
        unset MINGW_FALLBACK_SYSROOT
      fi
      return 0
    fi
  done

  if [[ -n "$previous_sysroot" ]]; then
    export MINGW_SYSROOT="$previous_sysroot"
  else
    unset MINGW_SYSROOT
  fi
  unset MINGW_FALLBACK_SYSROOT
  return 1
}

build_common::mingw_sysroot_has_includes() {
  local root="$1"
  local triple="$2"
  if [[ -z "$root" ]]; then
    return 1
  fi

  local resolved
  resolved="$(cd "$root" 2>/dev/null && pwd 2>/dev/null || printf '%s' "$root")"

  local candidate
  for candidate in \
    "$resolved" \
    "$resolved/${triple}"; do
    if [[ -d "${candidate}/include" ]]; then
      if [[ -f "${candidate}/include/stdlib.h" || -f "${candidate}/include/stdio.h" ]]; then
        export MINGW_SYSROOT="$candidate"
        return 0
      fi
    fi
  done

  return 1
}

build_common::discover_mingw_sysroot() {
  local triple="$1"
  local compiler_path="${2:-}"

  if [[ -n "${MINGW_TRIPLE:-}" && "${MINGW_TRIPLE}" != "$triple" ]]; then
    unset MINGW_SYSROOT
  fi

  if build_common::mingw_sysroot_has_includes "${MINGW_SYSROOT:-}" "$triple"; then
    return 0
  fi

  local compiler_dir=""
  if [[ -n "$compiler_path" ]]; then
    compiler_dir="$(cd "$(dirname "$compiler_path")" 2>/dev/null && pwd 2>/dev/null || dirname "$compiler_path")"
  fi

  local -a candidates=()
  if [[ -n "$compiler_dir" ]]; then
    candidates+=("${compiler_dir}/..")
    candidates+=("${compiler_dir}/../${triple}")
    candidates+=("${compiler_dir}/../../${triple}")
  fi

  if command -v "${triple}-gcc" >/dev/null 2>&1; then
    local gcc_sysroot
    gcc_sysroot="$("${triple}-gcc" -print-sysroot 2>/dev/null || true)"
    candidates+=("${gcc_sysroot}")
  fi

  if [[ -n "${LLVM_MINGW_ROOT:-}" ]]; then
    candidates+=("${LLVM_MINGW_ROOT}")
    candidates+=("${LLVM_MINGW_ROOT}/${triple}")
  fi

  candidates+=("/usr/${triple}")
  candidates+=("/opt/${triple}")

  local -a msys_prefixes=(/mingw64 /ucrt64 /clang64 /mingw32 /opt/mingw /opt/llvm-mingw)
  local prefix
  for prefix in "${msys_prefixes[@]}"; do
    candidates+=("${prefix}")
    candidates+=("${prefix}/${triple}")
  done

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    if build_common::mingw_sysroot_has_includes "$candidate" "$triple"; then
      return 0
    fi
  done
}

build_common::apply_mingw_sysroot_flags() {
  local triple="$1"
  local cflags_var="$2"
  local cxxflags_var="$3"
  local cmake_flags_var="${4:-}"
  local cmake_array_var="${5:-}"

  local sysroot="${MINGW_SYSROOT:-}"
  if [[ -z "$sysroot" ]]; then
    return 0
  fi

  local sysroot_tool_path
  sysroot_tool_path="$(build_common::to_tool_path "$sysroot")"

  build_common::append_unique_flag "$cflags_var" "--sysroot=${sysroot_tool_path}"
  build_common::append_unique_flag "$cxxflags_var" "--sysroot=${sysroot_tool_path}"

  local include_semicolon_list=""
  local libcxx_semicolon_list=""
  local -a c_include_tool_paths
  c_include_tool_paths=()
  local -a libcxx_tool_paths
  libcxx_tool_paths=()
  local preferred_stdlib="${BUILD_COMMON_MINGW_STDLIB:-}"
  local skip_libcxx_includes=0
  if [[ "$preferred_stdlib" == "libstdc++" ]]; then
    skip_libcxx_includes=1
  fi

  if [[ -n "$cmake_flags_var" ]]; then
    build_common::append_unique_flag "$cmake_flags_var" "$(build_common::shell_escape "-DCMAKE_SYSROOT=${sysroot_tool_path}")"
  fi
  if [[ -n "$cmake_array_var" ]]; then
    build_common::append_unique_array_flag "$cmake_array_var" "-DCMAKE_SYSROOT=${sysroot_tool_path}"
  fi

  local -a include_candidates=()
  include_candidates+=("${sysroot}/include")
  include_candidates+=("${sysroot}/ucrt/include")

  if [[ -n "$triple" ]]; then
    include_candidates+=("${sysroot}/${triple}/include")
    include_candidates+=("${sysroot}/${triple}/ucrt/include")
  fi

  if [[ -n "$triple" ]]; then
    local gcc_root
    gcc_root="${sysroot}/lib/gcc/${triple}"
    if [[ ! -d "$gcc_root" ]]; then
      local sysroot_parent
      sysroot_parent="$(cd "${sysroot}/.." 2>/dev/null && pwd 2>/dev/null || true)"
      if [[ -n "$sysroot_parent" ]]; then
        if [[ -d "${sysroot_parent}/lib/gcc/${triple}" ]]; then
          gcc_root="${sysroot_parent}/lib/gcc/${triple}"
        fi
      fi
    fi
    if [[ -d "$gcc_root" ]]; then
      local gcc_version_dir
      gcc_version_dir="$(find "$gcc_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
      if [[ -n "$gcc_version_dir" && -d "$gcc_version_dir" ]]; then
        include_candidates+=("${gcc_version_dir}/include")
        include_candidates+=("${gcc_version_dir}/include-fixed")
      fi
    fi
  fi

  local sysroot_parent
  sysroot_parent="$(cd "${sysroot}/.." 2>/dev/null && pwd 2>/dev/null || true)"
  if [[ -n "$sysroot_parent" && "$sysroot_parent" != "$sysroot" ]]; then
    include_candidates+=("${sysroot_parent}/include")
    include_candidates+=("${sysroot_parent}/ucrt/include")
    if [[ -n "$triple" ]]; then
      include_candidates+=("${sysroot_parent}/${triple}/include")
      include_candidates+=("${sysroot_parent}/${triple}/ucrt/include")
    fi
  fi

  local candidate
  for candidate in "${include_candidates[@]}"; do
    if [[ -z "$candidate" || ! -d "$candidate" ]]; then
      continue
    fi
    if [[ ! -f "${candidate}/stdlib.h" && ! -f "${candidate}/stdio.h" ]]; then
      continue
    fi
    local include_tool_path
    include_tool_path="$(build_common::to_tool_path "$candidate")"
    local already_listed=0
    local listed_path
    if (( ${#c_include_tool_paths[@]} )); then
      for listed_path in "${c_include_tool_paths[@]}"; do
        if [[ "$listed_path" == "$include_tool_path" ]]; then
          already_listed=1
          break
        fi
      done
    fi
    if (( !already_listed )); then
      c_include_tool_paths+=("$include_tool_path")
    fi
    if [[ -n "$include_tool_path" ]]; then
      case ";${include_semicolon_list};" in
        *";${include_tool_path};"*) ;;
        *)
          if [[ -n "$include_semicolon_list" ]]; then
            include_semicolon_list+=";"
          fi
          include_semicolon_list+="$include_tool_path"
          ;;
      esac
    fi
  done

  local -a cxx_sysroots
  cxx_sysroots=("${sysroot}")
  local fallback_sysroot="${MINGW_FALLBACK_SYSROOT:-}"
  if [[ -n "$fallback_sysroot" && "$fallback_sysroot" != "$sysroot" ]]; then
    cxx_sysroots+=("${fallback_sysroot}")
  fi

  local current_sysroot
  for current_sysroot in "${cxx_sysroots[@]}"; do
    if [[ -z "$current_sysroot" ]]; then
      continue
    fi

    local current_parent
    current_parent="$(cd "${current_sysroot}/.." 2>/dev/null && pwd 2>/dev/null || true)"

    local -a cxx_roots
    cxx_roots=()
    cxx_roots+=("${current_sysroot}/include")
    if [[ -n "$triple" ]]; then
      cxx_roots+=("${current_sysroot}/${triple}/include")
    fi
    if [[ -n "$current_parent" && "$current_parent" != "$current_sysroot" ]]; then
      cxx_roots+=("${current_parent}/include")
      if [[ -n "$triple" ]]; then
        cxx_roots+=("${current_parent}/${triple}/include")
      fi
    fi

    local root
    for root in "${cxx_roots[@]}"; do
      if [[ ! -d "$root" ]]; then
        continue
      fi

      local libcxx_path="${root}/c++/v1"
      if (( !skip_libcxx_includes )) && [[ -d "$libcxx_path" ]]; then
        if [[ -f "${libcxx_path}/vector" || -f "${libcxx_path}/string" || -f "${libcxx_path}/memory" ]]; then
          local libcxx_tool_path
          libcxx_tool_path="$(build_common::to_tool_path "$libcxx_path")"
          local already_cxx_listed=0
          if (( ${#libcxx_tool_paths[@]} )); then
            for listed_path in "${libcxx_tool_paths[@]}"; do
              if [[ "$listed_path" == "$libcxx_tool_path" ]]; then
                already_cxx_listed=1
                break
              fi
            done
          fi
          if (( !already_cxx_listed )); then
            libcxx_tool_paths+=("$libcxx_tool_path")
          fi
          if [[ -n "$libcxx_tool_path" ]]; then
            case ";${libcxx_semicolon_list};" in
              *";${libcxx_tool_path};"*) ;;
              *)
                if [[ -n "$libcxx_semicolon_list" ]]; then
                  libcxx_semicolon_list+=";"
                fi
                libcxx_semicolon_list+="$libcxx_tool_path"
                ;;
            esac
          fi
        fi
      fi

      local cxx_version_dir
      if [[ -d "${root}/c++" ]]; then
        while IFS= read -r cxx_version_dir; do
          if [[ -z "$cxx_version_dir" ]]; then
            continue
          fi
          if (( skip_libcxx_includes )) && [[ "${cxx_version_dir##*/}" == "v1" ]]; then
            continue
          fi
          if [[ -f "${cxx_version_dir}/vector" || -f "${cxx_version_dir}/string" || -f "${cxx_version_dir}/bits/stdc++.h" ]]; then
            local cxx_tool_path
            cxx_tool_path="$(build_common::to_tool_path "$cxx_version_dir")"
            local already_libcxx_dir=0
            if (( ${#libcxx_tool_paths[@]} )); then
              for listed_path in "${libcxx_tool_paths[@]}"; do
                if [[ "$listed_path" == "$cxx_tool_path" ]]; then
                  already_libcxx_dir=1
                  break
                fi
              done
            fi
            if (( !already_libcxx_dir )); then
              libcxx_tool_paths+=("$cxx_tool_path")
            fi
            if [[ -n "$cxx_tool_path" ]]; then
              case ";${libcxx_semicolon_list};" in
                *";${cxx_tool_path};"*) ;;
                *)
                  if [[ -n "$libcxx_semicolon_list" ]]; then
                    libcxx_semicolon_list+=";"
                  fi
                  libcxx_semicolon_list+="$cxx_tool_path"
                  ;;
              esac
            fi

            if [[ -n "$triple" ]]; then
              local triple_cxx_dir
              triple_cxx_dir="${cxx_version_dir}/${triple}"
              if [[ -d "$triple_cxx_dir" ]]; then
                local triple_cxx_tool
                triple_cxx_tool="$(build_common::to_tool_path "$triple_cxx_dir")"
                local already_triple_listed=0
                if (( ${#libcxx_tool_paths[@]} )); then
                  for listed_path in "${libcxx_tool_paths[@]}"; do
                    if [[ "$listed_path" == "$triple_cxx_tool" ]]; then
                      already_triple_listed=1
                      break
                    fi
                  done
                fi
                if (( !already_triple_listed )); then
                  libcxx_tool_paths+=("$triple_cxx_tool")
                fi
                if [[ -n "$triple_cxx_tool" ]]; then
                  case ";${libcxx_semicolon_list};" in
                    *";${triple_cxx_tool};"*) ;;
                    *)
                      if [[ -n "$libcxx_semicolon_list" ]]; then
                        libcxx_semicolon_list+=";"
                      fi
                      libcxx_semicolon_list+="$triple_cxx_tool"
                      ;;
                  esac
                fi
              fi
            fi
          fi
        done < <(find "${root}/c++" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
      fi
    done
  done

  local path
  local path
  if (( ${#libcxx_tool_paths[@]} )); then
    for path in "${libcxx_tool_paths[@]}"; do
      build_common::append_unique_flag "$cxxflags_var" "-isystem${path}"
    done
  fi
  if (( ${#c_include_tool_paths[@]} )); then
    for path in "${c_include_tool_paths[@]}"; do
      build_common::append_unique_flag "$cflags_var" "-isystem${path}"
      build_common::append_unique_flag "$cxxflags_var" "-isystem${path}"
    done
  fi

  local final_semicolon_list=""
  if [[ -n "$libcxx_semicolon_list" ]]; then
    final_semicolon_list="$libcxx_semicolon_list"
  fi
  if [[ -n "$include_semicolon_list" ]]; then
    if [[ -n "$final_semicolon_list" ]]; then
      final_semicolon_list+=";"
    fi
    final_semicolon_list+="$include_semicolon_list"
  fi

  if [[ -n "$final_semicolon_list" ]]; then
    export MINGW_INCLUDE_DIRECTORIES="$final_semicolon_list"
  fi
}

build_common::ensure_mingw_environment() {
  local triple="$1"
  local compiler_bin="${2:-}"
  local compiler_path=""
  if [[ -n "$compiler_bin" ]]; then
    compiler_path="$(command -v "$compiler_bin" 2>/dev/null || true)"
  fi

  build_common::detect_llvm_mingw_root "$triple" "$compiler_path"

  if [[ -n "${LLVM_MINGW_ROOT:-}" && -d "${LLVM_MINGW_ROOT}/bin" ]]; then
    build_common::prepend_unique_path PATH "${LLVM_MINGW_ROOT}/bin"
  fi

  unset MINGW_FALLBACK_SYSROOT
  build_common::discover_mingw_sysroot "$triple" "$compiler_path"

  if [[ -z "${MINGW_TRIPLE:-}" ]]; then
    export MINGW_TRIPLE="$triple"
  fi
}

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

  local -a common_args=(
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

  if [[ -n "${MINGW_INCLUDE_DIRECTORIES:-}" ]]; then
    common_args+=(
      "-DCMAKE_C_STANDARD_INCLUDE_DIRECTORIES=${MINGW_INCLUDE_DIRECTORIES}"
      "-DCMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES=${MINGW_INCLUDE_DIRECTORIES}"
    )
  fi

  common_args+=("$@")

  if build_common::cmake_supports_source_build_args; then
    local -a cmake_args=(
      -S "$source_dir"
      -B "$build_dir"
    )
    cmake_args+=("${common_args[@]}")
    cmake "${cmake_args[@]}"
    return
  fi

  (
    cd "$build_dir"
    cmake "${common_args[@]}" "$source_dir"
  )
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
  local -a cmake_build_cmd=(cmake --build "$build_dir")
  if build_common::cmake_generator_is_multi_config "$build_dir"; then
    cmake_build_cmd+=(--config Release)
  fi
  cmake_build_cmd+=(--target "$target")
  if [[ -n "$parallel_jobs" ]] && build_common::cmake_supports_parallel; then
    cmake_build_cmd+=(--parallel "$parallel_jobs")
  elif [[ -z "${BUILD_COMMON_CMAKE_PARALLEL_WARNED:-}" ]]; then
    echo "⚠️  Detected CMake without --parallel support; falling back to serialized builds." >&2
    BUILD_COMMON_CMAKE_PARALLEL_WARNED=1
  fi
  "${cmake_build_cmd[@]}" 2>&1
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
