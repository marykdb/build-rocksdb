#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: $0 PACKAGED_ARCHIVE.zip" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$archive" ]] || { echo "Missing package: $archive" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/package" "$work/databases"
(cd "$work/package" && cmake -E tar xf "$archive")
include_dir="$work/package/include/rocksdb"
[[ -f "$include_dir/rocksdb/c.h" ]] || { echo "Missing packaged C header" >&2; exit 1; }
libraries=()
for library in rocksdb bz2 lz4 z zstd snappy; do
  path="$work/package/lib/lib${library}.a"
  [[ -f "$path" ]] || { echo "Missing packaged archive: $path" >&2; exit 1; }
  libraries+=("$path")
done
cc="${CC:-cc}"
cxx="${CXX:-c++}"
binary="$work/codec-smoke"
case "$(uname -s)" in
  Linux)
    link_args=(-Wl,--start-group "${libraries[@]}" -Wl,--end-group -lstdc++ -pthread -ldl -lrt -lm)
    ;;
  MINGW*|MSYS*|CYGWIN*)
    binary+=".exe"
    # Keep the validation executable independent of runner DLL search order.
    # In particular, Git Bash can otherwise load a different libstdc++ or
    # winpthread runtime before the WinLibs toolchain's DLLs.
    link_args=(-static -Wl,--start-group "${libraries[@]}" -Wl,--end-group -lstdc++ -pthread -lshlwapi -lrpcrt4)
    ;;
  Darwin)
    link_args=("${libraries[@]}" -pthread)
    ;;
  *) echo "Unsupported native smoke-test host: $(uname -s)" >&2; exit 1 ;;
esac
"$cc" -std=c99 -Wall -Wextra -Werror -I "$include_dir" -c "$script_dir/verify-packaged-codecs.c" -o "$work/codec-smoke.o"
"$cxx" "$work/codec-smoke.o" "${link_args[@]}" -o "$binary"

# Inspect the executable as well as the static package: a successful link
# must not silently add a dependency on a runner-provided compiler runtime.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    imports="$("${OBJDUMP:-objdump}" -p "$binary")"
    if printf '%s\n' "$imports" | grep -Ei 'DLL Name:.*(libstdc\+\+|libgcc|libwinpthread)' ; then
      echo "Smoke executable unexpectedly imports a compiler runtime DLL" >&2
      exit 1
    fi
    # Use native paths for native Python; MSYS timeout may obscure loader
    # failures with exit 127 before any test output is produced.
    binary="$(cygpath -w "$binary")"
    database_dir="$(cygpath -w "$work/databases")"
    python3 - "$binary" "$database_dir" <<'PYTHON'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=60)
PYTHON
    exit 0
    ;;
esac

# Bound engine execution. Python is available on the macOS runners.
if command -v timeout >/dev/null 2>&1 && [[ "$(timeout --version 2>/dev/null || true)" == *"GNU coreutils"* ]]; then
  timeout 60 "$binary" "$work/databases"
else
  python3 - "$binary" "$work/databases" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=60)
PY
fi
