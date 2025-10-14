# Avoiding Kotlin/Native `.refptr` losses on MinGW (KT-81420)

## Background
Kotlin/Native's `mingwX64` binaries can crash immediately when they link against C++ static
libraries built with the MinGW toolchain. MinGW emits `.refptr.*` COMDAT sections that keep
v-tables and RTTI objects alive, but the LLD-based linker that Kotlin/Native ships trims those
sections away, rewrites the RIP-relative loads to a zero displacement, and the executable dereferences
instruction bytes instead of the real v-table pointer. The failure only reproduces on MinGW builds;
Linux and Apple targets continue to work because they do not rely on `.refptr` indirection.

## Build configurations that avoid the crash
The upstream bug report highlights two ways to produce working Windows binaries until LLD is fixed:

1. **Link with the GNU MinGW toolchain.** Building and linking with `x86_64-w64-mingw32-g++` (or
   the matching `aarch64-w64-mingw32-g++`) keeps `.refptr` sections intact, so the generated
   executable reads the correct v-table addresses.
2. **Retag `.refptr.*` sections before Kotlin/Native sees them.** Post-processing the static
   libraries with `objcopy --rename-section` to move the MinGW `.refptr.*` COMDATs into regular
   `.rdata` sections preserves the relocations that the v-table loads expect. Kotlin/Native's
   LLD linker no longer garbage-collects the data, so the binary executes normally.

## Automation in this repository
The MinGW build scripts now perform the second workaround automatically:

- `buildDependencies.sh` sanitises every `.a` file in `build/lib/mingw_*` after the codecs finish
  compiling.
- `buildRocksdbMinGW.sh` runs the same sanitiser on `librocksdb.a` produced by CMake.

As a result, Kotlin/Native consumers of the prebuilt archives inherit MinGW-compatible static
libraries that remain safe to link even before JetBrains delivers an upstream fix.
