import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sync_journal_storage.dart';
import 'sync_journal_types.dart';

final class SqliteSyncLedger implements SyncLedger {
  SqliteSyncLedger._(this._db);

  static const _applicationId = 0x45535953;
  static const _schemaVersion = 1;
  final Database _db;

  static SqliteSyncLedger open(String path) {
    if (path != ':memory:') File(path).parent.createSync(recursive: true);
    final database = sqlite3.open(path);
    final ledger = SqliteSyncLedger._(database);
    try {
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('PRAGMA trusted_schema = OFF');
      ledger._atomic(() {
        final applicationId = ledger._pragma('application_id');
        final version = ledger._pragma('user_version');
        if (applicationId == _applicationId && version == _schemaVersion) {
          return;
        }
        if (applicationId != 0 ||
            version != 0 ||
            database
                .select(
                  "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1",
                )
                .isNotEmpty) {
          throw const SyncJournalException(
            'Unsupported sync journal database.',
          );
        }
        database.execute('''
          CREATE TABLE sync_head (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND $syncLedgerMaximumRows),
            bytes INTEGER NOT NULL CHECK (bytes BETWEEN 0 AND $syncLedgerMaximumBytes),
            auth BLOB NOT NULL CHECK (length(auth) = $syncLedgerHeadBytes)
          ) STRICT;
          CREATE TABLE sync_entry (
            revision INTEGER PRIMARY KEY CHECK (revision BETWEEN 1 AND $syncLedgerMaximumRows),
            encrypted BLOB NOT NULL CHECK (length(encrypted) BETWEEN 29 AND $syncLedgerMaximumEntryBytes)
          ) STRICT;
          PRAGMA application_id = $_applicationId;
          PRAGMA user_version = $_schemaVersion;
        ''');
      });
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      return ledger;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  int _pragma(String name) => _db.select('PRAGMA $name').single[name] as int;

  T _atomic<T>(T Function() operation) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = operation();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  SyncLedgerHead? readHead() {
    final row = _db
        .select('SELECT revision, bytes, auth FROM sync_head WHERE id = 1')
        .firstOrNull;
    if (row == null) return null;
    return (
      revision: row['revision'] as int,
      bytes: row['bytes'] as int,
      auth: row['auth'] as Uint8List,
    );
  }

  @override
  void initialize(SyncLedgerHead head) => _atomic(() {
    if (readHead() != null) return;
    if (_db.select('SELECT revision FROM sync_entry LIMIT 1').isNotEmpty) {
      throw const SyncJournalException('The sync journal head is missing.');
    }
    _db.execute('INSERT INTO sync_head VALUES (1, 0, 0, ?)', [head.auth]);
  });

  @override
  List<SyncLedgerEntry> readPage({required int after, required int through}) =>
      [
        for (final row in _db.select(
          'SELECT revision, encrypted FROM sync_entry '
          'WHERE revision > ? AND revision <= ? ORDER BY revision LIMIT 8',
          [after, through],
        ))
          (
            revision: row['revision'] as int,
            encrypted: row['encrypted'] as Uint8List,
          ),
      ];

  @override
  void append({
    required int expectedRevision,
    required SyncLedgerHead head,
    required Uint8List encrypted,
  }) => _atomic(() {
    final current = readHead();
    if (current == null) {
      throw const SyncJournalException('The sync journal head is missing.');
    }
    if (current.revision != expectedRevision) {
      throw SyncJournalRevisionConflict(expectedRevision, current.revision);
    }
    _db.execute('INSERT INTO sync_entry VALUES (?, ?)', [
      head.revision,
      encrypted,
    ]);
    _db.execute(
      'UPDATE sync_head SET revision = ?, bytes = ?, auth = ? WHERE id = 1',
      [head.revision, head.bytes, head.auth],
    );
  });

  @override
  void close() => _db.close();
}
