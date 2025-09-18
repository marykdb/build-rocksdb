#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --target=<konan-target> [--konan-version=<version>]

Ensures that the Kotlin/Native toolchain for the provided target is installed
under $HOME/.konan and that the cross-compilation toolchain is downloaded.
USAGE
}

TARGET=""
KONAN_VERSION="${KONAN_VERSION:-2.2.20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target=*)
      TARGET="${1#*=}"
      ;;
    --konan-version=*)
      KONAN_VERSION="${1#*=}"
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
  shift
done

if [[ -z "$TARGET" ]]; then
  echo "Missing required --target argument" >&2
  usage >&2
  exit 1
fi

uname_s=$(uname -s)
uname_m=$(uname -m)

case "$uname_s" in
  Linux*) host_os="linux" ;;
  Darwin*) host_os="macos" ;;
  MINGW*|MSYS*|CYGWIN*) host_os="windows" ;;
  *)
    echo "Unsupported host OS: $uname_s" >&2
    exit 1
    ;;
esac

case "$uname_m" in
  x86_64|amd64) host_arch="x86_64" ;;
  arm64|aarch64)
    if [[ "$host_os" == "macos" ]]; then
      host_arch="aarch64"
    else
      host_arch="arm64"
    fi
    ;;
  *)
    echo "Unsupported host architecture: $uname_m" >&2
    exit 1
    ;;
esac

if [[ "$host_os" == "linux" && "$host_arch" != "x86_64" ]]; then
  echo "The build scripts currently expect an x86_64 Linux host" >&2
  exit 1
fi

host_id="$host_os-$host_arch"
archive_name="kotlin-native-prebuilt-${host_id}-${KONAN_VERSION}.tar.gz"
download_url="https://github.com/JetBrains/kotlin/releases/download/v${KONAN_VERSION}/${archive_name}"

konan_dir="${HOME}/.konan"
download_dir="${konan_dir}/downloads"
distribution_dir="${konan_dir}/${archive_name%.tar.gz}"

mkdir -p "$download_dir"

archive_path="${download_dir}/${archive_name}"
if [[ ! -f "$archive_path" ]]; then
  echo "Downloading Kotlin/Native ${KONAN_VERSION} for ${host_id}..."
  curl -sSL "$download_url" -o "$archive_path"
else
  echo "Using cached Kotlin/Native archive at ${archive_path}"
fi

if [[ ! -d "$distribution_dir" ]]; then
  echo "Extracting Kotlin/Native distribution into ${konan_dir}"
  tar -xzf "$archive_path" -C "$konan_dir"
else
  echo "Kotlin/Native distribution already extracted at ${distribution_dir}"
fi

konanc_binary="${distribution_dir}/bin/konanc"
if [[ ! -x "$konanc_binary" ]]; then
  echo "konanc executable not found at ${konanc_binary}" >&2
  exit 1
fi

export KONAN_DATA_DIR="${konan_dir}"

should_prepare=true
case "$TARGET" in
  linux_x64)
    pattern="x86_64-unknown-linux-gnu-*"
    ;;
  linux_arm64)
    pattern="aarch64-unknown-linux-gnu-*"
    ;;
  mingw_x64)
    pattern="mingw-w64-x86_64-*"
    ;;
  *)
    pattern=""
    ;;
esac

if [[ -n "$pattern" && -d "${KONAN_DATA_DIR}/dependencies" ]]; then
  if compgen -G "${KONAN_DATA_DIR}/dependencies/${pattern}" > /dev/null; then
    echo "Konan dependencies for ${TARGET} already present"
    should_prepare=false
  fi
fi

if [[ "$should_prepare" == true ]]; then
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT
  cat >"${tmp_dir}/stub.kt" <<'KT'
fun answer() = 42
KT
  echo "Preparing Kotlin/Native toolchain for ${TARGET}"
  if ! "${konanc_binary}" "${tmp_dir}/stub.kt" -p library -target "${TARGET}" -o "${tmp_dir}/${TARGET}.klib" >/dev/null 2>&1; then
    "${konanc_binary}" "${tmp_dir}/stub.kt" -p library -target "${TARGET}" -o "${tmp_dir}/${TARGET}.klib"
  fi
  rm -rf "$tmp_dir"
fi

echo "Kotlin/Native toolchain ready for ${TARGET}"
