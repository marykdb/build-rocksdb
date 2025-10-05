# MinGW Snappy Auto-Import Check

This document captures the steps used to build the Snappy dependency with the MinGW toolchain and verify whether the resulting static library relies on auto-imported symbols.

## Environment preparation

```
sudo apt-get update
sudo apt-get install -y mingw-w64
```

## Build invocation

```
./buildDependencies.sh --output-dir build/lib/mingw_x86_64
```

This script bootstraps Snappy (alongside the other dependency archives) using the `x86_64-w64-mingw32` GCC toolchain.

## Verification

After the build completed, the produced archive was inspected for any auto-import thunks:

```
x86_64-w64-mingw32-nm build/lib/mingw_x86_64/libsnappy.a | grep __imp__
```

The command produced no matches, confirming that the MinGW-built static library does not depend on auto-imported symbols.
