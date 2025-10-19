#!/usr/bin/env bash
# build-mingw-x64.sh
# Git Bash script to replicate the selected GH Actions steps for Windows (MinGW) x86_64
# - Downloads and exposes LLVM-MinGW toolchain (msvcrt x86_64)
# - Provisions GCC runtime/sysroot for libstdc++
# - Provisions alternate GCC (winlibs GCC 9.5.0) for bzip2
# - Exports env vars and runs: ./build.sh mingwX64

set -euo pipefail

### Helpers
is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }
resolve_exe() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi
  local resolved
  resolved="$(command -v "$cmd")"
  [[ -n "$resolved" && -x "$resolved" ]] || return 1
  echo "$resolved"
}
prefer_toolchain_tool() {
  local tool
  for tool in "$@"; do
    if [[ -z "$tool" ]]; then
      continue
    fi
    if [[ -n "${BZIP2_GCC_BIN_DIR:-}" ]]; then
      local candidate
      for candidate in "${BZIP2_GCC_BIN_DIR}/${tool}" "${BZIP2_GCC_BIN_DIR}/${tool}.exe"; do
        if [[ -x "$candidate" ]]; then
          echo "$candidate"
          return 0
        fi
      done
    fi
    if [[ -n "${LLVM_MINGW_BIN:-}" ]]; then
      for candidate in "${LLVM_MINGW_BIN}/${tool}" "${LLVM_MINGW_BIN}/${tool}.exe"; do
        if [[ -x "$candidate" ]]; then
          echo "$candidate"
          return 0
        fi
      done
    fi
    if resolved="$(resolve_exe "$tool")"; then
      echo "$resolved"
      return 0
    fi
  done
  return 1
}
pwsh() { powershell.exe -NoProfile -ExecutionPolicy Bypass "$@"; }

fail() { echo "Error: $*" >&2; exit 1; }

if ! is_windows; then
  fail "This script must run in Git Bash on Windows."
fi

# Ensure we're in repo root (has build.sh)
if [[ ! -f "./build.sh" ]]; then
  fail "Run this from the repository root where ./build.sh exists."
fi

# Nice error trace
trap 'echo "Build failed at line $LINENO" >&2' ERR

### 2) Ensure curl present (Git for Windows ships curl) and install tools via choco
if ! have curl; then
  fail "curl is required (Git for Windows normally includes it)."
fi

# Ensure 7z and ninja are on PATH for this shell
if have "/c/Program Files/7-Zip/7z.exe"; then
  export PATH="/c/Program Files/7-Zip:$PATH"
fi
if have "/c/Program Files/7-Zip/7z.exe"; then :; elif ! have 7z; then
  fail "7z not found after install. Restart Git Bash or ensure 7-Zip is on PATH."
fi
if ! have ninja; then
  # GitHub Actions step used choco ninja; in Git Bash it may resolve as 'ninja'
  echo "ninja not found on PATH yet; continuing (build may still work if CMake finds it)."
fi

### 3) Toolchain locations
PWD_UNIX="$(pwd)"
TOOLCHAIN_DIR="$PWD_UNIX/toolchains"
mkdir -p "$TOOLCHAIN_DIR"

### 4) Install LLVM-MinGW (msvcrt x86_64)
LLVM_MINGW_VERSION="20241030"
LLVM_MINGW_DIST="llvm-mingw-${LLVM_MINGW_VERSION}-msvcrt-x86_64"
LLVM_ARCHIVE="${LLVM_MINGW_DIST}.zip"
LLVM_ARCHIVE_PATH="$PWD_UNIX/${LLVM_ARCHIVE}"
LLVM_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${LLVM_ARCHIVE}"

if [[ ! -d "$TOOLCHAIN_DIR/${LLVM_MINGW_DIST}" ]]; then
  echo "Downloading LLVM-MinGW toolchain (${LLVM_MINGW_VERSION})..."
  curl --fail --location --silent --show-error "$LLVM_URL" --output "$LLVM_ARCHIVE_PATH"
  echo "Extracting LLVM-MinGW into $TOOLCHAIN_DIR ..."
  rm -rf "$TOOLCHAIN_DIR/${LLVM_MINGW_DIST}"
  7z x "$LLVM_ARCHIVE_PATH" -o"$TOOLCHAIN_DIR" >/dev/null
  rm -f "$LLVM_ARCHIVE_PATH"
fi

LLVM_MINGW_ROOT_WIN="$TOOLCHAIN_DIR/${LLVM_MINGW_DIST}"
[[ -d "$LLVM_MINGW_ROOT_WIN" ]] || fail "Expected LLVM MinGW root not found: $LLVM_MINGW_ROOT_WIN"

# Convert to Unix paths for Git Bash
if have cygpath; then
  LLVM_MINGW_ROOT="$(cygpath -u "$LLVM_MINGW_ROOT_WIN")"
  LLVM_MINGW_BIN="$(cygpath -u "$LLVM_MINGW_ROOT_WIN/bin")"
else
  LLVM_MINGW_ROOT="$LLVM_MINGW_ROOT_WIN"
  LLVM_MINGW_BIN="$LLVM_MINGW_ROOT_WIN/bin"
fi

export LLVM_MINGW_ROOT
export PATH="$LLVM_MINGW_BIN:$PATH"

echo "LLVM-MinGW root: $LLVM_MINGW_ROOT"
echo "Added to PATH:   $LLVM_MINGW_BIN"

### 5) Provision GCC runtime/sysroot for libstdc++ (JetBrains msys2 bundle)
RUNTIME_ARCHIVE="msys2-mingw-w64-x86_64-2.zip"
RUNTIME_URL="https://download.jetbrains.com/kotlin/native/${RUNTIME_ARCHIVE}"
RUNTIME_ARCHIVE_PATH="$PWD_UNIX/${RUNTIME_ARCHIVE}"
RUNTIME_ROOT="$TOOLCHAIN_DIR/jetbrains-msys2"

if [[ ! -d "$RUNTIME_ROOT/msys2-mingw-w64-x86_64-2" ]]; then
  echo "Downloading GCC runtime/sysroot bundle..."
  curl --fail --location --silent --show-error "$RUNTIME_URL" --output "$RUNTIME_ARCHIVE_PATH"
  rm -rf "$RUNTIME_ROOT"
  mkdir -p "$RUNTIME_ROOT"
  7z x "$RUNTIME_ARCHIVE_PATH" -o"$RUNTIME_ROOT" >/dev/null
  rm -f "$RUNTIME_ARCHIVE_PATH"
fi

SYSROOT_CANDIDATE="$RUNTIME_ROOT/msys2-mingw-w64-x86_64-2"
[[ -d "$SYSROOT_CANDIDATE/include" ]] || fail "Failed to locate JetBrains sysroot includes at $SYSROOT_CANDIDATE"

if have cygpath; then
  MINGW_SYSROOT="$(cygpath -u "$SYSROOT_CANDIDATE")"
  MINGW_FALLBACK_SYSROOT="$(cygpath -u "${SYSROOT_CANDIDATE}/..")"
else
  MINGW_SYSROOT="$SYSROOT_CANDIDATE"
  MINGW_FALLBACK_SYSROOT="${SYSROOT_CANDIDATE}/.."
fi
# Compatibility names from your workflow
export MINGW_SYSROOT
export MINGW_GCC92_SYSROOT="$MINGW_SYSROOT"
export MINGW_FALLBACK_SYSROOT

echo "MINGW_SYSROOT: $MINGW_SYSROOT"

### 6) Provision alternate GCC (winlibs GCC 9.5.0) for bzip2
GCC9_VERSION="9.5.0"
WINLIBS_RELEASE="9.5.0-10.0.0-msvcrt-r1"
WINLIBS_ARCHIVE="winlibs-x86_64-posix-seh-gcc-${GCC9_VERSION}-mingw-w64msvcrt-10.0.0-r1.zip"
WINLIBS_URL="https://github.com/brechtsanders/winlibs_mingw/releases/download/${WINLIBS_RELEASE}/${WINLIBS_ARCHIVE}"
WINLIBS_ARCHIVE_PATH="$PWD_UNIX/${WINLIBS_ARCHIVE}"
ALT_ROOT="$TOOLCHAIN_DIR/winlibs-gcc-${GCC9_VERSION}"
if [[ ! -d "$ALT_ROOT/mingw64" ]]; then
  echo "Downloading WinLibs GCC toolchain (${GCC9_VERSION})..."
  curl --fail --location --silent --show-error "$WINLIBS_URL" --output "$WINLIBS_ARCHIVE_PATH"
  rm -rf "$ALT_ROOT"
  mkdir -p "$ALT_ROOT"
  7z x "$WINLIBS_ARCHIVE_PATH" -o"$ALT_ROOT" >/dev/null
  rm -f "$WINLIBS_ARCHIVE_PATH"
fi

echo $ALT_ROOT

# Find mingw64 inside extracted tree
if [[ -d "$ALT_ROOT/mingw64" ]]; then
  ALT_SYSROOT_WIN="$ALT_ROOT/mingw64"
else
  ALT_SYSROOT_WIN="$(find "$ALT_ROOT" -maxdepth 2 -type d -name 'mingw64' | head -n 1)"
fi
[[ -n "${ALT_SYSROOT_WIN:-}" ]] || fail "Failed to locate mingw64 sysroot in alternate GCC toolchain"

ALT_BIN_WIN="$ALT_SYSROOT_WIN/bin"
[[ -d "$ALT_BIN_WIN" ]] || fail "Failed to locate alternate GCC bin directory"

if have cygpath; then
  BZIP2_GCC_SYSROOT="$(cygpath -u "$ALT_SYSROOT_WIN")"
  BZIP2_GCC_BIN_DIR="$(cygpath -u "$ALT_BIN_WIN")"
else
  BZIP2_GCC_SYSROOT="$ALT_SYSROOT_WIN"
  BZIP2_GCC_BIN_DIR="$ALT_BIN_WIN"
fi

export BZIP2_GCC_SYSROOT
export BZIP2_GCC_BIN_DIR

echo "BZIP2_GCC_SYSROOT: $BZIP2_GCC_SYSROOT"
echo "BZIP2_GCC_BIN_DIR: $BZIP2_GCC_BIN_DIR"

# Ensure Windows-native TMP/TEMP for GNU binutils (they create temp files via WinAPI)
if have cygpath; then
  tmp_win="$(cygpath -w "${TMPDIR:-/tmp}" 2>/dev/null || true)"
  if [[ -z "$tmp_win" ]]; then
    tmp_win="$(cygpath -w /tmp 2>/dev/null || true)"
  fi
  if [[ -n "$tmp_win" ]]; then
    mkdir -p "$(cygpath -u "$tmp_win")"
    export TMP="$tmp_win"
    export TEMP="$tmp_win"
  fi
fi

# === MinGW compiler/tool selection (LLVM-first) ===
# Prefer LLVM-MinGW binaries for deterministic cross builds
if [[ -d "${BZIP2_GCC_BIN_DIR:-}" ]]; then
  export PATH="$BZIP2_GCC_BIN_DIR:$PATH"
fi

TOOLCHAIN_TRIPLE="${TOOLCHAIN_TRIPLE:-x86_64-w64-mingw32}"
export TOOLCHAIN_TRIPLE
export MINGW_TRIPLE="${MINGW_TRIPLE:-$TOOLCHAIN_TRIPLE}"

use_clang=0
if CC_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-gcc" "x86_64-w64-mingw32-gcc")"; then
  CXX_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-g++" "x86_64-w64-mingw32-g++")" || CXX_PATH="$CC_PATH"
else
  if ! CC_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-clang" "clang")"; then
    fail "Unable to locate a usable MinGW compiler for ${TOOLCHAIN_TRIPLE}"
  fi
  CXX_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-clang++" "clang++" "${TOOLCHAIN_TRIPLE}-clang")" || CXX_PATH="$CC_PATH"
  use_clang=1
fi

export CC="$CC_PATH"
export CXX="$CXX_PATH"

if ! AR_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-gcc-ar" "${TOOLCHAIN_TRIPLE}-ar" "llvm-ar" "ar")"; then
  fail "Unable to locate a usable archiver (ar)."
fi
if ! RANLIB_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-gcc-ranlib" "${TOOLCHAIN_TRIPLE}-ranlib" "llvm-ranlib" "ranlib")"; then
  fail "Unable to locate a usable ranlib."
fi
STRIP_PATH="$(prefer_toolchain_tool "strip" "${TOOLCHAIN_TRIPLE}-strip" "llvm-strip")"
NM_PATH="$(prefer_toolchain_tool "${TOOLCHAIN_TRIPLE}-gcc-nm" "${TOOLCHAIN_TRIPLE}-nm" "nm" "llvm-nm")"
OBJCOPY_PATH="$(prefer_toolchain_tool "objcopy" "${TOOLCHAIN_TRIPLE}-objcopy" "llvm-objcopy")"
OBJDUMP_PATH="$(prefer_toolchain_tool "objdump" "${TOOLCHAIN_TRIPLE}-objdump" "llvm-objdump")"

RC=""
if RC_PATH="$(prefer_toolchain_tool "windres" "${TOOLCHAIN_TRIPLE}-windres")"; then
  RC="$RC_PATH"
elif RC_PATH="$(prefer_toolchain_tool "llvm-rc")"; then
  RC="${RC_PATH} -F pe-x86-64"
fi

export AR="$AR_PATH"
export RANLIB="$RANLIB_PATH"
[[ -n "$STRIP_PATH" ]] && export STRIP="$STRIP_PATH" || export STRIP=strip
[[ -n "$NM_PATH" ]] && export NM="$NM_PATH" || export NM=nm
[[ -n "$OBJCOPY_PATH" ]] && export OBJCOPY="$OBJCOPY_PATH"
[[ -n "$OBJDUMP_PATH" ]] && export OBJDUMP="$OBJDUMP_PATH"
export RC

if (( use_clang )); then
  echo "Using LLVM-MinGW toolchain from: $(dirname "$CC_PATH")"
  local_target_flag="--target=${TOOLCHAIN_TRIPLE}"
  export CFLAGS="${local_target_flag} ${CFLAGS:-}"
  export CXXFLAGS="${local_target_flag} ${CXXFLAGS:-}"
  if [[ -n "${MINGW_SYSROOT:-}" && -d "$MINGW_SYSROOT/include" ]]; then
    export CFLAGS="--sysroot=$MINGW_SYSROOT -I$MINGW_SYSROOT/include ${CFLAGS}"
    export CXXFLAGS="--sysroot=$MINGW_SYSROOT -I$MINGW_SYSROOT/include ${CXXFLAGS}"
    export LDFLAGS="--sysroot=$MINGW_SYSROOT -L$MINGW_SYSROOT/lib ${LDFLAGS:-}"
  fi
else
  echo "Using WinLibs GCC toolchain from: $(dirname "$CC_PATH")"
  export CFLAGS="${CFLAGS:-}"
  export CXXFLAGS="${CXXFLAGS:-}"
  export LDFLAGS="${LDFLAGS:-}"
fi

if [[ -n "${AR:-}" ]]; then
  export CMAKE_AR="$AR"
fi
if [[ -n "${RANLIB:-}" ]]; then
  export CMAKE_RANLIB="$RANLIB"
fi
if [[ -n "${NM:-}" ]]; then
  export CMAKE_NM="$NM"
fi
if [[ -n "${OBJCOPY:-}" ]]; then
  export CMAKE_OBJCOPY="$OBJCOPY"
fi
if [[ -n "${OBJDUMP:-}" ]]; then
  export CMAKE_OBJDUMP="$OBJDUMP"
fi

# Create wrapper shims for missing MinGW cross names so detection scripts succeed
SHIM_DIR="$TOOLCHAIN_DIR/shims"
mkdir -p "$SHIM_DIR"
if ! command -v x86_64-w64-mingw32-clang >/dev/null 2>&1; then
  cat > "$SHIM_DIR/x86_64-w64-mingw32-clang" <<'EOF'
#!/usr/bin/env bash
exec clang --target=x86_64-w64-mingw32 "$@"
EOF
  chmod +x "$SHIM_DIR/x86_64-w64-mingw32-clang"
fi
if ! command -v x86_64-w64-mingw32-clang++ >/dev/null 2>&1; then
  cat > "$SHIM_DIR/x86_64-w64-mingw32-clang++" <<'EOF'
#!/usr/bin/env bash
exec clang++ --target=x86_64-w64-mingw32 "$@"
EOF
  chmod +x "$SHIM_DIR/x86_64-w64-mingw32-clang++"
fi
# Also provide gcc/g++ shims pointing to clang/clang++ for build systems that probe gcc names
# Removed creation of gcc/g++ shims as per instructions

# Prepend shims to PATH only if GCC is not present
if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  export PATH="$SHIM_DIR:$PATH"
fi

# Ensure ninja is on PATH (Chocolatey shim)
if ! command -v ninja >/dev/null 2>&1; then
  if [[ -x "/c/ProgramData/chocolatey/bin/ninja.exe" ]]; then
    export PATH="/c/ProgramData/chocolatey/bin:$PATH"
  fi
fi

# Diagnostics
echo "CC:      $CC"
echo "CXX:     $CXX"
echo "AR:      $AR"
echo "RANLIB:  $RANLIB"
echo "STRIP:   ${STRIP:-}"
echo "NM:      ${NM:-}"
echo "OBJCOPY: ${OBJCOPY:-}"
echo "OBJDUMP: ${OBJDUMP:-}"
echo "RC:      $RC"
echo "SYSROOT: $MINGW_SYSROOT"
echo "Ninja:   $(command -v ninja || echo 'not found')"

### 7) Build
echo "Starting build: ./build.sh mingwX64"
./build.sh mingwX64

echo "Done. Artifacts should be under build/archives/"
