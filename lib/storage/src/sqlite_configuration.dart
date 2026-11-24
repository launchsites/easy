import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Switching a new SQLite file into WAL can briefly contend with another
/// opener. Established WAL databases skip the locking mode-change command.
void configureSqliteWal(Database database) {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      final current = database
          .select('PRAGMA journal_mode')
          .single
          .values
          .single;
      if (current == 'wal' || current == 'memory') return;
      final changed = database
          .select('PRAGMA journal_mode = WAL')
          .single
          .values
          .single;
      if (changed == 'wal') return;
    } on SqliteException catch (error) {
      // SQLite can return BUSY immediately during a journal-mode transition.
      if (error.resultCode != 5 && error.resultCode != 6 || attempt == 9) {
        rethrow;
      }
    }
    sleep(Duration(milliseconds: 8 << (attempt < 5 ? attempt : 5)));
  }
  throw StateError('SQLite could not enable its write-ahead journal.');
}
