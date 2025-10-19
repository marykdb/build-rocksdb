#!/usr/bin/env bash

# MinGW-specific helper functions extracted from build-rocksdb-common.sh.
# These helpers rely on associative arrays and other Bash features that are not
# available in the default macOS Bash. Load this file only when building
# MinGW/Windows targets.

if [[ -n "${BUILD_COMMON_MINGW_SANITIZE_SH:-}" ]]; then
  return
fi
BUILD_COMMON_MINGW_SANITIZE_SH=1

# shellcheck disable=SC2034
BUILD_COMMON_VALIDATED_MINGW_ROOTS="${BUILD_COMMON_VALIDATED_MINGW_ROOTS:-}"
BUILD_COMMON_MINGW_BINUTILS_KEY="${BUILD_COMMON_MINGW_BINUTILS_KEY:-}"
BUILD_COMMON_MINGW_BINUTILS_READY="${BUILD_COMMON_MINGW_BINUTILS_READY:-0}"
BUILD_COMMON_MINGW_BINUTILS_OBJDUMP="${BUILD_COMMON_MINGW_BINUTILS_OBJDUMP:-}"
BUILD_COMMON_MINGW_BINUTILS_AR="${BUILD_COMMON_MINGW_BINUTILS_AR:-}"
BUILD_COMMON_MINGW_BINUTILS_RANLIB="${BUILD_COMMON_MINGW_BINUTILS_RANLIB:-}"

if ! declare -p BUILD_COMMON_MINGW_BINUTILS_OBJCOPY >/dev/null 2>&1; then
  declare -ag BUILD_COMMON_MINGW_BINUTILS_OBJCOPY=()
fi
if ! declare -p BUILD_COMMON_MINGW_SANITIZED_STATUS >/dev/null 2>&1; then
  declare -Ag BUILD_COMMON_MINGW_SANITIZED_STATUS=()
fi

build_common_mingw::coff_replace_section_name() {
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

build_common_mingw::ar_extract_output_is_symbol_warning() {
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

build_common_mingw::mingw_binutils_candidates() {
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

build_common_mingw::resolve_mingw_binutils() {
  local preferred_triple="${1:-}"
  local cache_key="${preferred_triple:-__default__}"

  if [[ "${BUILD_COMMON_MINGW_BINUTILS_READY:-0}" == "1" && "${BUILD_COMMON_MINGW_BINUTILS_KEY:-}" == "$cache_key" ]]; then
    return 0
  fi

  local -a objdump_candidates=()
  local -a objcopy_candidates=()
  local -a ar_candidates=()
  local -a ranlib_candidates=()
  build_common_mingw::mingw_binutils_candidates "$preferred_triple" objdump_candidates objcopy_candidates ar_candidates ranlib_candidates

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

  BUILD_COMMON_MINGW_BINUTILS_KEY="$cache_key"
  BUILD_COMMON_MINGW_BINUTILS_READY=1
  BUILD_COMMON_MINGW_BINUTILS_OBJDUMP="$objdump_bin"
  BUILD_COMMON_MINGW_BINUTILS_AR="$ar_bin"
  BUILD_COMMON_MINGW_BINUTILS_RANLIB="$ranlib_bin"
  BUILD_COMMON_MINGW_BINUTILS_OBJCOPY=("${objcopy_bins[@]}")

  return 0
}

build_common_mingw::is_mingw_triple() {
  local triple="${1:-}"
  if [[ -z "$triple" ]]; then
    return 1
  fi

  case "$triple" in
    *-w64-mingw32*) return 0 ;;
    *) return 1 ;;
  esac
}

build_common_mingw::mitigate_mingw_refptr_comdats() {
  local archive="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$archive" || ! -f "$archive" ]]; then
    return 0
  fi

  if ! build_common_mingw::resolve_mingw_binutils "$preferred_triple"; then
    return 1
  fi

  local objdump_bin="${BUILD_COMMON_MINGW_BINUTILS_OBJDUMP:-}"
  local ar_bin="${BUILD_COMMON_MINGW_BINUTILS_AR:-}"
  local ranlib_bin="${BUILD_COMMON_MINGW_BINUTILS_RANLIB:-}"
  local -a objcopy_bins=("${BUILD_COMMON_MINGW_BINUTILS_OBJCOPY[@]}")

  if [[ -z "$objdump_bin" || ${#objcopy_bins[@]} == 0 || -z "$ar_bin" ]]; then
    echo "❌ Unable to sanitize MinGW archive ${archive}: required binutils not found" >&2
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

  local -a members=()
  if ! mapfile -t members < <("$ar_bin" t "$archive_abs" 2>/dev/null); then
    return 1
  fi

  local -a object_members=()
  local member
  for member in "${members[@]}"; do
    member="${member%$'\r'}"
    case "$member" in
      ''|/|//|//* ) continue ;;
      * ) object_members+=("$member") ;;
    esac
  done

  if (( ${#object_members[@]} == 0 )); then
    BUILD_COMMON_MINGW_SANITIZED_STATUS["$archive_abs"]="clean"
    return 0
  fi

  declare -A member_lookup=()
  for member in "${object_members[@]}"; do
    member_lookup["$member"]=1
  done

  declare -A member_sections=()
  local -a members_with_refptr=()
  while IFS=$'\t' read -r section_member section_name; do
    if [[ -z "$section_member" || -z "$section_name" ]]; then
      continue
    fi
    if [[ -z "${member_lookup[$section_member]:-}" ]]; then
      continue
    fi
    if [[ -n "${member_sections[$section_member]:-}" ]]; then
      member_sections["$section_member"]+=$'\n'"$section_name"
    else
      member_sections["$section_member"]="$section_name"
      members_with_refptr+=("$section_member")
    fi
  done < <("$objdump_bin" --section-headers --archive-headers "$archive_abs" 2>/dev/null | awk 'BEGIN { member="" } /^[^ ]+:\s+file format/ { member=$1; sub(/:$/, "", member); next } /^[[:space:]]+[0-9]+[[:space:]]+/ { if (member == "") next; section=$2; if (section ~ /\\.refptr/) printf "%s\t%s\n", member, section; }')

  if (( ${#members_with_refptr[@]} == 0 )); then
    BUILD_COMMON_MINGW_SANITIZED_STATUS["$archive_abs"]="clean"
    local stamp_path="${archive_abs}.mingw_refptr_sanitized"
    touch "$stamp_path" 2>/dev/null || true
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d 2>/dev/null || true)"
  if [[ -z "$tmpdir" ]]; then
    echo "⚠️  Unable to create temporary directory to patch ${archive}" >&2
    return 1
  fi

  trap 'rm -rf "$tmpdir"' RETURN

  local archive_tmp="${tmpdir}/${archive_base}"
  cp "$archive_abs" "$archive_tmp"

  local extraction_output=""
  if ! extraction_output="$( (cd "$tmpdir" && "$ar_bin" x "$archive_tmp") 2>&1 )"; then
    local extracted_warning_output="$extraction_output"
    local objcopy_index=0
    local objcopy_bin="${objcopy_bins[$objcopy_index]}"
    if build_common_mingw::ar_extract_output_is_symbol_warning "$extracted_warning_output"; then
      echo "ℹ️  Retrying extraction of ${archive_base} with alternative tool" >&2
      objcopy_index=$(((objcopy_index + 1) % ${#objcopy_bins[@]}))
      objcopy_bin="${objcopy_bins[$objcopy_index]}"
      if ! (cd "$tmpdir" && "$objcopy_bin" --extract-symbol "$archive_tmp" >/dev/null 2>&1); then
        echo "❌  Failed to extract archive ${archive_abs}: ${extraction_output}" >&2
        return 1
      fi
    else
      echo "❌  Failed to extract archive ${archive_abs}: ${extraction_output}" >&2
      return 1
    fi
  fi

  local -a repack_members=()
  local renamed_sections=0
  for member in "${members_with_refptr[@]}"; do
    local member_path="${tmpdir}/${member}"
    if [[ ! -f "$member_path" ]]; then
      member_path="${tmpdir}/${member%.o}.o"
      if [[ ! -f "$member_path" ]]; then
        echo "⚠️  [MinGW] Unable to locate ${member} after extraction; skipping" >&2
        continue
      fi
    fi
    repack_members+=("${member_path##*/}")

    local sections
    IFS=$'\n' read -r -d '' -a sections < <(printf '%s\0' "${member_sections[$member]}")
    local section
    for section in "${sections[@]}"; do
      local sanitized_name="${section/.refptr/.refptr.lld}"
      if build_common_mingw::coff_replace_section_name "$member_path" "$section" "$sanitized_name"; then
        renamed_sections=$((renamed_sections + 1))
      else
        echo "⚠️  [MinGW] Failed to rewrite section ${section} in ${member}" >&2
      fi
    done
  done

  if (( renamed_sections == 0 )); then
    BUILD_COMMON_MINGW_SANITIZED_STATUS["$archive_abs"]="clean"
    local stamp_path="${archive_abs}.mingw_refptr_sanitized"
    touch "$stamp_path" 2>/dev/null || true
    return 0
  fi

  if ! (cd "$tmpdir" && "$ar_bin" r "$archive_tmp" "${repack_members[@]}" >/dev/null 2>&1); then
    echo "❌ Unable to update ${archive_abs} with rewritten members" >&2
    return 1
  fi
  if [[ -n "$ranlib_bin" ]]; then
    "$ranlib_bin" "$archive_tmp" >/dev/null 2>&1 || true
  fi
  mv "$archive_tmp" "$archive_abs"
  BUILD_COMMON_MINGW_SANITIZED_STATUS["$archive_abs"]="rewritten"
  local stamp_path="${archive_abs}.mingw_refptr_sanitized"
  touch "$stamp_path" 2>/dev/null || true
  echo "✅ [MinGW] sanitized ${archive_abs} (${renamed_sections} sections updated)" >&2

  return 0
}

build_common_mingw::verify_mingw_refptr_sections_rewritten() {
  local archive="$1"
  local preferred_triple="${2:-}"

  if [[ -n "$preferred_triple" ]] && ! build_common::is_mingw_triple "$preferred_triple"; then
    return 0
  fi

  if [[ -z "$archive" || ! -f "$archive" ]]; then
    return 0
  fi

  if ! build_common_mingw::resolve_mingw_binutils "$preferred_triple"; then
    return 1
  fi

  local objdump_bin="${BUILD_COMMON_MINGW_BINUTILS_OBJDUMP:-}"
  if [[ -z "$objdump_bin" ]]; then
    echo "❌ Unable to verify MinGW archive ${archive}: objdump not found" >&2
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

  local refptr_count
  refptr_count=$("$objdump_bin" --section-headers --archive-headers "$archive_abs" 2>/dev/null | \
    awk 'BEGIN { count = 0 } \
         /^[^ ]+:\\s+file format/ { current = $1; sub(/:$/, "", current); next } \
         /^[[:space:]]+[0-9]+[[:space:]]+/ { \
           section = $2; \
           if (section ~ /\\.refptr(\\.|$)/) count++; \
         } \
         END { print count }')

  if [[ -z "$refptr_count" ]]; then
    echo "❌ Unable to compute sanitized name for section ${section} in ${member}" >&2
    return 1
  fi

  if (( refptr_count > 0 )); then
    echo "❌ [MinGW] ${archive_abs} still contains ${refptr_count} .refptr sections" >&2
    return 1
  fi

  local stamp_path="${archive_abs}.mingw_refptr_sanitized"
  touch "$stamp_path" 2>/dev/null || true
  echo "✅ [MinGW] verified ${archive_abs}" >&2
  return 0
}

build_common_mingw::sanitize_mingw_archives_in_tree() {
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

  local overall_status=0
  local found=0

  echo "🔍 [MinGW] scanning ${root_dir} for static archives" >&2

  while IFS= read -r -d '' archive_path; do
    found=1
    local archive_abs="$archive_path"
    local stamp_path="${archive_abs}.mingw_refptr_sanitized"

    if [[ -f "$stamp_path" && "$stamp_path" -nt "$archive_abs" ]]; then
      echo "ℹ️  [MinGW] ${archive_abs} already sanitized (stamp up to date)" >&2
      continue
    fi

    BUILD_COMMON_MINGW_SANITIZED_STATUS=()

    if ! build_common_mingw::mitigate_mingw_refptr_comdats "$archive_abs" "$preferred_triple"; then
      overall_status=1
      continue
    fi

    local sanitized_state="${BUILD_COMMON_MINGW_SANITIZED_STATUS[$archive_abs]:-}"
    if [[ "$sanitized_state" == "rewritten" ]]; then
      if ! build_common_mingw::verify_mingw_refptr_sections_rewritten "$archive_abs" "$preferred_triple"; then
        overall_status=1
      fi
    else
      touch "$stamp_path" 2>/dev/null || true
    fi
  done < <(find "$root_dir" -type f -name '*.a' -print0 2>/dev/null)

  if (( ! found )); then
    echo "ℹ️  [MinGW] no archives found under ${root_dir}" >&2
  fi

  return $overall_status
}

build_common_mingw::assert_mingw_archives_sanitized() {
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

  local archives_found=0
  while IFS= read -r -d '' archive_path; do
    archives_found=1
    local archive_abs="$archive_path"
    local stamp_path="${archive_abs}.mingw_refptr_sanitized"
    if [[ -f "$stamp_path" && "$stamp_path" -nt "$archive_abs" ]]; then
      continue
    fi
    if ! build_common_mingw::verify_mingw_refptr_sections_rewritten "$archive_abs" "$preferred_triple"; then
      return 1
    fi
  done < <(find "$root_dir" -type f -name '*.a' -print0 2>/dev/null)

  if (( ! archives_found )); then
    echo "❌ No static libraries were discovered under ${root_dir}" >&2
    return 1
  fi

  return 0
}
