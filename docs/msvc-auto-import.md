# MSVC auto-import diagnostics when using MinGW-built Snappy

Snappy is compiled in `buildDependencies.sh` with the MinGW cross toolchain and installed as a static archive (`libsnappy.a`).
Prior to defining `SNAPPY_STATIC`, the object files produced by GCC/LLVM's MinGW frontends assumed the GNU binutils
"auto-import" extension was available when referencing variables that live in DLLs (for example functions and runtime
structures provided by the MinGW CRT import libraries). When those objects were linked by MSVC's `link.exe` or `lld-link` in
MSVC mode, the Windows linker could not synthesize the auto-import thunks that MinGW expected and failed with diagnostics such
as `error LNK2026: module unsafe for SAFESEH image` or `error LNK2001: unresolved external symbol __imp___acrt_iob_func`
depending on which import was requested.

The MinGW dependency build now injects `-DSNAPPY_STATIC` so Snappy's headers drop the `__declspec(dllimport)` annotations.
MinGW still produces objects that link against its own static C runtime, but they no longer depend on the auto-import
extension. If you are consuming an older archive that predates this change—or rebuilding the dependency manually—be sure to
define `SNAPPY_STATIC` or rebuild Snappy with MSVC so the produced objects match MSVC's import model.
