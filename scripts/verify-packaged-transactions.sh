#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: $0 PACKAGED_ARCHIVE.zip" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/package" "$work/databases"
(cd "$work/package" && cmake -E tar xf "$archive")
libraries=()
for library in rocksdb bz2 lz4 z zstd snappy; do
  path="$work/package/lib/lib${library}.a"
  [[ -f "$path" ]] || { echo "Missing archive: $path" >&2; exit 1; }
  libraries+=("$path")
done
binary="$work/transaction-recovery"
case "$(uname -s)" in
  Darwin) link_args=("${libraries[@]}" -pthread) ;;
  Linux) link_args=(-Wl,--start-group "${libraries[@]}" -Wl,--end-group -pthread -ldl -lrt -lm) ;;
  MINGW*|MSYS*|CYGWIN*)
    binary+=".exe"
    link_args=(-static -Wl,--start-group "${libraries[@]}" -Wl,--end-group -pthread -lshlwapi -lrpcrt4)
    ;;
  *) echo "Unsupported smoke-test host" >&2; exit 1 ;;
esac
"${CXX:-c++}" -std=c++20 -I "$work/package/include/rocksdb" \
  "$script_dir/verify-packaged-transactions.cc" "${link_args[@]}" -o "$binary"
database_root="$work/databases"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    binary="$(cygpath -w "$binary")"
    database_root="$(cygpath -w "$database_root")"
    ;;
esac
# Each preparation process exits without destructors to exercise real WAL recovery.
# macOS additionally checks that resolution and DB close release the recovered object.
python3 - "$binary" "$database_root" <<'PY'
import pathlib
import subprocess
import sys
binary, root = sys.argv[1:]
check_leaks = sys.platform == 'darwin'
for policy in range(3):
    for mode in ('recover', 'recover-delete', 'recover-rollback', 'pending'):
        path = str(pathlib.Path(root) / f'{policy}-{mode}')
        subprocess.run([binary, 'prepare', path, str(policy)], check=True, timeout=60)
        command = [binary, mode, path, str(policy)]
        if check_leaks:
            command = ['leaks', '--atExit', '--', *command]
        subprocess.run(command, check=True, timeout=60)
print('Passed 12 recovery cases' + (' with macOS leak checks.' if check_leaks else ' (leak checker not run).'))
PY
