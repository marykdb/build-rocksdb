# MinGW build guidance and `.refptr` retention

This project now hardens the Windows/MinGW build so that static archives keep the
`.refptr` COMDAT sections that C++ libraries (such as Snappy) rely on to preserve
v-table pointers. Kotlin/Native's LLVM-based linker previously discarded those
COMDATs, rewriting RIP-relative loads to point at zero and crashing executables
at runtime. The mitigation rewrites MinGW object files after they are built so
the `.refptr` sections are marked as ordinary read-only data. That prevents the
linker from garbage-collecting them and fixes the crash described in
[KT-81420](https://youtrack.jetbrains.com/issue/KT-81420).

## Supported build workflows

You can safely produce working MinGW artefacts in any of the following ways:

1. **Top-level orchestrator** – On a Linux host run `./build.sh` (optionally with
   `--konan-version` and/or explicit target names). The script provisions the
   toolchain, invokes `buildDependencies.sh`, and then calls
   `buildRocksdbMinGW.sh`. The mitigation automatically post-processes every
   MinGW archive that the orchestrator produces, so the resulting ZIP archives
   keep their `.refptr` data intact.
2. **Direct RocksDB rebuild** – When you only need to refresh the RocksDB static
   library, run `./buildRocksdbMinGW.sh --arch=x86_64` or `--arch=arm64`. The
   script drives a dedicated CMake build directory and now post-processes the
   generated `librocksdb.a` (and its staged variant under `rocksdb-build/`) to
   neutralise `.refptr` COMDATs.
3. **Dependency-only refresh** – If you are updating Snappy/Zstd/LZ4/BZip2/Zlib
   independently, invoke `./buildDependencies.sh --output-dir build/lib/mingw_x86_64`
   (or `mingw_arm64`). The script now scans each produced archive and rewrites
   any `.rdata$.refptr.*` sections, ensuring the resulting dependencies are safe
   to link into Kotlin/Native binaries.

In every workflow the fix runs automatically; no manual flags are necessary as
long as the relevant binutils (`objdump`, `objcopy`, and `ar`) are on `PATH`
(either from `llvm-mingw` or GNU Binutils).

## Manual verification tips

If you want to double-check a library, use:

```bash
objdump -h build/lib/mingw_x86_64/libsnappy.a | grep '\.refptr'
```

The sections should appear without the `LINK_ONCE_*` annotation after the build,
confirming the mitigation succeeded.
