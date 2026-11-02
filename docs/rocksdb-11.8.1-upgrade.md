# RocksDB 11.8.1 upgrade report

## Source and branches

- Upstream tag: `v11.8.1`, commit `abeebd9630f11bd08c28b7bd43c7bdfc62050654`, verified against Facebook's GitHub remote.
- `11.8.fb`: the exact upstream release, following the previous `10.10.fb` naming pattern. The current upstream `11.8.fb` remote has advanced beyond the release tag, so it is deliberately not used as the release base.
- `11.8.maryk`: the curated Maryk port on top of that release.
- Consolidated commits: `83e4b2e73` (platform support) and `3192d7cbd` (C API, generator, compatibility, and tests).
- Build-project review branch: `rocksdb-11.8.1`.
- Previous Maryk revision: `a0a9a3e637ada76e3ada6deba79f6fbc56956f08` on `10.10.maryk`, based on `v10.10.1`.
- The build repository pins the new Maryk commit through its submodule gitlink.

The 27 non-merge Maryk commits above 10.10.1 are carried forward as a consolidated port. Existing branches and published releases are preserved. These changes are prepared locally; pushing the fork branches and running the release workflow are separate publication steps.

## Consolidation and compatibility

The port uses 11.8's C API generation system. Changes live in the source templates and specification; `db/c.cc`, `include/rocksdb/c.h`, and generated fragments are regenerated together. Four status-bearing write-batch wrappers now use the generator instead of duplicate manual implementations.

All 1,338 implemented functions from the previous Maryk C API retain their public signatures, and the compatibility checker preserves 231 enum/typedef symbols. The resulting header has 2,063 declared C functions, each with exactly one implementation. The historical declaration `rocksdb_writebatch_wi_create_from` remains removed under upstream's existing allowlist: it never had an implementation.

11.8 upstream overlaps with Maryk's extensions. Existing Maryk signatures take precedence, including error-bearing write-batch functions, binary column-family names, transaction wrappers, background-error strings, and ownership of borrowed database/transaction/write-batch handles. This is the Maryk C API, so it does not claim vanilla 11.8 C ABI compatibility.

Upstream behavior with conflicting names remains available where needed through explicit additions:

- `rocksdb_backup_engine_info_app_metadata_with_length`: a borrowed, length-aware metadata result.
- `rocksdb_readoptions_set_table_filter_with_callback`: callback state with shared lifetime across iterator copies. The legacy handle-based setter continues borrowing the caller's filter.
- `rocksdb_flushjobinfo_table_properties_view` and `rocksdb_externalfileingestioninfo_table_properties_view`: borrowed upstream metadata views. Maryk's existing table-property wrappers remain available.

The port adapts database openers to 11.8's `unique_ptr` ownership transfer. WAL filter callbacks use a borrowed write-batch wrapper, replacing an upstream layout cast that is incompatible with Maryk's ownership-aware representation. Redundant table-filter state was removed; presence and clearing use the actual callback stored in `ReadOptions`.

Removed upstream options retain compatibility shims: managed iterators remain ineffective, the SST-size-checking option stores its legacy setter/getter value without changing validation, and the deprecated maximum memtable compaction level still returns zero. The unused slice-transform `in_range` parameter remains accepted. Performance-level enum values remain compatible with Maryk. The C statistics test uses 11.8's updated bytes-written ticker ID.

Platform patches retain Android memory-advice/time compatibility, watchOS/tvOS stack-trace guards, and the Windows checkpoint hard-link fallback. Makefile changes are reduced to the two required platform-variable exports. The existing Linux GCC 11 container satisfies upstream's C++20 requirement.

## Verification

Local verification used macOS ARM64, Apple Clang, C++20, a fresh Debug CMake/Ninja build, and clang-format 21.1.2. Debug keeps assertions enabled. Compression codecs were disabled for these focused tests.

| Check | Result |
| --- | --- |
| Combined upstream and Maryk `c_test` | Passed; includes 116 named phases and 25 generated option round-trip groups |
| Checkpoint tests | 41 passed |
| Write-batch tests | 29 passed; 2 upstream tests remain disabled |
| Indexed write-batch tests | 89 passed |
| Statistics tests | 3 passed |
| C API completeness | 2,063 declarations, exactly one implementation each |
| C API compatibility against `10.10.maryk` | Passed |
| clang-format 21 check of templates and C tests | Passed |
| Generated-file reproducibility | Checked with upstream's `verify_generated_up_to_date.py` |
| Shell syntax, configuration listing, whitespace | Passed |

The C suite retains upstream coverage and Maryk's transaction/import, binary-name, mutable-option, TTL, callback, and lifecycle cases. Additional regressions cover WAL batch rewriting, borrowed versus owned table filters, and compatibility shims. Each local test run uses a fresh temporary directory.

Reproduce the focused build:

```bash
cmake -S rocksdb -B build/verify-11.8.1 -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DWITH_TESTS=ON -DWITH_GFLAGS=OFF \
  -DWITH_BENCHMARK_TOOLS=OFF -DWITH_TOOLS=OFF -DWITH_CORE_TOOLS=OFF \
  -DROCKSDB_BUILD_SHARED=OFF -DPORTABLE=ON \
  -DWITH_SNAPPY=OFF -DWITH_LZ4=OFF -DWITH_ZSTD=OFF \
  -DWITH_ZLIB=OFF -DWITH_BZ2=OFF
cmake --build build/verify-11.8.1 --parallel 8 \
  --target c_test checkpoint_test write_batch_test write_batch_with_index_test statistics_test
TEST_TMPDIR="$(mktemp -d)" ctest --test-dir build/verify-11.8.1 -R '^c_test$' --output-on-failure
for test_executable in checkpoint_test write_batch_test write_batch_with_index_test statistics_test; do
  TEST_TMPDIR="$(mktemp -d)" "build/verify-11.8.1/$test_executable"
done
```

The release workflow now has a required Linux C API job that checks symbols, compares signatures against the immutable previous Maryk commit, and runs the assertion-enabled C suite. Full release archives, compression-enabled builds, Linux/Windows/Android and Apple cross-target builds, and downstream Kotlin bindings were not built locally. No GitHub workflow or publication was triggered.

The two pre-existing toolchain ZIP downloads and the old `rocksdb/db_test2` executable were left untouched. The executable becomes visible as untracked under 11.8's ignore rules.
