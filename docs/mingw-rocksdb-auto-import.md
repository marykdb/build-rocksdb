# MinGW RocksDB Auto-Import Check

This note captures how to build the Windows-specific RocksDB objects with the MinGW toolchain, verify whether they rely on auto-imported symbols, and compile them with flags that avoid those imports.

## Environment preparation

```
sudo apt-get update
sudo apt-get install -y mingw-w64
```

Initialize the RocksDB submodule so the sources are available locally:

```
git submodule update --init
```

## Dependency build

RocksDB relies on several third-party libraries. Build the MinGW variants once via the provided helper:

```
./buildDependencies.sh --output-dir build/lib/mingw_x86_64
```

## Configure CMake

Generate a MinGW Ninja build using `cmake`. For the auto-import audit we only need the build rules; a release configuration with optimizations disabled keeps the compile lightweight:

```
cmake -S rocksdb -B build/lib/mingw_x86_64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS_RELEASE=-O0 \
  -DCMAKE_CXX_FLAGS_RELEASE=-O0
```

## Build the Windows environment object

The Windows environment implementation (`port/win/env_win.cc`) is where most platform APIs are consumed. Build just that translation unit:

```
ninja -C build/lib/mingw_x86_64 \
  CMakeFiles/rocksdb.dir/port/win/env_win.cc.obj
```

The command emits `build/lib/mingw_x86_64/CMakeFiles/rocksdb.dir/port/win/env_win.cc.obj`.

## Verification

Inspect the object (or a full `librocksdb.a` if you subsequently build the entire target) for `__imp__` thunks:

```
x86_64-w64-mingw32-nm \
  build/lib/mingw_x86_64/CMakeFiles/rocksdb.dir/port/win/env_win.cc.obj \
  | grep __imp__
```

The listing includes entries such as `__imp__errno` and `__imp__localtime64_s`, confirming that RocksDB's upstream MinGW build imports Windows DLL data symbols and therefore requires auto-import support.

## Removing the auto-import requirement

MinGW marks many CRT entry points with `__declspec(dllimport)`, which makes Clang and GCC emit `__imp__` references that require the linker’s auto-import logic. Overriding that decoration at compile time is sufficient to keep the objects self-contained:

```
cmake -S rocksdb -B build/lib/mingw_x86_64 \
  -DCMAKE_C_FLAGS="-O2 -U_WIN32_WINNT -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00 -D_CRTIMP= -D_SECIMP=" \
  -DCMAKE_CXX_FLAGS="-O2 -U_WIN32_WINNT -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00 -D_CRTIMP= -D_SECIMP="
```

The `buildRocksdbMinGW.sh` helper wires these definitions in automatically, so invoking it will configure and build RocksDB without auto-imported symbols:

```
./buildRocksdbMinGW.sh --arch=x86_64
```

After either workflow completes, inspect the Windows environment object again:

```
x86_64-w64-mingw32-nm \
  build/lib/mingw_x86_64/CMakeFiles/rocksdb.dir/port/win/env_win.cc.obj \
  | grep __imp__
```

The build prints no output, confirming that the MinGW artifacts no longer rely on auto-imported symbols.
