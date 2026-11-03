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

## Java-compatible expansion (fork 8868be54a)

The next expansion adds **110 C exports**, preserving all **2,082** exports
from `5c38774f4269dcb823442d6c8036b5db13e40713`, for **2,192** total implemented
exports. This is additive bridge work on the 11.8.1 engine. The earlier 19-export
baseline and its release checks above describe the previous pinned bundle; they
are not verification of this expansion.

| Family | Added exports | Contract |
| --- | ---: | --- |
| Mutable CF/DB settings | 60 | 29 scalar CF getter/setter pairs and DB compaction wakeup getter/setter. Handles retain their existing clone/destruction rules; Kotlin applies only explicitly changed fields. |
| Compression | 8 | Enabled/dictionary-training fields and normal/bottommost option attachment. Attachments copy values. Getters return independently owned compression-option handles, each destroyed with `rocksdb_compression_options_destroy`. |
| Compaction concurrency | 7 | Shared limiter construction, name, limit/reset/count, destruction and option attachment. Zero blocks new tasks; negative limits remove the cap. Options share ownership after the wrapper is destroyed. |
| Cache/rate diagnostics | 5 | HyperClock strict-capacity controls and limiter burst/byte/request counters. Counters measure real RocksDB I/O, not the broken JNI manual-request path. |
| SST diagnostics | 11 | Seven legacy SST metadata fields, three live-file fields and tracked-file enumeration. Checksum/path views carry explicit lengths and must be copied before owner/callback expiry. Tracked-file enumeration snapshots the manager's map before invoking callbacks. |
| Table properties | 7 | Index partition/encoding details and length-aware indexed property maps. Views borrow the collection or callback lifetime. Out-of-range map access returns null and zero length. These getters use the legacy `rocksdb_tableproperties_t` layout; never cast it to the distinct `rocksdb_table_properties_t` layout. |
| Runtime readback/control | 4 | Owned current CF/DB option strings, and compaction abort/resume. Free strings with `rocksdb_free`; null CF selects the default. Abort/resume calls nest and must balance. |
| Memtable factories | 3 | Skip-list lookahead, vector reservation and complete hash-linked-list configuration. Options retain the factory. Hash factories require a prefix extractor; nonconcurrent factories require concurrent memtable writes disabled. |
| Batch visitor | 1 | All Java-supported records, including CF IDs, blob indexes and transaction markers. Data carries explicit binary lengths. Callback zero reports an aborted iteration; continuation zero is successful early termination. No exception may escape a C callback. Marker callback failure is reported after satisfying the engine's internal checked-status assertions. |
| Extended events | 4 | Listener registration and borrowed copied-envelope accessors for file/SST/recovery/deletion events. Copy strings/properties before the callback returns. Listener callbacks may run on RocksDB threads; callers must synchronize their own state and handle failures inside callbacks. |

Option strings expose the engine's full serialization. The Kotlin effective-option
snapshots intentionally select only their documented portable scalar subset;
these snapshots do not promise lossless round trips for enums, factories,
callbacks or structured settings. Startup options remain the route for settings
whose Java mutable serialization is broken.

### Expansion verification boundary

The new behavioral cases in `db/c_test.c` passed in the local macOS ARM64 Debug
CMake C suite. They cover independently owned compression copies, shared resource
ownership, real flush byte/request counters, cache and limiter controls, mutable
readback before/after partial updates, metadata equality and copied lifetimes,
tracked files, table-map bounds, built-in memtable read/write operation, all
Java-supported batch record families, successful early termination, invalid
callbacks and failures on transaction markers. The existing C suite and generated
round trips also ran; no earlier Kotlin or release-matrix result is reused as a
pass for the new wrappers.

The source check, API completeness/link check, generated-file freshness and ABI
compatibility against the 2,082-export baseline passed for this expansion.
Repository-wide `AUTO_CLEAN=1 make -j2 check` and
`AUTO_CLEAN=1 ASSERT_STATUS_CHECKED=1 make -j2 check` were attempted in separate
source snapshots of fork `8868be54a` under `/tmp`. Both reached their 120-second
wall limit while compiling database objects, before test execution. Neither
reported a compiler or test failure before deliberate termination. These broad
engine gates are **not certified complete** and must not be reported as passes.
The snapshots excluded the unrelated untracked `db_test2` and did not alter
shared build outputs. Published native archives and the full platform matrix
still require the new build/release pipeline.

### Java/JNI exclusions retained

The C bridge does not repair Java/JNI 11.8.1. Common Kotlin therefore excludes:

- Range-filtered table properties: JNI returns `long[]` instead of its map.
- Compaction manual/output-prefix fields omitted by JNI statistics copying.
- Manual `RateLimiter.request`, whose JNI calls an unimplemented old overload.
- Live compression changes and live level-multiplier updates with broken Java
  mutable-option serialization; startup configuration remains available.
- Replay/trace filtering, current-WAL/extended inventory, newer transaction and
  backup controls without a corresponding Java API.

The supported event and property surfaces also preserve Java's limitations:
handle-deletion callbacks do not inspect or retain the dying borrowed handle;
flush/sync/truncate/close I/O events report no meaningful offset or length;
Java-compatible property maps are string views, not lossless arbitrary binary
maps. Native C map getters themselves remain length-aware.

## Packaged compression regression gate

The first expansion's binding CI exposed a packaging defect: Linux and MinGW
shipped codec archives but compiled the engine without their enablement macros.
The recipe now enables the shipped zlib, bzip2, Snappy, LZ4 and ZSTD code paths,
matching Apple and Android, and uses the target dependency headers.

`scripts/verify-packaged-codecs.sh` links only the six packaged archives and
checks Snappy, zlib, bzip2, LZ4, LZ4HC and ZSTD. Each case creates a compressed
SST, checks the actual codec metadata and compressed size, closes and reopens
the database, and verifies the decompressed bytes. The release workflow runs
this gate in both Linux build containers and on the native Windows runner.
The codec-agnostic Debug C API job remains unchanged.

The packaged macOS positive control passed all six cases; substituting a
codec-disabled engine made the same gate fail at Snappy open. Linux/Windows
execution is gated by their release jobs. This is separate from the full-engine
`make check` boundary above.
