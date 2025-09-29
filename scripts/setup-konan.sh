#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_VERSION="2.2.20"
KONAN_VERSION="$DEFAULT_VERSION"
declare -a REQUESTED_TARGETS=()
OUTPUT_FILE=""
GITHUB_ENV_FILE=""
GITHUB_PATH_FILE=""
PRINT_SHELL_EXPORTS=1

usage() {
  cat <<'USAGE'
Usage: setup-konan.sh [OPTIONS]

Ensures a Kotlin/Native toolchain is downloaded locally and outputs environment
variables for the requested targets.

Options:
  --version <ver>        Kotlin/Native version to install (default: 2.2.20)
  --target <id>          Target to prepare (may be repeated).
                         Supported targets: mingw_x64
  --output <file>        Write shell export statements to FILE instead of stdout.
                         Use '-' to write to standard output.
  --github-env <file>    Append KEY=VALUE lines suitable for GitHub Actions to FILE.
  --github-path <file>   Append PATH entries to FILE for GitHub Actions PATH updates.
  --no-print-shell       Suppress printing shell exports to stdout.
  -h, --help             Show this help message.
USAGE
}

add_unique_path() {
  local array_name="$1"
  local new_path="$2"
  # shellcheck disable=SC1083
  eval "local -a current=(\"\${${array_name}[@]:-}\")"
  local existing
  for existing in "${current[@]}"; do
    if [[ "$existing" == "$new_path" ]]; then
      return
    fi
  done
  # shellcheck disable=SC1083
  eval "${array_name}+=(\"\$new_path\")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --version" >&2
        exit 1
      fi
      KONAN_VERSION="$2"
      shift 2
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --target" >&2
        exit 1
      fi
      REQUESTED_TARGETS+=("$2")
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --output" >&2
        exit 1
      fi
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --github-env)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --github-env" >&2
        exit 1
      fi
      GITHUB_ENV_FILE="$2"
      PRINT_SHELL_EXPORTS=0
      shift 2
      ;;
    --github-path)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --github-path" >&2
        exit 1
      fi
      GITHUB_PATH_FILE="$2"
      PRINT_SHELL_EXPORTS=0
      shift 2
      ;;
    --no-print-shell)
      PRINT_SHELL_EXPORTS=0
      shift
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

if [[ ${#REQUESTED_TARGETS[@]} -eq 0 ]]; then
  echo "At least one --target must be provided" >&2
  usage >&2
  exit 1
fi

uname_s="$(uname -s)"
uname_m="$(uname -m | tr '[:upper:]' '[:lower:]')"
host_id=""
archive_ext=""
case "$uname_s" in
  Linux*)
    host_id="linux-x86_64"
    archive_ext="tar.gz"
    ;;
  Darwin*)
    case "$uname_m" in
      arm64|aarch64)
        host_id="macos-aarch64"
        ;;
      x86_64)
        host_id="macos-x86_64"
        ;;
      *)
        echo "Unsupported macOS architecture: $uname_m" >&2
        exit 1
        ;;
    esac
    archive_ext="tar.gz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    host_id="windows-x86_64"
    archive_ext="zip"
    ;;
  *)
    echo "Unsupported host platform: $uname_s" >&2
    exit 1
    ;;
 esac

install_root="${PROJECT_ROOT}/build/tools/konan/${KONAN_VERSION}/${host_id}"
mkdir -p "$install_root"
asset_basename="kotlin-native-prebuilt-${host_id}-${KONAN_VERSION}"
archive_name="${asset_basename}.${archive_ext}"
archive_path="${install_root}/${archive_name}"

if [[ ! -d "${install_root}/${asset_basename}" ]]; then
  if [[ ! -f "$archive_path" ]]; then
    url="https://github.com/JetBrains/kotlin/releases/download/v${KONAN_VERSION}/${archive_name}"
    echo "Downloading Kotlin/Native ${KONAN_VERSION} (${host_id}) from ${url}" >&2
    curl --fail --location --silent --show-error "$url" --output "$archive_path"
  fi
  echo "Extracting ${archive_name}" >&2
  case "$archive_ext" in
    tar.gz)
      python - "$archive_path" "$install_root" <<'PY'
import pathlib, sys, tarfile
archive = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
with tarfile.open(archive, mode="r:gz") as tf:
    tf.extractall(dest)
PY
      ;;
    zip)
      python - "$archive_path" "$install_root" <<'PY'
import pathlib, sys, zipfile
archive = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
PY
      ;;
    *)
      echo "Unsupported archive extension: $archive_ext" >&2
      exit 1
      ;;
  esac
fi

konan_home="${install_root}/${asset_basename}"
if [[ ! -d "$konan_home" ]]; then
  echo "Failed to locate Kotlin/Native home at ${konan_home}" >&2
  exit 1
fi

declare -A env_exports=()
declare -a path_additions=()

env_exports[KONAN_HOME]="$konan_home"
env_exports[KONAN_VERSION]="$KONAN_VERSION"
# Kotlin/Native tools expect KONAN_DATA_DIR by default alongside the distribution.
env_exports[KONAN_DATA_DIR]="${konan_home}/konan"

konan_bin="${konan_home}/bin"
if [[ -d "$konan_bin" ]]; then
  add_unique_path path_additions "$konan_bin"
fi

dependencies_root="${install_root}/dependencies"
mkdir -p "$dependencies_root"

needs_mingw=0
for target in "${REQUESTED_TARGETS[@]}"; do
  case "$target" in
    mingw_x64)
      needs_mingw=1
      ;;
    *)
      echo "Unsupported target: $target" >&2
      exit 1
      ;;
  esac
done

if (( needs_mingw )); then
  dependency_name="msys2-mingw-w64-x86_64-2"
  dependency_archive="${dependency_name}.tar.gz"
  dependency_path="${dependencies_root}/${dependency_archive}"
  dependency_dir="${dependencies_root}/${dependency_name}"
  if [[ ! -d "$dependency_dir" ]]; then
    if [[ ! -f "$dependency_path" ]]; then
      dep_url="https://download.jetbrains.com/kotlin/native/${dependency_archive}"
      echo "Downloading Kotlin/Native dependency ${dependency_name} from ${dep_url}" >&2
      curl --fail --location --silent --show-error "$dep_url" --output "$dependency_path"
    fi
    echo "Extracting ${dependency_archive}" >&2
    python - "$dependency_path" "$dependencies_root" <<'PY'
import pathlib, sys, tarfile
archive = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
with tarfile.open(archive, mode="r:gz") as tf:
    tf.extractall(dest)
PY
  fi
  if [[ ! -d "$dependency_dir" ]]; then
    echo "Failed to extract dependency ${dependency_name}" >&2
    exit 1
  fi
  env_exports[KONAN_MINGW_X64_ROOT]="$dependency_dir"
  env_exports[MINGW_ROOT]="$dependency_dir"
  env_exports[LLVM_MINGW_ROOT]="$dependency_dir"
  add_unique_path path_additions "${dependency_dir}/bin"
fi

current_path="${PATH:-}"
for path_entry in "${path_additions[@]}"; do
  if [[ -d "$path_entry" ]]; then
    case ":${current_path}:" in
      *":${path_entry}:"*) ;;
      *) current_path="${path_entry}:${current_path}" ;;
    esac
  fi
done
env_exports[PATH]="$current_path"

write_shell_exports() {
  local dest="$1"
  local header="# Generated by setup-konan.sh"
  local -a keys=()
  local key
  for key in "${!env_exports[@]}"; do
    keys+=("$key")
  done
  IFS=$'\n' keys=($(sort <<<"${keys[*]}") )
  unset IFS
  if [[ "$dest" == "-" || -z "$dest" ]]; then
    for key in "${keys[@]}"; do
      printf 'export %s=%q\n' "$key" "${env_exports[$key]}"
    done
    return
  fi
  mkdir -p "$(dirname "$dest")"
  {
    echo "$header"
    for key in "${keys[@]}"; do
      printf 'export %s=%q\n' "$key" "${env_exports[$key]}"
    done
  } >"$dest"
}

if (( PRINT_SHELL_EXPORTS )); then
  if [[ -n "$OUTPUT_FILE" ]]; then
    write_shell_exports "$OUTPUT_FILE"
    if [[ "$OUTPUT_FILE" != "-" ]]; then
      # shellcheck disable=SC1090
      :
    fi
  else
    write_shell_exports -
  fi
elif [[ -n "$OUTPUT_FILE" ]]; then
  write_shell_exports "$OUTPUT_FILE"
fi

if [[ -n "$GITHUB_ENV_FILE" ]]; then
  mkdir -p "$(dirname "$GITHUB_ENV_FILE")"
  env_keys=()
  env_key=""
  for env_key in "${!env_exports[@]}"; do
    env_keys+=("$env_key")
  done
  IFS=$'\n' env_keys=($(sort <<<"${env_keys[*]}") )
  unset IFS
  for env_key in "${env_keys[@]}"; do
    if [[ "$env_key" == "PATH" ]]; then
      continue
    fi
    printf '%s=%s\n' "$env_key" "${env_exports[$env_key]}" >> "$GITHUB_ENV_FILE"
  done
  unset env_keys env_key
fi

if [[ -n "$GITHUB_PATH_FILE" ]]; then
  mkdir -p "$(dirname "$GITHUB_PATH_FILE")"
  for path_entry in "${path_additions[@]}"; do
    if [[ -d "$path_entry" ]]; then
      printf '%s\n' "$path_entry" >> "$GITHUB_PATH_FILE"
    fi
  done
fi
