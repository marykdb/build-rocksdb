#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../build-rocksdb-common.sh
source "${REPO_ROOT}/build-rocksdb-common.sh"

if (( $# < 1 )); then
  cat <<'USAGE' >&2
Usage: verify-mingw-refptr.sh <directory> [triple]

Ensures that every static library under <directory> has had its
MinGW .refptr COMDAT sections rewritten. Intended for CI validation.
USAGE
  exit 1
fi

LIB_DIR="$1"
TRIPLE="${2:-${MINGW_TRIPLE:-}}"

if [[ -z "$TRIPLE" ]]; then
  echo "MinGW target triple was not provided. Pass it explicitly as the second argument or via MINGW_TRIPLE." >&2
  exit 1
fi

if [[ -n "$TRIPLE" ]]; then
  if ! build_common::is_mingw_triple "$TRIPLE"; then
    echo "Expected a MinGW target triple, got '${TRIPLE}'" >&2
    exit 1
  fi
fi

build_common::assert_mingw_archives_sanitized "$LIB_DIR" "$TRIPLE"

echo "✅ [MinGW] ${LIB_DIR} is free of legacy .refptr COMDATs"
