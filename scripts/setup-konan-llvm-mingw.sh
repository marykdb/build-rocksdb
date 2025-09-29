#!/usr/bin/env bash

set -euo pipefail

print_usage() {
  cat <<'USAGE' >&2
Usage: setup-konan-llvm-mingw.sh [options]

Downloads the JetBrains-packaged llvm-mingw toolchain that ships with Kotlin/Native
and prints the POSIX path to the extracted toolchain directory on stdout.

Options:
  --toolchains-dir=PATH   Directory where helper repositories and toolchains should be placed.
  --konan-data-dir=PATH   Directory to use as Kotlin/Native data directory (defaults to <toolchains-dir>/konan-data).
  --konan-repo=URL        Kotlin/Native Git repository to clone (defaults to https://github.com/JetBrains/kotlin-native).
  --konan-branch=BRANCH   Branch or tag to checkout (defaults to archive).
  --gradle-task=TASK      Gradle task to execute (defaults to dependencies:mingw_x64Dependencies).
  -h, --help              Show this help message.
USAGE
}

log() {
  printf '[setup-konan] %s\n' "$*" >&2
}

# Defaults
TOOLCHAINS_DIR=""
KONAN_DATA_DIR_OVERRIDE=""
KONAN_REPO_URL="https://github.com/JetBrains/kotlin-native"
KONAN_REPO_BRANCH="archive"
GRADLE_TASK="dependencies:mingw_x64Dependencies"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchains-dir=*)
      TOOLCHAINS_DIR="${1#*=}"
      ;;
    --konan-data-dir=*)
      KONAN_DATA_DIR_OVERRIDE="${1#*=}"
      ;;
    --konan-repo=*)
      KONAN_REPO_URL="${1#*=}"
      ;;
    --konan-branch=*)
      KONAN_REPO_BRANCH="${1#*=}"
      ;;
    --gradle-task=*)
      GRADLE_TASK="${1#*=}"
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

if command -v git >/dev/null 2>&1; then
  :
else
  log "git is required but not found in PATH"
  exit 1
fi

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

mkdir -p "$POSIX_TOOLCHAINS_DIR"
KONAN_REPO_DIR="$POSIX_TOOLCHAINS_DIR/kotlin-native"

if [[ -d "$KONAN_REPO_DIR" ]]; then
  log "Removing existing Kotlin/Native clone at $KONAN_REPO_DIR"
  rm -rf "$KONAN_REPO_DIR"
fi

log "Cloning Kotlin/Native ($KONAN_REPO_BRANCH) from $KONAN_REPO_URL"
git clone --depth 1 --branch "$KONAN_REPO_BRANCH" "$KONAN_REPO_URL" "$KONAN_REPO_DIR" >&2

pushd "$KONAN_REPO_DIR" >/dev/null

export KONAN_DATA_DIR="$KONAN_DATA_ENV"

GRADLEW="./gradlew"
UNAME_OUT="$(uname -s 2>/dev/null || echo)"
case "$UNAME_OUT" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ -x ./gradlew.bat ]]; then
      GRADLEW="./gradlew.bat"
    fi
    ;;
esac

log "Running $GRADLEW --console=plain --no-daemon $GRADLE_TASK"
if ! "$GRADLEW" --console=plain --no-daemon "$GRADLE_TASK" >&2; then
  log "Gradle task $GRADLE_TASK failed"
  exit 1
fi

popd >/dev/null

# Resolve the downloaded llvm-mingw toolchain location.
if command -v cygpath >/dev/null 2>&1; then
  POSIX_KONAN_DATA_DIR="$(cygpath -u "$KONAN_DATA_ENV")"
else
  POSIX_KONAN_DATA_DIR="$KONAN_DATA_ENV"
fi

if [[ ! -d "$POSIX_KONAN_DATA_DIR/dependencies" ]]; then
  log "Expected dependencies directory missing at $POSIX_KONAN_DATA_DIR/dependencies" >&2
  log "Gradle task $GRADLE_TASK may have failed" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t TOOLCHAIN_CANDIDATES < <(find "$POSIX_KONAN_DATA_DIR"/dependencies -maxdepth 1 -type d -name 'msys2-mingw-w64-*clang-llvm*' | sort)
shopt -u nullglob

if ((${#TOOLCHAIN_CANDIDATES[@]} == 0)); then
  log "Unable to locate llvm-mingw toolchain inside $POSIX_KONAN_DATA_DIR/dependencies" >&2
  exit 1
fi

LLVM_MINGW_ROOT="${TOOLCHAIN_CANDIDATES[0]}"
log "Found llvm-mingw toolchain at $LLVM_MINGW_ROOT"

printf '%s\n' "$LLVM_MINGW_ROOT"
