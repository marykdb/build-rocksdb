/* Exercise the packaged C API under a legacy Windows code page. The independent
 * wide-API checks prevent narrow APIs from agreeing on the same wrong filename. */
#include <rocksdb/c.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define UNICODE_NAME "caf\xC3\xA9-\xC4\xB0-\xE6\xBC\xA2\xE5\xAD\x97-\xF0\x9F\xA7\xAA"

static void require(int condition, const char* operation) {
  if (!condition) {
    fprintf(stderr, "FAIL packaged Windows Unicode: %s (Windows error %lu)\n",
            operation, (unsigned long)GetLastError());
    exit(EXIT_FAILURE);
  }
}

static void check_error(char* error) {
  if (error != NULL) {
    fprintf(stderr, "FAIL packaged Windows Unicode: %s\n", error);
    rocksdb_free(error);
    exit(EXIT_FAILURE);
  }
}

static wchar_t* wide_path(const char* path) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  wchar_t* result;
  require(length > 0, "UTF-8 path conversion length");
  result = (wchar_t*)malloc((size_t)length * sizeof(wchar_t));
  require(result != NULL, "wide path allocation");
  require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, result,
                            length) == length, "UTF-8 path conversion");
  return result;
}

static void path_join(char* result, size_t capacity, const char* parent,
                      const char* name) {
  int length = snprintf(result, capacity, "%s/%s", parent, name);
  require(length > 0 && (size_t)length < capacity, "test path length");
}

static void verify_current(const char* path) {
  char current[4096];
  wchar_t* wide;
  path_join(current, sizeof(current), path, "CURRENT");
  wide = wide_path(current);
  require(GetFileAttributesW(wide) != INVALID_FILE_ATTRIBUTES,
          "CURRENT exists at the exact Unicode filename");
  free(wide);
}

static void verify_value(rocksdb_t* db, rocksdb_readoptions_t* options) {
  char* error = NULL;
  size_t length;
  char* value = rocksdb_get(db, options, "key", 3, &length, &error);
  check_error(error);
  require(value != NULL && length == 7 && memcmp(value, "correct", 7) == 0,
          "existing record round trip");
  rocksdb_free(value);
}

int wmain(int argc, wchar_t** argv) {
  char base[4096], parent[4096], source[4096], backups[4096], restored[4096];
  wchar_t* wide;
  char* error = NULL;
  rocksdb_options_t* options;
  rocksdb_writeoptions_t* writes;
  rocksdb_readoptions_t* reads;
  rocksdb_backup_engine_options_t* backup_options;
  rocksdb_backup_engine_t* engine;
  rocksdb_restore_options_t* restore_options;
  rocksdb_env_t* env;
  rocksdb_t* db;
  require(argc == 2, "expected test parent directory");
  require(GetACP() != CP_UTF8, "runner must use a legacy Windows code page");
  printf("Windows Unicode smoke under code page %u\n", GetACP());
  require(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[1], -1, base,
                            sizeof(base), NULL, NULL) > 0, "test root conversion");
  path_join(parent, sizeof(parent), base, "parent-" UNICODE_NAME);
  wide = wide_path(parent);
  require(CreateDirectoryW(wide, NULL) != 0, "create exact Unicode parent");
  free(wide);
  path_join(source, sizeof(source), parent, "source-" UNICODE_NAME);
  path_join(backups, sizeof(backups), parent, "backups-" UNICODE_NAME);
  path_join(restored, sizeof(restored), parent, "restored-" UNICODE_NAME);

  options = rocksdb_options_create();
  writes = rocksdb_writeoptions_create();
  reads = rocksdb_readoptions_create();
  rocksdb_options_set_create_if_missing(options, 1);
  db = rocksdb_open(options, source, &error);
  check_error(error);
  require(db != NULL, "create database");
  rocksdb_put(db, writes, "key", 3, "correct", 7, &error);
  check_error(error);
  rocksdb_close(db);
  verify_current(source);
  rocksdb_options_set_create_if_missing(options, 0);
  db = rocksdb_open(options, source, &error);
  check_error(error);
  require(db != NULL, "reopen existing database without creating a new one");
  verify_value(db, reads);

  env = rocksdb_create_default_env();
  backup_options = rocksdb_backup_engine_options_create(backups);
  engine = rocksdb_backup_engine_open_opts(backup_options, env, &error);
  check_error(error);
  require(engine != NULL, "open backup engine");
  rocksdb_backup_engine_create_new_backup_flush(engine, db, 1, &error);
  check_error(error);
  rocksdb_close(db);
  rocksdb_backup_engine_close(engine);
  engine = rocksdb_backup_engine_open_opts(backup_options, env, &error);
  check_error(error);
  require(engine != NULL, "reopen backup engine");
  restore_options = rocksdb_restore_options_create();
  rocksdb_backup_engine_restore_db_from_latest_backup(engine, restored, restored,
                                                     restore_options, &error);
  check_error(error);
  rocksdb_restore_options_destroy(restore_options);
  rocksdb_backup_engine_close(engine);
  rocksdb_backup_engine_options_destroy(backup_options);
  rocksdb_env_destroy(env);
  verify_current(restored);
  db = rocksdb_open(options, restored, &error);
  check_error(error);
  require(db != NULL, "open restored database");
  verify_value(db, reads);
  rocksdb_close(db);
  rocksdb_destroy_db(options, source, &error);
  check_error(error);
  rocksdb_destroy_db(options, restored, &error);
  check_error(error);
  rocksdb_readoptions_destroy(reads);
  rocksdb_writeoptions_destroy(writes);
  rocksdb_options_destroy(options);
  puts("PASS packaged Windows Unicode: exact paths, reopen, backup and restore");
  return EXIT_SUCCESS;
}
