# C wrappers for the common Kotlin API

The RocksDB `11.8.maryk` branch adds 19 C exports while preserving all 2,063
functions and 283 enum/typedef symbols from the previous pinned revision
`8c1c45524`.

| Family | Exports | Contract |
| --- | --- | --- |
| Memtable range statistics | `rocksdb_approximate_memtable_stats`, `_cf` | Approximate record count and bytes in `[start, limit)`, using explicit binary lengths and `uint64_t` outputs. Invalid arguments return an error and zero both outputs. |
| SST table properties | `rocksdb_get_properties_of_all_tables`, `_cf`, `rocksdb_get_properties_of_tables_in_range`, `_cf` | Owned collection of filenames and shared immutable properties. Empty success is a non-null collection. Invalid input or a DB error returns null and an error string. Range results describe entire overlapping SSTs. |
| Collection lifetime | `rocksdb_table_properties_collection_destroy`, `_count`, `_key_at`, `_value_at` | Indexed filename and `rocksdb_tableproperties_t` views are borrowed until collection destruction. Do not destroy borrowed property handles. Collections remain valid after the DB closes. Invalid positions return null and zero filename length. |
| Column-family clipping | `rocksdb_clip_column_family` | Physically removes keys outside binary `[begin, end)` bounds. Uses the CF comparator, rejects reversed ranges, and propagates DB errors. Requires application exclusion of concurrent writes. |
| Legacy compaction options | Six generated FIFO/universal field getter/setters and two `rocksdb_options_set_compaction_options_*` bridges | Accepts the same opaque handles as the existing constructors. This avoids unsafe casts between similarly named but distinct C types. Option values are copied into DB/CF options. |

Memtable statistics and collection getters have default-column-family and
explicit-column-family variants. The range collection accepts zero ranges as
an empty result. All range validation uses the selected column family's
comparator. Table-property collections can be read concurrently, but callers
must synchronize destruction.

## Generated sources and checks

The nontrivial wrappers live in `rocksdb/tools/c_api_gen/c_base.h` and
`c_base.cc`. Scalar compaction controls live in `spec.json` and their generated
`c_generated_compaction_options_legacy` fragments. Never edit generated
`include/rocksdb/c.h` or `db/c.cc` directly.

The assertion-enabled C regression suite covers binary bounds, CF isolation,
unflushed/flushed memtable statistics, multiple SSTs and range filtering,
empty results, invalid arrays/counts/bounds, clipping boundaries, metadata
lifetime after database close, canonical option attachment, and generated
option round trips. Local macOS ARM64 verification uses the existing Debug
CMake build with compression disabled:

```bash
python3 rocksdb/tools/c_api_gen/regen_all.py --clang-format clang-format-21
python3 rocksdb/tools/c_api_gen/check_api_completeness.py
python3 rocksdb/tools/c_api_gen/check_api_compatibility.py --ref 8c1c45524
python3 rocksdb/tools/c_api_gen/verify_generated_up_to_date.py --clang-format clang-format-21
cmake --build build/verify-11.8.1 --parallel 6 --target c_test
TEST_TMPDIR="$(mktemp -d)" ctest --test-dir build/verify-11.8.1 \
  -R '^c_test$' --timeout 60 --output-on-failure
```

The release workflow runs the C suite before publishing the complete native
platform matrix. Successful focused local C checks do not certify that matrix.
The repository-wide `make check` gate additionally exposed unused parameters in
the previous removed-option compatibility shims; those no-op implementations
now explicitly discard their parameters to satisfy `-Werror`.

## Java/JNI limitation

RocksDB 11.8.1's `Java_org_rocksdb_RocksDB_getPropertiesOfTablesInRange` JNI
implementation returns the input range-handle `jlongArray` instead of the
constructed properties map. JVM use can therefore fail with an
`IncompatibleClassChangeError` (`[J` is not a `Map`). The new C range-collection
API is covered by native tests, but common Kotlin range-properties exposure
must wait for corrected JVM and Android JNI artifacts. The current C-only work
does not claim to repair or republish those artifacts.
