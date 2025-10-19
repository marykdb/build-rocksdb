#!/usr/bin/env bash

# Common helper functions shared across build scripts for RocksDB.

BUILD_COMMON_VALIDATED_MINGW_ROOTS=""

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

build_common::remove_matching_flag() {
  local var_name="$1"
  local pattern="$2"
  if [[ -z "$pattern" ]]; then
    return
  fi

  # shellcheck disable=SC2154
  local current="${!var_name:-}"
  if [[ -z "$current" ]]; then
    return
  fi

  local -a tokens=()
  read -r -a tokens <<<"$current"
  local -a kept=()
  local token
  for token in "${tokens[@]}"; do
    if [[ "$token" == $pattern ]]; then
      continue
    fi
    kept+=("$token")
  done

  local result="${kept[*]}"
  printf -v "$var_name" '%s' "$result"
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

build_common::find_tool() {
  if (( $# == 0 )); then
    return 1
  fi

  local candidate
  for candidate in "$@"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

build_common::coff_replace_section_name() {
  local object_file="$1"
  local old_name="$2"
  local new_name="$3"

  if [[ -z "$object_file" || -z "$old_name" || -z "$new_name" ]]; then
    return 1
  fi

  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    echo "❌ Unable to locate python interpreter to rewrite COFF section names" >&2
    return 1
  fi

  "$python_bin" - "$object_file" "$old_name" "$new_name" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old = sys.argv[2].encode('ascii')
new = sys.argv[3].encode('ascii')

needle = old + b'\x00'
if len(new) > len(old):
    sys.stderr.write("replacement name longer than original\n")
    sys.exit(1)

data = path.read_bytes()
count = data.count(needle)
if count == 0:
    sys.stderr.write("section name not found in object\n")
    sys.exit(1)

replacement = new + b'\x00'
if len(new) < len(old):
    replacement += b'\x00' * (len(old) - len(new))

data = data.replace(needle, replacement)
path.write_bytes(data)
PY
}

build_common::ar_extract_output_is_symbol_warning() {
  local output="$1"
  local line
  local recognized=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *"illegal output pathname for archive member: /"*|\
      *"illegal output pathname for archive member: //"*|\
      "No such file or directory")
        recognized=1
        continue
        ;;
      *)
        return 1
        ;;
    esac
  done <<<"$output"

  if (( recognized )); then
    return 0
  fi
  return 1
}

build_common::mingw_binutils_candidates() {
  local preferred_triple="${1:-}"

  local -n _objdump_candidates_ref="$2"
  local -n _objcopy_candidates_ref="$3"
  local -n _ar_candidates_ref="$4"
  local -n _ranlib_candidates_ref="$5"

  _objdump_candidates_ref=()
  _objcopy_candidates_ref=()
  _ar_candidates_ref=()
  _ranlib_candidates_ref=()

  if [[ -n "$preferred_triple" ]]; then
    _objdump_candidates_ref+=("${preferred_triple}-objdump")
    _objcopy_candidates_ref+=("${preferred_triple}-objcopy")
    _ar_candidates_ref+=("${preferred_triple}-ar")
    _ranlib_candidates_ref+=("${preferred_triple}-ranlib")
  fi

  local mingw_triple="${MINGW_TRIPLE:-}"
  if [[ -n "$mingw_triple" && "$mingw_triple" != "$preferred_triple" ]]; then
    _objdump_candidates_ref+=("${mingw_triple}-objdump")
    _objcopy_candidates_ref+=("${mingw_triple}-objcopy")
    _ar_candidates_ref+=("${mingw_triple}-ar")
    _ranlib_candidates_ref+=("${mingw_triple}-ranlib")
  fi

  _objdump_candidates_ref+=(llvm-objdump objdump)
  _objcopy_candidates_ref+=(llvm-objcopy objcopy)
  _ar_candidates_ref+=(llvm-ar ar)
  _ranlib_candidates_ref+=(llvm-ranlib ranlib)
}

build_common::is_mingw_triple() {
  local triple="${1:-}"
  if [[ -z "$triple" ]]; then
    return 1
  fi

  case "$triple" in
    *-w64-mingw32*) return 0 ;;
    *) return 1 ;;
  esac
}

build_common::mitigate_mingw_refptr_comdats() {
  local archive="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$archive" || ! -f "$archive" ]]; then
    return 0
  fi

  local -a objdump_candidates=()
  local -a objcopy_candidates=()
  local -a ar_candidates=()
  local -a ranlib_candidates=()
  build_common::mingw_binutils_candidates "$preferred_triple" objdump_candidates objcopy_candidates ar_candidates ranlib_candidates

  local objdump_bin=""
  local ar_bin=""
  local ranlib_bin=""

  if ! objdump_bin="$(build_common::find_tool "${objdump_candidates[@]}")"; then
    objdump_bin=""
  fi
  if ! ar_bin="$(build_common::find_tool "${ar_candidates[@]}")"; then
    ar_bin=""
  fi
  if ! ranlib_bin="$(build_common::find_tool "${ranlib_candidates[@]}")"; then
    ranlib_bin=""
  fi

  local -a objcopy_bins=()
  if [[ -n "${OBJCOPY:-}" ]]; then
    local objcopy_env="${OBJCOPY%% *}"
    if [[ -x "$objcopy_env" ]]; then
      objcopy_bins+=("$objcopy_env")
    fi
  fi
  if [[ -n "${LLVM_MINGW_ROOT:-}" ]]; then
    local llvm_objcopy_path=""
    for candidate in "${LLVM_MINGW_ROOT}/bin/llvm-objcopy" "${LLVM_MINGW_ROOT}/bin/llvm-objcopy.exe"; do
      if [[ -x "$candidate" ]]; then
        llvm_objcopy_path="$candidate"
        break
      fi
    done
    if [[ -n "$llvm_objcopy_path" ]]; then
      objcopy_bins+=("$llvm_objcopy_path")
    fi
  fi
  local candidate resolved
  for candidate in "${objcopy_candidates[@]}"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      objcopy_bins+=("$resolved")
    fi
  done

  if (( ${#objcopy_bins[@]} )); then
    local -a deduped=()
    declare -A objcopy_seen=()
    for resolved in "${objcopy_bins[@]}"; do
      if [[ -z "${objcopy_seen[$resolved]:-}" ]]; then
        deduped+=("$resolved")
        objcopy_seen[$resolved]=1
      fi
    done
    objcopy_bins=("${deduped[@]}")
  fi

  if [[ -z "$objdump_bin" || ${#objcopy_bins[@]} == 0 || -z "$ar_bin" ]]; then
    echo "❌ Unable to sanitize MinGW archive ${archive}: required binutils not found" >&2
    return 1
  fi

  local objcopy_index=0
  local objcopy_bin="${objcopy_bins[$objcopy_index]}"

  local archive_dir archive_base archive_abs
  archive_dir="$(cd "$(dirname "$archive")" 2>/dev/null && pwd 2>/dev/null)"
  archive_base="$(basename "$archive")"
  if [[ -z "$archive_dir" ]]; then
    archive_abs="$archive"
  else
    archive_abs="${archive_dir}/${archive_base}"
  fi

  local tmpdir
  tmpdir="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmpdir" ]]; then
    echo "⚠️  Unable to create temporary directory to patch ${archive}" >&2
    return 1
  fi

  local cleanup
  cleanup() {
    rm -rf "$tmpdir"
  }

  local -a members=()
  local members_output
  if ! members_output="$("$ar_bin" t "$archive_abs" 2>/dev/null)"; then
    cleanup
    return 1
  fi
  while IFS= read -r member_line; do
    members+=("$member_line")
  done <<<"$members_output"

  local -a object_members=()
  local member
  for member in "${members[@]}"; do
    member="${member%$'\r'}"
    if [[ -z "$member" ]]; then
      continue
    fi
    case "$member" in
      /|//|//*)
        continue
        ;;
    esac
    object_members+=("$member")
  done

  if (( ${#object_members[@]} == 0 )); then
    cleanup
    return 0
  fi

  (
    set -euo pipefail
    cd "$tmpdir"

    local -a temp_member_files=()
    local idx=0
    local member temp_file
    for member in "${object_members[@]}"; do
      temp_file="${tmpdir}/member_${idx}.obj"
      if ! "$ar_bin" p "$archive_abs" "$member" >"$temp_file" 2>/dev/null; then
        printf '❌ Unable to extract %s from %s\n' "$member" "$archive_abs" >&2
        exit 1
      fi
      temp_member_files+=("$temp_file")
      ((idx++))
    done

    local -a sections=()
    local modified=0
    local renamed_sections=0
    local logged=0

    for idx in "${!object_members[@]}"; do
      member="${object_members[idx]}"
      temp_file="${temp_member_files[idx]}"
      if [[ ! -f "$temp_file" ]]; then
        continue
      fi
      sections=()
      while IFS= read -r section_line; do
        sections+=("$section_line")
      done < <("$objdump_bin" -h "$temp_file" 2>/dev/null | awk '$2 ~ /\.refptr/ {print $2}')
      if (( ${#sections[@]} == 0 )); then
        continue
      fi
      modified=1
      if (( ! logged )); then
        echo "🔧 [MinGW] rewriting refptr COMDATs in ${archive_abs}" >&2
        logged=1
      fi
      local section
      for section in "${sections[@]}"; do
        local new_name="$section"
        new_name="${new_name/.rdata$.refptr\./.rdata\$refptr_}"
        if [[ "$new_name" == "$section" ]]; then
          new_name="${new_name/.rdata$.refptr/.rdata\$refptr_}"
        fi
        if [[ "$new_name" == "$section" ]]; then
          new_name="${new_name/.refptr\./.refptr\$}"
        fi
        if [[ "$new_name" == "$section" ]]; then
          echo "❌ Unable to compute sanitized name for section ${section} in ${member}" >&2
          exit 1
        fi
        local rename_output=""
        local rewritten=0
        while :; do
          if rename_output="$("$objcopy_bin" --rename-section "${section}=${new_name},alloc,load,readonly,data" "$temp_file" 2>&1)"; then
            rewritten=1
            break
          fi
          if [[ "$rename_output" == *"file in wrong format"* ]]; then
            if (( (objcopy_index + 1) < ${#objcopy_bins[@]} )); then
              ((objcopy_index++))
              objcopy_bin="${objcopy_bins[$objcopy_index]}"
              echo "ℹ️  [MinGW] retrying section rewrite using ${objcopy_bin}" >&2
              continue
            fi
            if build_common::coff_replace_section_name "$temp_file" "$section" "$new_name"; then
              rewritten=1
              break
            fi
          fi
          if [[ "$rename_output" == *"option is not supported for COFF"* ]]; then
            if ! build_common::coff_replace_section_name "$temp_file" "$section" "$new_name"; then
              printf '%s\n' "$rename_output" >&2
              echo "❌ Unable to rewrite COFF section ${section} in ${member}" >&2
              exit 1
            fi
            rewritten=1
            break
          fi
          printf '%s\n' "$rename_output" >&2
          exit 1
        done
        if (( ! rewritten )); then
          echo "❌ Unable to rewrite section ${section} in ${member}" >&2
          exit 1
        fi
        ((renamed_sections++))
      done
    done

    if (( modified )); then
      local new_archive="${archive_abs}.tmp"
      rm -f "$new_archive"
      local stage_dir="$tmpdir/stage"
      mkdir -p "$stage_dir"
      for idx in "${!object_members[@]}"; do
        member="${object_members[idx]}"
        temp_file="${temp_member_files[idx]}"
        local staging_path="${stage_dir}/${member}"
        cp "$temp_file" "$staging_path"
        "$ar_bin" qc "$new_archive" "$staging_path"
        rm -f "$staging_path"
      done
      if [[ -n "$ranlib_bin" ]]; then
        "$ranlib_bin" "$new_archive" >/dev/null 2>&1 || true
      fi
      mv "$new_archive" "$archive_abs"
      echo "✅ [MinGW] sanitized ${archive_abs} (${renamed_sections} sections updated)" >&2
    fi
  )

  local compression_flag="${DISABLE_ROCKSDB_OPTIONAL_COMPRESSION:-0}"
  if [[ "$compression_flag" == "1" ]]; then
    common_args+=(
      -DWITH_SNAPPY=OFF
      -DWITH_LZ4=OFF
      -DWITH_ZSTD=OFF
      -DWITH_BZ2=OFF
    )
  else
    common_args+=(
      -DWITH_SNAPPY=ON
      -DWITH_LZ4=ON
      -DWITH_ZSTD=ON
      -DWITH_BZ2=ON
    )
  fi
  common_args+=(
    -DWITH_ZLIB=ON
  )

  local status=$?
  cleanup
  return $status
}

build_common::verify_mingw_refptr_sections_rewritten() {
  local archive="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$archive" ]]; then
    echo "❌ MinGW archive path was not provided" >&2
    return 1
  fi

  local archive_dir archive_base archive_abs
  archive_dir="$(cd "$(dirname "$archive")" 2>/dev/null && pwd 2>/dev/null)"
  archive_base="$(basename "$archive")"
  if [[ -z "$archive_dir" ]]; then
    archive_abs="$archive"
  else
    archive_abs="${archive_dir}/${archive_base}"
  fi

  if [[ ! -f "$archive_abs" ]]; then
    echo "❌ Expected MinGW archive ${archive} but it was not found" >&2
    return 1
  fi

  local -a objdump_candidates=()
  local -a dummy=()
  build_common::mingw_binutils_candidates "$preferred_triple" objdump_candidates dummy dummy dummy

  local objdump_bin=""
  if ! objdump_bin="$(build_common::find_tool "${objdump_candidates[@]}")"; then
    echo "❌ Unable to locate objdump to validate ${archive}" >&2
    return 1
  fi

  local -a ar_candidates=()
  local -a dummy=()
  build_common::mingw_binutils_candidates "$preferred_triple" dummy dummy ar_candidates dummy

  local ar_bin=""
  if ! ar_bin="$(build_common::find_tool "${ar_candidates[@]}")"; then
    echo "❌ Unable to locate ar to inspect ${archive}" >&2
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmpdir" ]]; then
    echo "❌ Unable to create temporary directory to verify ${archive}" >&2
    return 1
  fi

  local cleanup
  cleanup() {
    rm -rf "$tmpdir"
  }

  local -a members=()
  local members_output
  if ! members_output="$("$ar_bin" t "$archive_abs" 2>/dev/null)"; then
    cleanup
    return 1
  fi
  while IFS= read -r member_line; do
    members+=("$member_line")
  done <<<"$members_output"

  local -a object_members=()
  local member
  for member in "${members[@]}"; do
    member="${member%$'\r'}"
    if [[ -z "$member" ]]; then
      continue
    fi
    case "$member" in
      /|//|//*)
        continue
        ;;
    esac
    object_members+=("$member")
  done

  if (( ${#object_members[@]} == 0 )); then
    cleanup
    echo "🧪 [MinGW] verification passed for ${archive_abs}" >&2
    return 0
  fi

  local status=0
  (
    set -euo pipefail
    cd "$tmpdir"

    local -a temp_member_files=()
    local idx=0
    local member temp_file
    for member in "${object_members[@]}"; do
      temp_file="${tmpdir}/member_${idx}.obj"
      if ! "$ar_bin" p "$archive_abs" "$member" >"$temp_file" 2>/dev/null; then
        printf '❌ Unable to extract %s from %s\n' "$member" "$archive_abs" >&2
        exit 1
      fi
      temp_member_files+=("$temp_file")
      ((idx++))
    done

    for idx in "${!object_members[@]}"; do
      member="${object_members[idx]}"
      temp_file="${temp_member_files[idx]}"
      if [[ ! -f "$temp_file" ]]; then
        continue
      fi
      if "$objdump_bin" -h "$temp_file" 2>/dev/null | grep -Fq '.refptr'; then
        echo "❌ MinGW refptr COMDATs remain in ${archive_abs} (member ${member})" >&2
        exit 1
      fi
    done
  ) || status=$?

  cleanup
  if (( status == 0 )); then
    echo "🧪 [MinGW] verification passed for ${archive_abs}" >&2
  fi
  return $status
}


build_common::sanitize_mingw_archives_in_tree() {
  local root_dir="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$root_dir" || ! -d "$root_dir" ]]; then
    return 0
  fi

  local normalized_root
  normalized_root="$(cd "$root_dir" 2>/dev/null && pwd 2>/dev/null || true)"
  if [[ -n "$normalized_root" ]]; then
    root_dir="$normalized_root"
  fi

  local stamp_file="${root_dir%/}/.mingw_refptr_sanitized"
  if [[ -f "$stamp_file" ]]; then
    if ! find "$root_dir" -type f -name '*.a' -newer "$stamp_file" -print -quit 2>/dev/null | grep -q .; then
      echo "ℹ️  [MinGW] archives already sanitized under ${root_dir} (stamp up to date)" >&2
      return 0
    fi
  fi

  echo "🔍 [MinGW] scanning ${root_dir} for static archives" >&2

  local -a archives=()
  while IFS= read -r -d '' archive_path; do
    archives+=("$archive_path")
  done < <(find "$root_dir" -type f -name '*.a' -print0 2>/dev/null)

  if (( ${#archives[@]} == 0 )); then
    return 0
  fi

  local archive
  local overall_status=0
  for archive in "${archives[@]}"; do
    if ! build_common::mitigate_mingw_refptr_comdats "$archive" "$preferred_triple"; then
      overall_status=1
      continue
    fi
    if ! build_common::verify_mingw_refptr_sections_rewritten "$archive" "$preferred_triple"; then
      overall_status=1
    fi
  done

  if (( overall_status == 0 )); then
    touch "$stamp_file" 2>/dev/null || true
  fi

  return $overall_status
}

build_common::assert_mingw_archives_sanitized() {
  local root_dir="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$root_dir" ]]; then
    echo "❌ MinGW archive directory was not provided" >&2
    return 1
  fi

  if [[ ! -d "$root_dir" ]]; then
    echo "❌ Expected MinGW archive directory ${root_dir} but it was not found" >&2
    return 1
  fi

  local normalized_root
  normalized_root="$(cd "$root_dir" 2>/dev/null && pwd 2>/dev/null || true)"
  if [[ -n "$normalized_root" ]]; then
    root_dir="$normalized_root"
  fi

  if [[ ":${BUILD_COMMON_VALIDATED_MINGW_ROOTS:-}:" == *":$root_dir:"* ]]; then
    return 0
  fi

  local stamp_file="${root_dir%/}/.mingw_refptr_sanitized"
  if [[ -f "$stamp_file" ]]; then
    if ! find "$root_dir" -type f -name '*.a' -newer "$stamp_file" -print -quit 2>/dev/null | grep -q .; then
      if [[ -n "${BUILD_COMMON_VALIDATED_MINGW_ROOTS:-}" ]]; then
        BUILD_COMMON_VALIDATED_MINGW_ROOTS+=":$root_dir"
      else
        BUILD_COMMON_VALIDATED_MINGW_ROOTS="$root_dir"
      fi
      echo "ℹ️  [MinGW] validation skipped for ${root_dir} (stamp up to date)" >&2
      return 0
    fi
  fi

  echo "🧪 [MinGW] validating sanitized archives under ${root_dir}" >&2

  local -a archives=()
  while IFS= read -r -d '' archive_path; do
    archives+=("$archive_path")
  done < <(find "$root_dir" -type f -name '*.a' -print0 2>/dev/null)

  if (( ${#archives[@]} == 0 )); then
    echo "❌ No static libraries were discovered under ${root_dir}" >&2
    return 1
  fi

  local archive
  for archive in "${archives[@]}"; do
    if ! build_common::verify_mingw_refptr_sections_rewritten "$archive" "$preferred_triple"; then
      return 1
    fi
  done

  if [[ -n "${BUILD_COMMON_VALIDATED_MINGW_ROOTS:-}" ]]; then
    BUILD_COMMON_VALIDATED_MINGW_ROOTS+=":$root_dir"
  else
    BUILD_COMMON_VALIDATED_MINGW_ROOTS="$root_dir"
  fi

  return 0
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

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    local brew_formula
    for brew_formula in llvm-mingw mingw-w64; do
      brew_prefix="$(brew --prefix "${brew_formula}" 2>/dev/null || true)"
      if [[ -z "$brew_prefix" ]]; then
        continue
      fi
      if [[ -d "${brew_prefix}/${triple}" ]]; then
        export LLVM_MINGW_ROOT="$brew_prefix"
        return 0
      fi
      if [[ -d "${brew_prefix}/bin" ]]; then
        candidate_bins+=("${brew_prefix}/bin")
      fi
    done
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

  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    local brew_formula
    local triple_arch
    triple_arch="${triple%%-*}"
    for brew_formula in mingw-w64 llvm-mingw; do
      brew_prefix="$(brew --prefix "${brew_formula}" 2>/dev/null || true)"
      if [[ -z "$brew_prefix" ]]; then
        continue
      fi
      candidates+=("${brew_prefix}")
      candidates+=("${brew_prefix}/${triple}")
      if [[ -n "$triple_arch" ]]; then
        candidates+=("${brew_prefix}/toolchain-${triple_arch}")
        candidates+=("${brew_prefix}/toolchain-${triple_arch}/${triple}")
      fi
    done
  fi

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

  local -a cxx_roots
  cxx_roots=()
  cxx_roots+=("${sysroot}/include")
  if [[ -n "$sysroot_parent" && "$sysroot_parent" != "$sysroot" ]]; then
    cxx_roots+=("${sysroot_parent}/include")
  fi

  local root
  for root in "${cxx_roots[@]}"; do
    if [[ ! -d "$root" ]]; then
      continue
    fi

    local libcxx_path="${root}/c++/v1"
    if [[ -d "$libcxx_path" ]]; then
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
    -DROCKSDB_BUILD_SHARED=OFF
    -DROCKSDB_BUILD_STATIC=ON
    -DWITH_TESTS=OFF
    -DWITH_BENCHMARK_TOOLS=OFF
    -DWITH_TOOLS=OFF
    -DWITH_JNI=OFF
    -DWITH_JEMALLOC=OFF
    -DFAIL_ON_WARNINGS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DROCKSDB_DLL=ON
    -DROCKSDB_LIBRARY_EXPORTS=ON
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
