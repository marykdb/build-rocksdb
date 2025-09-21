#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

DEFAULT_KONAN_VERSION="2.2.20"
KONAN_VERSION="${KONAN_VERSION:-$DEFAULT_KONAN_VERSION}"

usage() {
  cat <<'USAGE'
Usage: ./build.sh [OPTIONS] [CONFIG ...]

Builds RocksDB artifacts using the repository's shell scripts.
When no CONFIG values are provided, all configurations for the current host are built.

Options:
  --konan-version <version>  Override the Kotlin/Native version used to prepare toolchains.
  --list                     List available build configurations and exit.
  -h, --help                 Show this help message and exit.

Configs:
  linuxX64, linuxArm64, mingwX64, mingwArm64,
  macosX64, macosArm64, iosArm64, iosSimulatorArm64,
  watchosArm64, watchosDeviceArm64, watchosSimulatorArm64,
  tvosArm64, tvosSimulatorArm64,  androidNativeArm32, androidNativeArm64,
  androidNativeX86, androidNativeX64
USAGE
}

fail() {
  printf '%b\n' "$*" >&2
  exit 1
}

resolve_host() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux*) echo "LINUX" ;;
    Darwin*) echo "MAC" ;;
    MINGW*|MSYS*|CYGWIN*) echo "WINDOWS" ;;
    *) fail "Unsupported host platform: $uname_s" ;;
  esac
}

HOST_PLATFORM="$(resolve_host)"
HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"

declare -a CONFIG_IDS=()
declare -a CONFIG_KEYS=()
declare -a CONFIG_VALUES=()

register_config() {
  local id="$1"
  shift
  CONFIG_IDS+=("$id")
  while [[ $# -gt 0 ]]; do
    local field="$1"
    local value="$2"
    CONFIG_KEYS+=("$id:$field")
    CONFIG_VALUES+=("$value")
    shift 2
  done
}

register_config \
  linuxX64 \
  host LINUX \
  konan_target linux_x64 \
  output_dir linux_x86_64 \
  build_script buildRocksdbLinux.sh \
  build_args "--arch=x86-64" \
  artifact "rocksdb-linux-x86_64.zip" \
  extra_cflags "-march=x86-64" \
  requires_konan_mode never

register_config \
  linuxArm64 \
  host LINUX \
  konan_target linux_arm64 \
  output_dir linux_arm64 \
  build_script buildRocksdbLinux.sh \
  build_args "--arch=arm64" \
  artifact "rocksdb-linux-arm64.zip" \
  extra_cflags "-march=armv8-a" \
  requires_konan_mode auto \
  auto_requires_host_arch arm

register_config \
  mingwX64 \
  host LINUX \
  konan_target mingw_x64 \
  output_dir mingw_x86_64 \
  build_script buildRocksdbMinGW.sh \
  build_args "--arch=x86_64" \
  artifact "rocksdb-mingw-x86_64.zip" \
  cmake_flags "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64" \
  requires_konan_mode always

register_config \
  mingwArm64 \
  host LINUX \
  konan_target "" \
  output_dir mingw_arm64 \
  build_script buildRocksdbMinGW.sh \
  build_args "--arch=arm64" \
  artifact "rocksdb-mingw-arm64.zip" \
  cmake_flags "-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64" \
  requires_konan_mode never

register_config \
  macosX64 \
  host MAC \
  konan_target macos_x64 \
  output_dir macos_x86_64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=macos --arch=x86_64" \
  artifact "rocksdb-macos-x86_64.zip" \
  apple_arch x86_64 \
  apple_target "x86_64-apple-macos11.0" \
  cmake_flags "-DPLATFORM=OS64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" \
  requires_konan_mode always

register_config \
  macosArm64 \
  host MAC \
  konan_target macos_arm64 \
  output_dir macos_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=macos --arch=arm64" \
  artifact "rocksdb-macos-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-macos11.0" \
  cmake_flags "-DPLATFORM=MAC -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" \
  requires_konan_mode always

register_config \
  iosArm64 \
  host MAC \
  konan_target ios_arm64 \
  output_dir ios_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=ios --arch=arm64" \
  artifact "rocksdb-ios-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-ios13.0" \
  apple_sdk iphoneos \
  cmake_flags "-DPLATFORM=OS64" \
  requires_konan_mode always

register_config \
  iosSimulatorArm64 \
  host MAC \
  konan_target ios_simulator_arm64 \
  output_dir ios_simulator_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=ios --simulator --arch=arm64" \
  artifact "rocksdb-ios-simulator-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-ios13.0-simulator" \
  apple_sdk iphonesimulator \
  cmake_flags "-DPLATFORM=SIMULATORARM64" \
  requires_konan_mode always

register_config \
  watchosArm64 \
  host MAC \
  konan_target watchos_arm64 \
  output_dir watchos_arm64_32 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=watchos --arch=arm64_32" \
  artifact "rocksdb-watchos-arm64.zip" \
  apple_arch arm64_32 \
  apple_target "arm64_32-apple-watchos7.0" \
  apple_sdk watchos \
  cmake_flags "-DPLATFORM=WATCHOS -DARCHS=arm64_32 -DDEPLOYMENT_TARGET=7.0" \
  requires_konan_mode always

register_config \
  watchosDeviceArm64 \
  host MAC \
  konan_target watchos_device_arm64 \
  output_dir watchos_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=watchos --arch=arm64" \
  artifact "rocksdb-watchos-device-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-watchos7.0" \
  apple_sdk watchos \
  cmake_flags "-DPLATFORM=WATCHOS -DARCHS=arm64 -DDEPLOYMENT_TARGET=7.0" \
  requires_konan_mode always

register_config \
  watchosSimulatorArm64 \
  host MAC \
  konan_target watchos_simulator_arm64 \
  output_dir watchos_simulator_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=watchos --simulator --arch=arm64" \
  artifact "rocksdb-watchos-simulator-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-watchos7.0-simulator" \
  apple_sdk watchsimulator \
  cmake_flags "-DPLATFORM=SIMULATORARM64_WATCHOS -DARCHS=arm64 -DDEPLOYMENT_TARGET=7.0" \
  requires_konan_mode always

register_config \
  tvosArm64 \
  host MAC \
  konan_target tvos_arm64 \
  output_dir tvos_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=tvos --arch=arm64" \
  artifact "rocksdb-tvos-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-tvos13.0" \
  apple_sdk appletvos \
  cmake_flags "-DPLATFORM=TVOS -DARCHS=arm64 -DDEPLOYMENT_TARGET=13.0" \
  requires_konan_mode always

register_config \
  tvosSimulatorArm64 \
  host MAC \
  konan_target tvos_simulator_arm64 \
  output_dir tvos_simulator_arm64 \
  build_script buildRocksdbApple.sh \
  build_args "--platform=tvos --simulator --arch=arm64" \
  artifact "rocksdb-tvos-simulator-arm64.zip" \
  apple_arch arm64 \
  apple_target "arm64-apple-tvos13.0-simulator" \
  apple_sdk appletvsimulator \
  cmake_flags "-DPLATFORM=SIMULATORARM64_TVOS -DARCHS=arm64 -DDEPLOYMENT_TARGET=13.0" \
  requires_konan_mode always

register_config \
  androidNativeArm32 \
  host "LINUX|MAC" \
  konan_target android_arm32 \
  output_dir android_arm32 \
  build_script buildRocksdbAndroid.sh \
  build_args "--arch=arm32" \
  artifact "rocksdb-android-arm32.zip" \
  requires_konan_mode always

register_config \
  androidNativeArm64 \
  host "LINUX|MAC" \
  konan_target android_arm64 \
  output_dir android_arm64 \
  build_script buildRocksdbAndroid.sh \
  build_args "--arch=arm64" \
  artifact "rocksdb-android-arm64.zip" \
  requires_konan_mode always

register_config \
  androidNativeX86 \
  host "LINUX|MAC" \
  konan_target android_x86 \
  output_dir android_x86 \
  build_script buildRocksdbAndroid.sh \
  build_args "--arch=x86" \
  artifact "rocksdb-android-x86.zip" \
  requires_konan_mode always

register_config \
  androidNativeX64 \
  host "LINUX|MAC" \
  konan_target android_x64 \
  output_dir android_x64 \
  build_script buildRocksdbAndroid.sh \
  build_args "--arch=x64" \
  artifact "rocksdb-android-x64.zip" \
  requires_konan_mode always

default_configs_for_host() {
  case "$1" in
    LINUX) echo "linuxX64 linuxArm64 mingwX64 mingwArm64" ;;
    MAC) echo "macosX64 macosArm64 iosArm64 iosSimulatorArm64 watchosArm64 watchosDeviceArm64 watchosSimulatorArm64 tvosArm64 tvosSimulatorArm64" ;;
    *) echo "" ;;
  esac
}

config_exists() {
  local config="$1"
  [[ -n "$(config_field "$config" host)" ]]
}

config_field() {
  local search_key="$1:$2"
  local idx
  for idx in "${!CONFIG_KEYS[@]}"; do
    if [[ "${CONFIG_KEYS[$idx]}" == "$search_key" ]]; then
      echo "${CONFIG_VALUES[$idx]}"
      return
    fi
  done
  echo ""
}

config_hosts_field() {
  config_field "$1" host
}

config_supports_host() {
  local config="$1"
  local host="$2"
  local field
  field="$(config_hosts_field "$config")"
  if [[ -z "$field" ]]; then
    echo "false"
    return
  fi
  if [[ "$field" == "ANY" ]]; then
    echo "true"
    return
  fi
  IFS='|' read -r -a allowed <<< "$field"
  for value in "${allowed[@]}"; do
    if [[ "$value" == "$host" ]]; then
      echo "true"
      return
    fi
  done
  echo "false"
}

list_configs() {
  echo "Available configurations:"
  for config in "${CONFIG_IDS[@]}"; do
    printf "  %-18s (host: %s)\n" "$config" "$(config_field "$config" host)"
  done
}

is_host_arm_arch() {
  [[ "$HOST_ARCH" == *"arm"* || "$HOST_ARCH" == *"aarch64"* ]]
}

ensure_valid_config() {
  local config="$1"
  if ! config_exists "$config"; then
    fail "Unknown configuration: $config"
  fi
}

config_host() {
  config_field "$1" host
}

config_konan_target() {
  config_field "$1" konan_target
}

config_output_directory() {
  config_field "$1" output_dir
}

config_build_script() {
  config_field "$1" build_script
}

config_build_args() {
  config_field "$1" build_args
}

resolve_sdk_path() {
  local sdk="$1"
  if [[ "$HOST_PLATFORM" != "MAC" ]]; then
    echo ""
    return
  fi
  case "$sdk" in
    iphoneos) xcrun --sdk iphoneos --show-sdk-path ;;
    iphonesimulator) xcrun --sdk iphonesimulator --show-sdk-path ;;
    watchos) xcrun --sdk watchos --show-sdk-path ;;
    watchsimulator) xcrun --sdk watchsimulator --show-sdk-path ;;
    appletvos) xcrun --sdk appletvos --show-sdk-path ;;
    appletvsimulator) xcrun --sdk appletvsimulator --show-sdk-path ;;
    "") echo "" ;;
    *) fail "Unknown SDK: $sdk" ;;
  esac
}

config_extra_cflags() {
  local config="$1"
  local cflags
  cflags="$(config_field "$config" extra_cflags)"
  if [[ -n "$cflags" ]]; then
    echo "$cflags"
    return
  fi

  local apple_arch apple_target apple_sdk
  apple_arch="$(config_field "$config" apple_arch)"
  apple_target="$(config_field "$config" apple_target)"
  apple_sdk="$(config_field "$config" apple_sdk)"

  if [[ -n "$apple_arch" && -n "$apple_target" ]]; then
    local flags="-arch $apple_arch -target $apple_target"
    if [[ -n "$apple_sdk" ]]; then
      local sdk_path
      sdk_path="$(resolve_sdk_path "$apple_sdk")"
      flags+=" -isysroot $sdk_path"
    fi
    echo "$flags"
    return
  fi

  echo ""
}

config_extra_cmakeflags() {
  config_field "$1" cmake_flags
}

config_artifact_name() {
  config_field "$1" artifact
}

requires_konan() {
  local config="$1"
  local mode
  mode="$(config_field "$config" requires_konan_mode)"
  case "${mode:-always}" in
    never)
      echo "false"
      ;;
    always)
      echo "true"
      ;;
    auto)
      if [[ "$(config_supports_host "$config" "$HOST_PLATFORM")" != "true" ]]; then
        echo "true"
        return
      fi
      local required_arch
      required_arch="$(config_field "$config" auto_requires_host_arch)"
      case "$required_arch" in
        arm)
          if is_host_arm_arch; then
            echo "false"
          else
            echo "true"
          fi
          ;;
        "")
          echo "false"
          ;;
        *)
          echo "true"
          ;;
      esac
      ;;
    *)
      echo "true"
      ;;
  esac
}

prepare_konan() {
  local config="$1"
  local target
  target="$(config_konan_target "$config")"
  if [[ -z "$target" ]]; then
    return
  fi
  if [[ "$(requires_konan "$config")" == "true" ]]; then
    bash "$PROJECT_ROOT/scripts/install-konan.sh" "--target=${target}" "--konan-version=${KONAN_VERSION}"
  fi
}

prepare_headers() {
  local include_src="$PROJECT_ROOT/rocksdb/include"
  local include_dest="$PROJECT_ROOT/build/include/rocksdb"
  if [[ ! -d "$include_src" ]]; then
    fail "Missing rocksdb/include directory. Ensure the RocksDB submodule is initialized.\nTry running: git submodule update --init --recursive"
  fi
  rm -rf "$include_dest"
  mkdir -p "$include_dest"
  cp -R "$include_src/." "$include_dest"
}

build_dependencies() {
  local config="$1"
  local output_dir
  output_dir="$(config_output_directory "$config")"
  local extra_cflags extra_cmakeflags
  extra_cflags="$(config_extra_cflags "$config")"
  extra_cmakeflags="$(config_extra_cmakeflags "$config")"

  local -a args=(
    bash "$PROJECT_ROOT/buildDependencies.sh"
    --output-dir "$PROJECT_ROOT/build/lib/${output_dir}"
  )

  if [[ -n "$extra_cflags" ]]; then
    args+=("--extra-cflags" "$extra_cflags")
  fi
  if [[ -n "$extra_cmakeflags" ]]; then
    args+=("--extra-cmakeflags" "$extra_cmakeflags")
  fi

  "${args[@]}"
}

run_build_script() {
  local config="$1"
  local script
  script="$(config_build_script "$config")"
  if [[ -z "$script" ]]; then
    fail "No build script defined for $config"
  fi
  local args_string
  args_string="$(config_build_args "$config")"
  local -a script_args=()
  if [[ -n "$args_string" ]]; then
    # shellcheck disable=SC2206
    script_args=($args_string)
  fi
  bash "$PROJECT_ROOT/${script}" "${script_args[@]}"
}

package_artifacts() {
  local config="$1"
  local output_dir
  output_dir="$(config_output_directory "$config")"
  local artifact
  artifact="$(config_artifact_name "$config")"
  local include_base="$PROJECT_ROOT/build/include"
  local lib_base="$PROJECT_ROOT/build/lib/${output_dir}"

  [[ -d "$include_base" ]] || fail "Expected include directory $include_base not found"
  [[ -d "$lib_base" ]] || fail "Expected library directory $lib_base not found"

  if [[ ! -f "$lib_base/librocksdb.a" && ! -f "$lib_base/rocksdb-build/librocksdb.a" ]]; then
    fail "RocksDB static library not found in $lib_base"
  fi

  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  mkdir -p "$staging/include" "$staging/lib"

  while IFS= read -r -d '' header; do
    local rel dest
    rel="${header#${include_base}/}"
    dest="$staging/include/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp "$header" "$dest"
  done < <(find "$include_base" -type f \( -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' -o -name '*.inc' -o -name '*.ipp' \) -print0)

  while IFS= read -r -d '' libfile; do
    local rel dest
    rel="${libfile#${lib_base}/}"
    dest="$staging/lib/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp "$libfile" "$dest"
  done < <(find "$lib_base" -maxdepth 1 -type f -name '*.a' -print0)

  mkdir -p "$PROJECT_ROOT/build/archives"
  local archive_path="$PROJECT_ROOT/build/archives/${artifact}"
  rm -f "$archive_path"
  (cd "$staging" && zip -qr "$archive_path" include lib)
  trap - RETURN
  rm -rf "$staging"
}

build_config() {
  local config="$1"
  echo "=============================="
  echo "Building configuration: $config"
  echo "=============================="

  if [[ "$(config_supports_host "$config" "$HOST_PLATFORM")" != "true" ]]; then
    fail "Skipping $config because it requires host $(config_host "$config")"
  fi

  prepare_konan "$config"
  build_dependencies "$config"
  run_build_script "$config"
  package_artifacts "$config"
  echo "✅ Completed $config"
}

main() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --konan-version)
        [[ $# -ge 2 ]] || fail "--konan-version requires a value"
        KONAN_VERSION="$2"
        shift 2
        ;;
      --konan-version=*)
        KONAN_VERSION="${1#*=}"
        shift
        ;;
      --list)
        list_configs
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        usage >&2
        fail "Unknown option: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -eq 0 ]]; then
    local defaults
    defaults="$(default_configs_for_host "$HOST_PLATFORM")"
    if [[ -z "$defaults" ]]; then
      fail "No builds are defined for $HOST_PLATFORM hosts"
    fi
    read -r -a positional <<< "$defaults"
  fi

  for config in "${positional[@]}"; do
    ensure_valid_config "$config"
  done

  prepare_headers

  for config in "${positional[@]}"; do
    build_config "$config"
  done
}

main "$@"
