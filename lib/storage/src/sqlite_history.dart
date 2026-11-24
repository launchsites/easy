import 'package:sqlite3/sqlite3.dart';

import 'contracts.dart';
import 'snapshot_codec.dart';
import 'sqlite_documents.dart';

const workspaceRecentHistoryLimit = 6;
const workspaceNamedHistoryLimit = 16;
const workspaceAutomaticHistoryBytes = 96 * 1024 * 1024;
const workspaceNamedHistoryBytes = 192 * 1024 * 1024;
const _maximumAutomaticPoints = 144;
final _invalidName = RegExp(r'[\x00-\x1f\x7f]');

final class SqliteWorkspaceHistory {
  SqliteWorkspaceHistory(this.database, this.documents);

  final Database database;
  final SqliteDocuments documents;

  static void migrate(Database database) => database.execute('''
    CREATE TABLE named_history (
      revision INTEGER PRIMARY KEY REFERENCES revisions(revision),
      name TEXT NOT NULL UNIQUE COLLATE NOCASE
    ) STRICT;
  ''');

  List<WorkspaceHistoryPoint> list() => List.unmodifiable([
    for (final row in database.select('''
      SELECT r.revision, r.kind, r.created_at, names.name
      FROM revisions r LEFT JOIN named_history names ON names.revision = r.revision
      ORDER BY r.revision DESC
    '''))
      _point(row),
  ]);

  WorkspaceHistoryPoint namePoint(String name, int revision) {
    final label = name.trim();
    if (label.isEmpty || label.length > 80 || _invalidName.hasMatch(label)) {
      throw const WorkspaceStoreException(
        'Use a checkpoint name of 1 to 80 characters.',
      );
    }
    final current = database
        .select(
          '''
      SELECT r.revision, r.kind, r.created_at, names.name
      FROM revisions r LEFT JOIN named_history names ON names.revision = r.revision
      WHERE r.revision = ?
    ''',
          [revision],
        )
        .single;
    if (current['name'] == label) return _point(current);
    if (database.select(
      'SELECT 1 FROM named_history WHERE name = ? AND revision <> ?',
      [label, revision],
    ).isNotEmpty) {
      throw const WorkspaceStoreException(
        'A checkpoint already has that name.',
      );
    }
    final protected = _revisions()
        .where(
          (item) => item.point.name != null || item.point.revision == revision,
        )
        .toList(growable: false);
    final sizes = <String, int>{};
    for (final point in protected) {
      for (final document in point.documents) {
        sizes[document.digest] = document.bytes;
      }
    }
    if (protected.length > workspaceNamedHistoryLimit ||
        sizes.values.fold(0, (total, bytes) => total + bytes) >
            workspaceNamedHistoryBytes) {
      throw const WorkspaceStoreException(
        'Named checkpoints reached their storage limit.',
      );
    }
    database.execute(
      '''
      INSERT INTO named_history(revision, name) VALUES (?, ?)
      ON CONFLICT(revision) DO UPDATE SET name = excluded.name
    ''',
      [revision, label],
    );
    return WorkspaceHistoryPoint(
      revision: revision,
      recordedAt: _point(current).recordedAt,
      kind: current['kind'] as String,
      name: label,
    );
  }

  void removeName(int revision) => database.execute(
    'DELETE FROM named_history WHERE revision = ?',
    [revision],
  );

  /// Chooses the newest committed revision in each UTC time bucket. Estimates
  /// conservatively charge each referenced document once across retained
  /// points, even if their physical compressed chunks share space.
  void prune(DateTime now) {
    final points = _revisions();
    if (points.length <= 1) return;
    final discarded = <int>[];
    final seenBuckets = <String>{};
    final retainedDocuments = <String>{};
    var automaticBytes = 0;
    var automaticCount = 0;
    for (var index = 0; index < points.length; index++) {
      final revision = points[index];
      final point = revision.point;
      final tier = _bucket(point.recordedAt, now);
      if (point.name != null) {
        if (tier != null) seenBuckets.add(tier);
        continue;
      }
      final additional = <String, int>{
        for (final document in revision.documents)
          if (!retainedDocuments.contains(document.digest))
            document.digest: document.bytes,
      };
      final extra = additional.values.fold(0, (total, bytes) => total + bytes);
      final recent = index < workspaceRecentHistoryLimit;
      final timePoint = tier != null && !seenBuckets.contains(tier);
      if (index == 0 ||
          (recent || timePoint) &&
              automaticCount < _maximumAutomaticPoints &&
              extra <= workspaceAutomaticHistoryBytes - automaticBytes) {
        retainedDocuments.addAll(additional.keys);
        automaticBytes += extra;
        automaticCount++;
        if (tier != null) seenBuckets.add(tier);
      } else {
        discarded.add(point.revision);
      }
    }
    if (discarded.isEmpty) return;
    final remove = database.prepare('DELETE FROM revisions WHERE revision = ?');
    try {
      for (final revision in discarded) {
        remove.execute([revision]);
      }
    } finally {
      remove.close();
    }
    documents.removeUnused();
  }

  List<_Revision> _revisions() => [
    for (final row in database.select('''
      SELECT r.revision, r.kind, r.created_at, names.name,
             r.workspace, r.gym_sessions, r.workout_plans,
             CASE w.chunked WHEN 1 THEN w.stored_bytes ELSE length(CAST(w.body AS BLOB)) END AS workspace_bytes,
             CASE s.chunked WHEN 1 THEN s.stored_bytes ELSE length(CAST(s.body AS BLOB)) END AS session_bytes,
             CASE p.chunked WHEN 1 THEN p.stored_bytes ELSE length(CAST(p.body AS BLOB)) END AS plan_bytes
      FROM revisions r
      LEFT JOIN named_history names ON names.revision = r.revision
      LEFT JOIN documents w ON w.digest = r.workspace
      LEFT JOIN documents s ON s.digest = r.gym_sessions
      LEFT JOIN documents p ON p.digest = r.workout_plans
      ORDER BY r.revision DESC
    '''))
      (
        point: _point(row),
        documents: [
          (
            digest: row['workspace'] as String,
            bytes: _validSize(row['workspace_bytes']),
          ),
          (
            digest: row['gym_sessions'] as String,
            bytes: _validSize(row['session_bytes']),
          ),
          (
            digest: row['workout_plans'] as String,
            bytes: _validSize(row['plan_bytes']),
          ),
        ],
      ),
  ];
}

typedef _Revision = ({
  WorkspaceHistoryPoint point,
  List<({String digest, int bytes})> documents,
});

WorkspaceHistoryPoint _point(Row row) {
  final recordedAt = DateTime.tryParse(row['created_at'] as String)?.toUtc();
  if (recordedAt == null) {
    throw const WorkspaceStoreException(
      'A workspace checkpoint has an invalid date.',
    );
  }
  return WorkspaceHistoryPoint(
    revision: positiveRevision(row['revision']),
    kind: row['kind'] as String,
    name: row['name'] as String?,
    recordedAt: recordedAt,
  );
}

int _validSize(Object? size) {
  if (size is! int || size < 1) {
    throw const WorkspaceStoreException(
      'A workspace checkpoint refers to invalid data.',
    );
  }
  return size;
}

String? _bucket(DateTime timestamp, DateTime now) {
  final age = now.difference(timestamp);
  final width = switch (age.inHours) {
    < 1 => const Duration(minutes: 5),
    < 24 => const Duration(hours: 1),
    < 168 => const Duration(hours: 12),
    < 744 => const Duration(days: 1),
    < 8784 => const Duration(days: 7),
    _ => null,
  };
  if (width == null) return null;
  final bucket = timestamp.millisecondsSinceEpoch ~/ width.inMilliseconds;
  return '${width.inMinutes}/$bucket';
}
