#!/usr/bin/env bash

# Helper utilities for locating and configuring an Android NDK toolchain.
# The file is intended to be sourced by other scripts in this repository.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "android-ndk.sh is meant to be sourced, not executed directly" >&2
  exit 1
fi

_android_ndk_log() {
  printf '%s\n' "$*" >&2
}

_android_latest_directory() {
  local base="$1"
  local pattern="${2:-*}"
  if [[ ! -d "$base" ]]; then
    echo ""
    return 0
  fi

  local latest=""
  local entry
  while IFS= read -r entry; do
    latest="$entry"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -print 2>/dev/null | sort)

  echo "$latest"
}

_android_find_ndk_root() {
  local candidate

  if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "${ANDROID_NDK_ROOT}" ]]; then
    printf '%s\n' "${ANDROID_NDK_ROOT}"
    return 0
  fi
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "${ANDROID_NDK_HOME}" ]]; then
    printf '%s\n' "${ANDROID_NDK_HOME}"
    return 0
  fi

  local -a sdk_roots=()
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    sdk_roots+=("${ANDROID_HOME}")
  fi
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    sdk_roots+=("${ANDROID_SDK_ROOT}")
  fi
  sdk_roots+=("${HOME}/Android/Sdk")

  local root
  for root in "${sdk_roots[@]}"; do
    if [[ -d "${root}/ndk-bundle" ]]; then
      printf '%s\n' "${root}/ndk-bundle"
      return 0
    fi
    candidate=$(_android_latest_directory "${root}/ndk")
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done


  return 1
}

_android_download_ndk() {
  local version="${ANDROID_NDK_VERSION:-r26d}"
  local uname_s
  uname_s="$(uname -s)"
  local host_tag
  case "$uname_s" in
    Linux*) host_tag="linux" ;;
    Darwin*) host_tag="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) host_tag="windows" ;;
    *)
      _android_ndk_log "Automatic Android NDK download is not supported on host platform: ${uname_s}"
      return 1
      ;;
  esac

  local base_dir="${ANDROID_NDK_CACHE_DIR:-$HOME/.android/ndk}"
  local archive_name="android-ndk-${version}-${host_tag}.zip"
  local archive_path="${base_dir}/${archive_name}"
  local ndk_dir="${base_dir}/android-ndk-${version}"

  if [[ -d "$ndk_dir" ]]; then
    printf '%s\n' "$ndk_dir"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    _android_ndk_log "curl is required to download the Android NDK automatically"
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    _android_ndk_log "unzip is required to extract the Android NDK archive"
    return 1
  fi

  mkdir -p "$base_dir"

  if [[ ! -f "$archive_path" ]]; then
    local download_url="https://dl.google.com/android/repository/${archive_name}"
    _android_ndk_log "Downloading Android NDK ${version} for ${host_tag}..."
    if ! curl -fsSL "$download_url" -o "$archive_path"; then
      _android_ndk_log "Failed to download Android NDK from ${download_url}"
      rm -f "$archive_path"
      return 1
    fi
  else
    _android_ndk_log "Using cached Android NDK archive at ${archive_path}"
  fi

  _android_ndk_log "Extracting Android NDK archive..."
  if ! unzip -q "$archive_path" -d "$base_dir"; then
    _android_ndk_log "Failed to extract Android NDK archive ${archive_path}"
    return 1
  fi

  if [[ ! -d "$ndk_dir" ]]; then
    local extracted
    extracted=$(_android_latest_directory "$base_dir" "android-ndk-*")
    if [[ -n "$extracted" ]]; then
      ndk_dir="$extracted"
    fi
  fi

  if [[ ! -d "$ndk_dir" ]]; then
    _android_ndk_log "Unable to locate Android NDK directory after extraction"
    return 1
  fi

  printf '%s\n' "$ndk_dir"
  return 0
}

android_resolve_ndk_root() {
  local ndk_root
  if ndk_root=$(_android_find_ndk_root); then
    printf '%s\n' "$ndk_root"
    return 0
  fi

  if ndk_root=$(_android_download_ndk); then
    printf '%s\n' "$ndk_root"
    return 0
  fi

  return 1
}

_android_host_tags() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux*)
      echo "linux-x86_64"
      ;;
    Darwin*)
      local uname_m
      uname_m="$(uname -m)"
      if [[ "$uname_m" == "arm64" || "$uname_m" == "aarch64" ]]; then
        echo "darwin-arm64 darwin-x86_64"
      else
        echo "darwin-x86_64 darwin-arm64"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "windows-x86_64"
      ;;
    *)
      return 1
      ;;
  esac
}

setup_android_ndk_toolchain() {
  local arch="$1"
  local api_level="${2:-${ANDROID_API_LEVEL:-21}}"

  if [[ -z "$arch" ]]; then
    _android_ndk_log "setup_android_ndk_toolchain requires an architecture argument"
    return 1
  fi

  local ndk_root
  if ! ndk_root=$(android_resolve_ndk_root); then
    _android_ndk_log "Unable to locate the Android NDK (automatic download failed). Set ANDROID_NDK_ROOT or ANDROID_NDK_HOME."
    return 1
  fi

  local host_tags
  if ! host_tags=$(_android_host_tags); then
    _android_ndk_log "Unsupported host platform for Android NDK"
    return 1
  fi

  local bin_dir=""
  local host_tag=""
  local tag
  if [[ -d "${ndk_root}/toolchains/llvm/prebuilt" ]]; then
    for tag in $host_tags; do
      if [[ -d "${ndk_root}/toolchains/llvm/prebuilt/${tag}/bin" ]]; then
        bin_dir="${ndk_root}/toolchains/llvm/prebuilt/${tag}/bin"
        host_tag="$tag"
        break
      fi
    done
  fi

  if [[ -z "$bin_dir" && -d "${ndk_root}/bin" ]]; then
    bin_dir="${ndk_root}/bin"
    host_tag="standalone"
  fi

  if [[ -z "$bin_dir" ]]; then
    _android_ndk_log "Failed to locate the LLVM toolchain within the Android NDK (${ndk_root})"
    return 1
  fi

  local triple=""
  local tool_prefix=""
  local abi=""
  local extra_flags=""
  case "$arch" in
    android_arm32|arm32|armeabi-v7a)
      triple="armv7a-linux-androideabi${api_level}"
      tool_prefix="arm-linux-androideabi"
      abi="armeabi-v7a"
      extra_flags="-march=armv7-a -mthumb -mfpu=neon -mfloat-abi=softfp"
      ;;
    android_arm64|arm64|arm64-v8a|aarch64)
      triple="aarch64-linux-android${api_level}"
      tool_prefix="aarch64-linux-android"
      abi="arm64-v8a"
      extra_flags="-march=armv8-a"
      ;;
    android_x86|x86|i686)
      triple="i686-linux-android${api_level}"
      tool_prefix="i686-linux-android"
      abi="x86"
      extra_flags="-march=i686 -msse3 -mstackrealign -mfpmath=sse"
      ;;
    android_x64|android_x86_64|x64|x86_64)
      triple="x86_64-linux-android${api_level}"
      tool_prefix="x86_64-linux-android"
      abi="x86_64"
      extra_flags="-march=x86-64 -msse4.2 -mpopcnt"
      ;;
    *)
      _android_ndk_log "Unsupported Android architecture: ${arch}"
      return 1
      ;;
  esac

  local clang_prefix="${bin_dir}/${triple}"
  local cc="${clang_prefix}-clang"
  local cxx="${clang_prefix}-clang++"
  local ar="${bin_dir}/llvm-ar"
  local ranlib="${bin_dir}/llvm-ranlib"
  local strip="${bin_dir}/llvm-strip"

  if [[ ! -x "$ar" ]]; then
    local arch_ar="${bin_dir}/${tool_prefix}-ar"
    if [[ -x "$arch_ar" ]]; then
      ar="$arch_ar"
    fi
  fi
  if [[ ! -x "$ranlib" ]]; then
    local arch_ranlib="${bin_dir}/${tool_prefix}-ranlib"
    if [[ -x "$arch_ranlib" ]]; then
      ranlib="$arch_ranlib"
    fi
  fi
  if [[ ! -x "$strip" ]]; then
    local arch_strip="${bin_dir}/${tool_prefix}-strip"
    if [[ -x "$arch_strip" ]]; then
      strip="$arch_strip"
    fi
  fi

  if [[ ! -x "$cc" || ! -x "$cxx" ]]; then
    _android_ndk_log "Android NDK toolchain binaries not found for ${arch} (expected ${cc})"
    return 1
  fi

  export ANDROID_NDK_ROOT="$ndk_root"
  export ANDROID_PLATFORM="android-${api_level}"
  export ANDROID_API_LEVEL="$api_level"
  export ANDROID_TOOLCHAIN_HOST_TAG="$host_tag"
  export ANDROID_TOOLCHAIN_TRIPLE="$triple"
  export ANDROID_TOOLCHAIN_ABI="$abi"

  export CC="$cc"
  export CXX="$cxx"
  export AR="$ar"
  export RANLIB="$ranlib"
  export STRIP="$strip"

  local combined_flags="${extra_flags}"
  export ANDROID_TOOLCHAIN_EXTRA_CFLAGS="$combined_flags"
  export ANDROID_TOOLCHAIN_EXTRA_CXXFLAGS="$combined_flags"

  local cmake_flags=""
  local toolchain_file="${ndk_root}/build/cmake/android.toolchain.cmake"
  if [[ -f "$toolchain_file" ]]; then
    cmake_flags="-DANDROID=1 -DCMAKE_SYSTEM_NAME=Android -DANDROID_PLATFORM=android-${api_level}"
    cmake_flags+=" -DANDROID_ABI=${abi}"
    cmake_flags+=" -DANDROID_NDK=${ndk_root}"
    export ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE="$toolchain_file"
  else
    export ANDROID_TOOLCHAIN_CMAKE_TOOLCHAIN_FILE=""
    if [[ -d "${ndk_root}/platforms" ]]; then
      cmake_flags="-DANDROID=1 -DCMAKE_SYSTEM_NAME=Android -DANDROID_PLATFORM=android-${api_level}"
      cmake_flags+=" -DANDROID_ABI=${abi}"
      cmake_flags+=" -DANDROID_NDK=${ndk_root}"
    else
      local sysroot="${ndk_root}/sysroot"
      cmake_flags="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSROOT=${sysroot}"
      cmake_flags+=" -DCMAKE_C_COMPILER_TARGET=${triple}"
      cmake_flags+=" -DCMAKE_CXX_COMPILER_TARGET=${triple}"
      cmake_flags+=" -DANDROID=1 -DANDROID_ABI=${abi}"
    fi
  fi
  export ANDROID_TOOLCHAIN_CMAKE_FLAGS="$cmake_flags"

  return 0
}
