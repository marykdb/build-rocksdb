#include <rocksdb/c.h>
#include <rocksdb/options.h>
#include <rocksdb/utilities/transaction.h>
#include <rocksdb/utilities/transaction_db.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
void check(char*& error) {
  if (error) {
    std::fprintf(stderr, "%s\n", error);
    std::exit(2);
  }
}
int main(int argc, char** argv) {
  if (argc < 3) return 2;
  const int policy = argc > 3 ? std::atoi(argv[3]) : 0;
  if (std::strcmp(argv[1], "recover-delete") == 0) {
    rocksdb::Options options;
    options.create_if_missing = true;
    options.allow_2pc = true;
    rocksdb::TransactionDBOptions dbo;
    dbo.write_policy = static_cast<rocksdb::TxnDBWritePolicy>(policy);
    rocksdb::TransactionDB* db = nullptr;
    auto status = rocksdb::TransactionDB::Open(options, dbo, argv[2], &db);
    if (!status.ok()) {
      std::fprintf(stderr, "%s\n", status.ToString().c_str());
      return 2;
    }
    std::vector<rocksdb::Transaction*> transactions;
    db->GetAllPreparedTransactions(&transactions);
    if (transactions.size() != 1) return 2;
    for (auto* tx : transactions) {
      status = tx->Commit();
      if (!status.ok()) {
        std::fprintf(stderr, "%s\n", status.ToString().c_str());
        return 2;
      }
      delete tx;
    }
    std::string value;
    status = db->Get(rocksdb::ReadOptions(), "key", &value);
    if (!status.ok() || value != std::string(4 * 1024 * 1024, 'x')) return 2;
    delete db;
    return 0;
  }
  char* error = nullptr;
  auto* options = rocksdb_options_create();
  rocksdb_options_set_create_if_missing(options, 1);
  rocksdb_options_set_allow_2pc(options, 1);
  auto* dbo = rocksdb_transactiondb_options_create();
  rocksdb_transactiondb_options_set_write_policy(dbo, policy);
  auto* db = rocksdb_transactiondb_open(options, dbo, argv[2], &error);
  check(error);
  if (std::strcmp(argv[1], "prepare") == 0) {
    auto* wo = rocksdb_writeoptions_create();
    rocksdb_writeoptions_set_sync(wo, 1);
    auto* txo = rocksdb_transaction_options_create();
    auto* tx = rocksdb_transaction_begin(db, wo, txo, nullptr);
    rocksdb_transaction_set_name(tx, "recovered", 9, &error);
    check(error);
    std::string value(4 * 1024 * 1024, 'x');
    rocksdb_transaction_put(tx, "key", 3, value.data(), value.size(), &error);
    check(error);
    rocksdb_transaction_prepare(tx, &error);
    check(error);
    std::_Exit(0);
  }
  size_t count = 0;
  auto** transactions =
      rocksdb_transactiondb_get_prepared_transactions(db, &count);
  std::fprintf(stderr, "recovered transactions: %zu\n", count);
  if (count != 1) return 2;
  for (size_t i = 0; i < count; i++) {
    if (std::strcmp(argv[1], "recover-rollback") == 0) {
      rocksdb_transaction_rollback(transactions[i], &error);
      check(error);
    } else if (std::strcmp(argv[1], "pending") != 0) {
      rocksdb_transaction_commit(transactions[i], &error);
      check(error);
    }
    rocksdb_transaction_destroy(transactions[i]);
  }
  rocksdb_free(transactions);
  auto* ro = rocksdb_readoptions_create();
  size_t size = 0;
  char* value = rocksdb_transactiondb_get(db, ro, "key", 3, &size, &error);
  check(error);
  const bool committed = std::strcmp(argv[1], "recover") == 0;
  if (committed) {
    if (value == nullptr || size != 4 * 1024 * 1024) return 2;
    for (size_t i = 0; i < size; ++i)
      if (value[i] != 'x') return 2;
  } else if (value != nullptr)
    return 2;
  rocksdb_free(value);
  rocksdb_readoptions_destroy(ro);
  rocksdb_transactiondb_close(db);
  rocksdb_transactiondb_options_destroy(dbo);
  rocksdb_options_destroy(options);
}
