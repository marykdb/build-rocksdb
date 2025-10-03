# Windows linker diagnostics

Kotlin/Native's MinGW targets link applications by invoking LLVM's `lld-link` driver.
Our CI standardizes on the `llvm-mingw-20241030-ucrt-x86_64` toolchain (LLVM 19), so
you should expect diagnostics similar to the following during the link step:

```
ld.lld: comdat section .xdata$_ZNK9__gnu_cxx24__concurrence_lock_error4whatEv without leader and unassociated, discarding
ld.lld: comdat section .pdata$_ZN7rocksdb9DBOptionsD2Ev without leader and unassociated, discarding
```

The messages appear while `lld` is scanning `libstdc++.a` (the standard C++ library
from the GCC 9.5 toolchain provided by the host system) and the `librocksdb.a`
static library that ships in this repository's Windows archive. The MinGW build
script compiles RocksDB with the GNU libstdc++ runtime (`-stdlib=libstdc++`) while
pointing clang at the LLVM sysroot for headers, so the WinLibs GCC runtime is
exposed via `MINGW_FALLBACK_SYSROOT`/`MINGW_GCC_SYSROOT` for the link step.【F:buildRocksdbMinGW.sh†L102-L190】

GCC emits auxiliary `.xdata` and `.pdata` COMDAT sections for exception-handling
helpers such as the `__gnu_cxx::concurrence_lock_error` types. When the functions are
optimized away, the associated metadata becomes orphaned. LLVM 19's linker now logs a
warning as it discards those unreferenced records. The warning does **not** indicate a
corruption in the RocksDB archive—you can reproduce it with an empty program that only
links against the same `libstdc++.a` runtime.

Kotlin/Native's driver already passes `-WX:no` to `lld-link`, so these warnings are not
promoted to errors. If the link ultimately fails, look further down the output for an
`error:` message that identifies the real cause (for example, a missing symbol or an
incorrect library search path). Rebuilding RocksDB is only necessary when that final
error points at unresolved symbols from `librocksdb.a`; otherwise, you can leave the
prebuilt archive as-is and address the configuration issue that triggered the error.
