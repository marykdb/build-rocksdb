#!/usr/bin/env bash

set -euo pipefail

print_usage() {
  cat <<'USAGE' >&2
Usage: setup-konan-llvm-mingw.sh [options]

Downloads the JetBrains-packaged llvm-mingw toolchain that ships with the
Kotlin/Native 2.2.20 release and prints the POSIX path to the extracted
toolchain directory on stdout.

Options:
  --toolchains-dir=PATH   Directory where helper repositories and toolchains should be placed.
  --konan-data-dir=PATH   Directory to use as Kotlin/Native data directory (defaults to <toolchains-dir>/konan-data).
  --konan-version=VER     Kotlin/Native release version to download (defaults to 2.2.20).
  --kotlin-release-url=URL
                          Override the base GitHub release URL (defaults to the
                          official JetBrains release for the selected version).
  -h, --help              Show this help message.
USAGE
}

log() {
  printf '[setup-konan] %s\n' "$*" >&2
}

# Defaults
TOOLCHAINS_DIR=""
KONAN_DATA_DIR_OVERRIDE=""
KONAN_VERSION="2.2.20"
KOTLIN_RELEASE_URL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchains-dir=*)
      TOOLCHAINS_DIR="${1#*=}"
      ;;
    --konan-data-dir=*)
      KONAN_DATA_DIR_OVERRIDE="${1#*=}"
      ;;
    --konan-version=*)
      KONAN_VERSION="${1#*=}"
      ;;
    --kotlin-release-url=*)
      KOTLIN_RELEASE_URL_OVERRIDE="${1#*=}"
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      print_usage
      log "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$TOOLCHAINS_DIR" ]]; then
  POSIX_TOOLCHAINS_DIR="$(pwd)/toolchains"
else
  POSIX_TOOLCHAINS_DIR="$TOOLCHAINS_DIR"
fi

if command -v cygpath >/dev/null 2>&1; then
  POSIX_TOOLCHAINS_DIR="$(cygpath -u "$POSIX_TOOLCHAINS_DIR")"
fi

if [[ -n "$KONAN_DATA_DIR_OVERRIDE" ]]; then
  KONAN_DATA_POSIX="$KONAN_DATA_DIR_OVERRIDE"
  if command -v cygpath >/dev/null 2>&1; then
    KONAN_DATA_POSIX="$(cygpath -u "$KONAN_DATA_DIR_OVERRIDE")"
  fi
else
  KONAN_DATA_POSIX="$POSIX_TOOLCHAINS_DIR/konan-data"
fi

if command -v cygpath >/dev/null 2>&1; then
  KONAN_DATA_ENV="$(cygpath -w "$KONAN_DATA_POSIX")"
else
  KONAN_DATA_ENV="$KONAN_DATA_POSIX"
fi

log "Using toolchains directory: $POSIX_TOOLCHAINS_DIR"
log "Using Kotlin/Native data directory: $KONAN_DATA_ENV"

if ! command -v curl >/dev/null 2>&1; then
  log "curl is required but not available in PATH"
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  log "python is required but not available in PATH"
  exit 1
fi

mkdir -p "$POSIX_TOOLCHAINS_DIR"

# Ensure the Kotlin/Native data directory exists ahead of time so that
# dependency downloads succeed even if the JVM tooling does not create the
# directory structure automatically.
POSIX_KONAN_DATA_DIR_PRESET="$(
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$KONAN_DATA_ENV"
  else
    printf '%s' "$KONAN_DATA_ENV"
  fi
)"
mkdir -p "$POSIX_KONAN_DATA_DIR_PRESET"

KONAN_ARCHIVE="kotlin-native-prebuilt-windows-x86_64-${KONAN_VERSION}.zip"
if [[ -n "$KOTLIN_RELEASE_URL_OVERRIDE" ]]; then
  KONAN_ARCHIVE_URL="$KOTLIN_RELEASE_URL_OVERRIDE"
else
  KONAN_ARCHIVE_URL="https://github.com/JetBrains/kotlin/releases/download/v${KONAN_VERSION}/${KONAN_ARCHIVE}"
fi

KONAN_ARCHIVE_PATH="$POSIX_TOOLCHAINS_DIR/$KONAN_ARCHIVE"
log "Downloading Kotlin/Native ${KONAN_VERSION} from $KONAN_ARCHIVE_URL"
curl -fL --retry 5 --retry-delay 2 -o "$KONAN_ARCHIVE_PATH" "$KONAN_ARCHIVE_URL"

KONAN_HOME_DIR="$POSIX_TOOLCHAINS_DIR/${KONAN_ARCHIVE%.zip}"
if [[ -d "$KONAN_HOME_DIR" ]]; then
  log "Removing existing Kotlin/Native distribution at $KONAN_HOME_DIR"
  rm -rf "$KONAN_HOME_DIR"
fi

log "Extracting $KONAN_ARCHIVE_PATH"
python - "$KONAN_ARCHIVE_PATH" "$POSIX_TOOLCHAINS_DIR" <<'PY'
import pathlib
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
PY

rm -f "$KONAN_ARCHIVE_PATH"

if [[ ! -d "$KONAN_HOME_DIR" ]]; then
  log "Extracted distribution missing at $KONAN_HOME_DIR"
  exit 1
fi

log "Kotlin/Native home: $KONAN_HOME_DIR"

export KONAN_DATA_DIR="$KONAN_DATA_ENV"

UNAME_OUT="$(uname -s 2>/dev/null || echo)"
case "$UNAME_OUT" in
  MINGW*|MSYS*|CYGWIN*)
    STUB_DIR="$(mktemp -d)"
    trap 'rm -rf "$STUB_DIR"' EXIT
    STUB_SRC="$STUB_DIR/__setup__.kt"
    cat <<'EOF' >"$STUB_SRC"
fun main() = println("kotlin-native setup")
EOF
    STUB_OUT="$STUB_DIR/__setup__"
    if command -v cygpath >/dev/null 2>&1; then
      WINDOWS_KONAN_HOME="$(cygpath -w "$KONAN_HOME_DIR")"
      WINDOWS_STUB_SRC="$(cygpath -w "$STUB_SRC")"
      WINDOWS_STUB_OUT="$(cygpath -w "$STUB_OUT")"
    else
      WINDOWS_KONAN_HOME="$KONAN_HOME_DIR"
      WINDOWS_STUB_SRC="$STUB_SRC"
      WINDOWS_STUB_OUT="$STUB_OUT"
    fi
    WINDOWS_KONAN_DATA="$(cygpath -w "$POSIX_KONAN_DATA_DIR_PRESET")"
    PREFETCH_SCRIPT="$STUB_DIR/prefetch.bat"
    if command -v cygpath >/dev/null 2>&1; then
      WINDOWS_PREFETCH_SCRIPT="$(cygpath -w "$PREFETCH_SCRIPT")"
    else
      WINDOWS_PREFETCH_SCRIPT="$PREFETCH_SCRIPT"
    fi
    cat <<EOF >"$PREFETCH_SCRIPT"
@echo on
setlocal
set "KONAN_DATA_DIR=${WINDOWS_KONAN_DATA}"
"${WINDOWS_KONAN_HOME}\\bin\\konanc.bat" -target mingw_x64 -Xkonan-data-dir="${WINDOWS_KONAN_DATA}" -Xcheck-dependencies "${WINDOWS_STUB_SRC}" -o "${WINDOWS_STUB_OUT}"
exit /b %ERRORLEVEL%
EOF
    log "Prefetching mingw_x64 dependencies via konanc"
    if ! cmd.exe /C "\"${WINDOWS_PREFETCH_SCRIPT}\""; then
      log "Warning: konanc failed to prefetch dependencies. Continuing with cached artifacts, if any."
    fi
    rm -rf "$STUB_DIR"
    trap - EXIT
    ;;
  *)
    log "Non-Windows host detected ($UNAME_OUT); skipping konanc dependency prefetch"
    ;;
esac

if command -v cygpath >/dev/null 2>&1; then
  POSIX_KONAN_DATA_DIR="$(cygpath -u "$KONAN_DATA_ENV")"
else
  POSIX_KONAN_DATA_DIR="$KONAN_DATA_ENV"
fi

DEPENDENCIES_HOME="$POSIX_KONAN_DATA_DIR/dependencies"
mkdir -p "$DEPENDENCIES_HOME"

readarray -t KONAN_PROP_VALUES < <(python - "$KONAN_HOME_DIR/konan/konan.properties" <<'PY'
import sys

def parse_props(path):
    result = {}
    with open(path, 'r', encoding='utf-8') as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            key, value = line.split('=', 1)
            result[key.strip()] = value.strip()
    return result

props = parse_props(sys.argv[1])
dependencies_url = props.get('dependenciesUrl', '').rstrip('/')
toolchain_dependency = props.get('toolchainDependency.mingw_x64', '')
print(dependencies_url)
print(toolchain_dependency)
PY
)

DEPENDENCIES_BASE_URL="${KONAN_PROP_VALUES[0]:-}"
TOOLCHAIN_DEPENDENCY_NAME="${KONAN_PROP_VALUES[1]:-}"

if [[ -n "$DEPENDENCIES_BASE_URL" && -n "$TOOLCHAIN_DEPENDENCY_NAME" ]]; then
  TOOLCHAIN_DEPENDENCY_DIR="$DEPENDENCIES_HOME/$TOOLCHAIN_DEPENDENCY_NAME"
  if [[ ! -d "$TOOLCHAIN_DEPENDENCY_DIR" ]]; then
    DEP_ARCHIVE="$TOOLCHAIN_DEPENDENCY_NAME.tar.gz"
    DEP_URL="$DEPENDENCIES_BASE_URL/$DEP_ARCHIVE"
    TMP_DEP_ARCHIVE="$(mktemp)"
    log "Downloading Kotlin/Native dependency $TOOLCHAIN_DEPENDENCY_NAME from $DEP_URL"
    if curl -fL --retry 5 --retry-delay 2 -o "$TMP_DEP_ARCHIVE" "$DEP_URL"; then
      python - "$TMP_DEP_ARCHIVE" "$DEPENDENCIES_HOME" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])

with tarfile.open(archive) as tf:
    tf.extractall(dest)
PY
    else
      log "Warning: unable to download dependency archive from $DEP_URL"
    fi
    rm -f "$TMP_DEP_ARCHIVE"
  fi
fi

declare -a DEPENDENCY_DIR_CANDIDATES
DEPENDENCY_DIR_CANDIDATES+=("$DEPENDENCIES_HOME")

DEFAULT_KONAN_DIR="$HOME/.konan/dependencies"
if [[ -d "$DEFAULT_KONAN_DIR" ]]; then
  DEPENDENCY_DIR_CANDIDATES+=("$DEFAULT_KONAN_DIR")
fi

DEPENDENCIES_DIR=""
for candidate in "${DEPENDENCY_DIR_CANDIDATES[@]}"; do
  if [[ -d "$candidate" ]]; then
    DEPENDENCIES_DIR="$candidate"
    break
  fi
done

if [[ -z "$DEPENDENCIES_DIR" ]]; then
  log "Unable to locate Kotlin/Native dependencies. Checked: ${DEPENDENCY_DIR_CANDIDATES[*]}" >&2
  exit 1
fi

if [[ "$DEPENDENCIES_DIR" != "$POSIX_KONAN_DATA_DIR/dependencies" ]]; then
  log "Using dependencies from alternate location: $DEPENDENCIES_DIR"
fi

shopt -s nullglob
mapfile -t TOOLCHAIN_CANDIDATES < <(find "$DEPENDENCIES_DIR" -maxdepth 1 -type d -name 'msys2-mingw-w64-*' | sort)
shopt -u nullglob

if ((${#TOOLCHAIN_CANDIDATES[@]} == 0)); then
  log "Unable to locate llvm-mingw toolchain inside $DEPENDENCIES_DIR" >&2
  exit 1
fi

LLVM_MINGW_ROOT="${TOOLCHAIN_CANDIDATES[0]}"
log "Found llvm-mingw toolchain at $LLVM_MINGW_ROOT"

printf '%s\n' "$LLVM_MINGW_ROOT"
