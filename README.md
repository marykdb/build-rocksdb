# RocksDB prebuilt artifacts for marykdb

## Purpose
This repository automates building and packaging static RocksDB distributions with their compression codecs for every platform consumed by marykdb's [`rocksdb-multiplatform`](https://github.com/marykdb/rocksdb-multiplatform). The `build.sh` orchestrator drives platform-specific scripts to produce archives for Linux, Windows (MinGW), macOS, iOS, watchOS, tvOS, and Android from a single checkout.

## Build workflow
1. `build.sh` resolves the active host platform, accepts an optional Kotlin/Native version, and selects the configurations to compile (defaults are picked per host when no explicit list is provided).
2. Kotlin/Native toolchains are installed on demand for cross-compilation targets before each build step runs.
3. The RocksDB headers from the `rocksdb` submodule are copied into `build/include` so that every archive ships a consistent header set.
4. `buildDependencies.sh` fetches, verifies, and builds static `zlib`, `bzip2`, `zstd`, `snappy`, and `lz4` libraries for the requested target into `build/lib/<target>/`.
5. The relevant platform script (`buildRocksdbLinux.sh`, `buildRocksdbMinGW.sh`, `buildRocksdbApple.sh`, or `buildRocksdbAndroid.sh`) compiles RocksDB itself for the configuration that is being processed.
6. Headers and static libraries are collected into `build/archives/<artifact>.zip`, yielding an `include/` directory with RocksDB headers and a `lib/` directory with `librocksdb.a` alongside the codec libraries built in step 4.

## Published artifacts
The table below lists every archive produced by the build orchestration along with the intended platform, architecture, and host requirement. All archives share the layout described above (headers under `include/`, static libraries under `lib/`).

| Archive | Platform | CPU architecture | Host required to build |
| --- | --- | --- | --- |
| `rocksdb-linux-x86_64.zip` | Linux | x86_64 | Linux |
| `rocksdb-linux-arm64.zip` | Linux | arm64 | Linux |
| `rocksdb-mingw-x86_64.zip` | Windows via MinGW | x86_64 | Linux |
| `rocksdb-mingw-arm64.zip` | Windows via MinGW | arm64 | Linux |
| `rocksdb-macos-x86_64.zip` | macOS | x86_64 | macOS |
| `rocksdb-macos-arm64.zip` | macOS | arm64 | macOS |
| `rocksdb-ios-arm64.zip` | iOS devices | arm64 | macOS |
| `rocksdb-ios-simulator-arm64.zip` | iOS Simulator | arm64 | macOS |
| `rocksdb-watchos-arm64.zip` | watchOS devices | arm64_32 | macOS |
| `rocksdb-watchos-device-arm64.zip` | watchOS devices | arm64 | macOS |
| `rocksdb-watchos-simulator-arm64.zip` | watchOS Simulator | arm64 | macOS |
| `rocksdb-tvos-arm64.zip` | tvOS devices | arm64 | macOS |
| `rocksdb-tvos-simulator-arm64.zip` | tvOS Simulator | arm64 | macOS |
| `rocksdb-android-arm32.zip` | Android | arm32 (armeabi-v7a) | Linux or macOS |
| `rocksdb-android-arm64.zip` | Android | arm64 | Linux or macOS |
| `rocksdb-android-x86.zip` | Android | x86 | Linux or macOS |
| `rocksdb-android-x64.zip` | Android | x86_64 | Linux or macOS |

The archives are staged under `build/archives/` during a build and can be published from there when the build completes.

## Platform notes
- Apple device and simulator archives only cover 64-bit hardware (arm64 for devices, arm64-based simulators, and x86_64 for macOS). Legacy 32-bit targets such as armv7 or i386 are intentionally not produced because those platforms have been deprecated for years by Apple.
- Similarly, simulator builds for iOS, watchOS, and tvOS are arm64-only—aside from the macOS x86_64 build, there are no simulator x86_64 variants because developers are expected to be on Apple Silicon hardware five years after its introduction.
- The `watchos-arm64` archive labelled above uses the `arm64_32` ABI (64-bit registers with 32-bit pointers) because that remains the deployment baseline for physical watches.

### Windows (MinGW) toolchain baseline
- Continuous integration now provisions an MSYS2 MinGW-w64 environment (via [`msys2/setup-msys2`](https://github.com/msys2/setup-msys2)) and installs the `mingw-w64-x86_64-toolchain`, `mingw-w64-x86_64-cmake`, and `mingw-w64-x86_64-ninja` packages. This supplies GCC/Clang frontends, the MinGW sysroot, and build utilities directly from the MSYS2 distribution.
- RocksDB is compiled with `-O3 -DNDEBUG -fexceptions -frtti -fno-omit-frame-pointer` and the Windows portability defines (`WIN32_LEAN_AND_MEAN`, `UNICODE`, `_UNICODE`, `PORTABLE=1`). Link flags request static libstdc++/libgcc to keep the produced `.a` archives self-contained when linked from Kotlin/Native or other consumers.

## Usage examples
- List available build configurations:
  ```bash
  ./build.sh --list
  ```
- Build the default set for your current host (for example, Linux will build the Linux and MinGW variants):
  ```bash
  ./build.sh
  ```
- Build a specific archive while overriding the Kotlin/Native version used for toolchain provisioning:
  ```bash
  ./build.sh --konan-version 2.0.21 iosArm64
  ```
  The `--konan-version` flag applies to every configuration in the invocation.

Before starting a build, ensure the RocksDB submodule is initialized:
```bash
git submodule update --init --recursive
```
This is required because the orchestrator copies headers directly from `rocksdb/include`.

## Troubleshooting
- [Windows linker diagnostics](docs/windows-linker-diagnostics.md) explains the `comdat section ... without leader and unassociated`
  messages that `lld-link` may print when the Kotlin/Native toolchain links against the
  prebuilt MinGW archives.
