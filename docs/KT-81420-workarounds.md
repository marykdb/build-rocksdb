# KT-81420 Kotlin/Native MinGW `.refptr` Workarounds

The upstream issue [KT-81420](https://youtrack.jetbrains.com/issue/KT-81420) describes how clang/lld-based MinGW builds produced by Kotlin/Native drop `.refptr.*` COMDAT sections that keep C++ v-tables alive. When those COMDATs disappear, RocksDB binaries that depend on Snappy crash immediately when linked into a Kotlin/Native `mingwX64` executable.

## Builds that avoid the crash

- Building the same native code with the stock GNU MinGW toolchain (`x86_64-w64-mingw32-g++` or `i686-w64-mingw32-g++`) keeps the `.refptr` COMDATs intact and the resulting binaries execute normally.
- Non-MinGW Kotlin/Native targets such as Linux and Apple never route through the problematic linker path, so the crash does not occur there.

## Repository defaults

This repository now prefers the GNU MinGW toolchain for Windows builds so the shipped archives remain compatible with Kotlin/Native while the upstream fix is pending. Set `USE_LLVM_MINGW=1` when invoking `buildRocksdbMinGW.sh` to force the previous clang/lld flow if you need it for experimentation.
