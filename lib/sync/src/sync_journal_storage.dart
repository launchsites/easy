import 'dart:typed_data';

const syncLedgerMaximumRows = 120000;
const syncLedgerMaximumBytes = 64 * 1024 * 1024;
const syncLedgerMaximumEntryBytes = 1024 * 1024 + 4096;
const syncLedgerHeadBytes = 60;

typedef SyncLedgerHead = ({int revision, int bytes, Uint8List auth});
typedef SyncLedgerEntry = ({int revision, Uint8List encrypted});

abstract interface class SyncLedger {
  SyncLedgerHead? readHead();
  void initialize(SyncLedgerHead head);
  List<SyncLedgerEntry> readPage({required int after, required int through});
  void append({
    required int expectedRevision,
    required SyncLedgerHead head,
    required Uint8List encrypted,
  });
  void close();
}
