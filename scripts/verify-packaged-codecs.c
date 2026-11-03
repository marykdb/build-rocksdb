/* Link against the six archives from a distribution, not host codec libraries.
 */
#include <rocksdb/c.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char* codec, const char* operation, char* error) {
  fprintf(stderr, "FAIL %s %s: %s\n", codec, operation,
          error == NULL ? "unexpected result" : error);
  if (error != NULL) rocksdb_free(error);
  exit(EXIT_FAILURE);
}

static void check_error(const char* codec, const char* operation,
                        char** error) {
  if (*error != NULL) fail(codec, operation, *error);
}

int main(int argc, char** argv) {
  static const struct {
    int value;
    const char* name;
  } codecs[] = {{1, "Snappy"}, {2, "Zlib"},  {3, "BZip2"},
                {4, "LZ4"},    {5, "LZ4HC"}, {7, "ZSTD"}};
  unsigned char expected[65536];
  size_t codec_index;
  size_t byte;
  if (argc != 2) {
    fprintf(stderr, "Usage: %s EXISTING_TEST_PARENT_DIRECTORY\n", argv[0]);
    return EXIT_FAILURE;
  }
  for (byte = 0; byte < sizeof(expected); byte++)
    expected[byte] = (unsigned char)(byte % 17);
  for (codec_index = 0; codec_index < sizeof(codecs) / sizeof(codecs[0]);
       codec_index++) {
    char path[4096];
    char* error = NULL;
    char* actual;
    size_t actual_length;
    size_t name_length;
    const char* name;
    const char* codec = codecs[codec_index].name;
    rocksdb_options_t* options = rocksdb_options_create();
    rocksdb_writeoptions_t* write_options = rocksdb_writeoptions_create();
    rocksdb_readoptions_t* read_options = rocksdb_readoptions_create();
    rocksdb_flushoptions_t* flush_options = rocksdb_flushoptions_create();
    rocksdb_table_properties_collection_t* properties;
    const rocksdb_tableproperties_t* table;
    rocksdb_t* db;
    int length = snprintf(path, sizeof(path), "%s/%s", argv[1], codec);
    if (length < 0 || (size_t)length >= sizeof(path))
      fail(codec, "test path", NULL);
    rocksdb_options_set_create_if_missing(options, 1);
    rocksdb_options_set_compression(options, codecs[codec_index].value);
    rocksdb_options_set_bottommost_compression(options,
                                               codecs[codec_index].value);
    rocksdb_options_set_disable_auto_compactions(options, 1);
    rocksdb_flushoptions_set_wait(flush_options, 1);
    db = rocksdb_open(options, path, &error);
    check_error(codec, "open", &error);
    if (db == NULL) fail(codec, "open", NULL);
    rocksdb_put(db, write_options, "key", 3, (const char*)expected,
                sizeof(expected), &error);
    check_error(codec, "put", &error);
    rocksdb_flush(db, flush_options, &error);
    check_error(codec, "flush", &error);
    properties = rocksdb_get_properties_of_all_tables(db, &error);
    check_error(codec, "table properties", &error);
    if (properties == NULL ||
        rocksdb_table_properties_collection_count(properties) != 1) {
      fail(codec, "exactly one flushed SST", NULL);
    }
    table = rocksdb_table_properties_collection_value_at(properties, 0);
    if (table == NULL) fail(codec, "SST properties", NULL);
    name = rocksdb_tableproperties_compression_name(table, &name_length);
    if (rocksdb_tableproperties_format_version(table) >= 7) {
      /* RocksDB 11.8 uses manager;hex-coded-actual-types; for format >= 7.
       * Require exactly this codec's type, not merely a nonempty manager name.
       */
      char encoded_type[4];
      const char* separator =
          name == NULL ? NULL : (const char*)memchr(name, ';', name_length);
      snprintf(encoded_type, sizeof(encoded_type), "%02X;",
               codecs[codec_index].value);
      if (separator == NULL || separator == name ||
          (size_t)(separator - name) + 1 + 3 > name_length ||
          memcmp(separator + 1, encoded_type, 3) != 0) {
        fprintf(stderr, "SST compression_name=%.*s length=%zu\n",
                (int)name_length, name == NULL ? "" : name, name_length);
        fail(codec, "SST actual compression type", NULL);
      }
    } else if (name == NULL || name_length != strlen(codec) ||
               memcmp(name, codec, name_length) != 0) {
      fail(codec, "SST compression name", NULL);
    }
    if (rocksdb_tableproperties_data_size(table) >= sizeof(expected)) {
      fail(codec, "compressible SST data was not compressed", NULL);
    }
    rocksdb_table_properties_collection_destroy(properties);
    rocksdb_close(db);
    rocksdb_options_set_create_if_missing(options, 0);
    db = rocksdb_open(options, path, &error);
    check_error(codec, "reopen", &error);
    if (db == NULL) fail(codec, "reopen", NULL);
    actual = rocksdb_get(db, read_options, "key", 3, &actual_length, &error);
    check_error(codec, "read compressed SST", &error);
    if (actual == NULL || actual_length != sizeof(expected) ||
        memcmp(actual, expected, sizeof(expected)) != 0) {
      fail(codec, "decompressed value equality", NULL);
    }
    rocksdb_free(actual);
    rocksdb_close(db);
    rocksdb_destroy_db(options, path, &error);
    check_error(codec, "cleanup", &error);
    rocksdb_flushoptions_destroy(flush_options);
    rocksdb_readoptions_destroy(read_options);
    rocksdb_writeoptions_destroy(write_options);
    rocksdb_options_destroy(options);
    printf("PASS packaged %s: compress, flush, properties, reopen and read\n",
           codec);
  }
  return EXIT_SUCCESS;
}
