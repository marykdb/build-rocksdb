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
    log "Prefetching mingw_x64 dependencies via konanc"
    if ! cmd.exe /C "\"${WINDOWS_KONAN_HOME}\\bin\\konanc.bat\" -target mingw_x64 -Xcheck-dependencies \"${WINDOWS_STUB_SRC}\" -o \"${WINDOWS_STUB_OUT}\"" >/dev/null 2>&1; then
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

DEPENDENCIES_DIR="$POSIX_KONAN_DATA_DIR/dependencies"
if [[ ! -d "$DEPENDENCIES_DIR" ]]; then
  log "Expected dependencies directory missing at $DEPENDENCIES_DIR" >&2
  log "konanc did not populate Kotlin/Native dependencies" >&2
  exit 1
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
