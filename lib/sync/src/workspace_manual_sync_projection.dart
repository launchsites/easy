part of '../workspace_manual_sync.dart';

const _maximumOutgoingReviewRows = 120;

typedef _ProjectionRow = ({
  ManualSyncProjectionRecord review,
  WorkspaceSyncRecord? replacement,
});

class _WorkspaceIndex {
  _WorkspaceIndex(WorkspaceSnapshot snapshot)
    : document = jsonDecode(snapshot.workspaceJson) as Map<String, dynamic> {
    final taskSeries = _seriesIds(document['recurringTasks']);
    final eventSeries = _seriesIds(document['recurringEvents']);
    final copies = document['appleCalendarCopies'];
    _excluded = {
      SyncRecordKind.task: taskSeries,
      SyncRecordKind.calendarEvent:
          eventSeries == null || (copies != null && copies is! Map)
          ? null
          : {
              ...eventSeries,
              if (copies is Map) ...copies.keys.whereType<String>(),
            },
    };
    for (final collection in workspaceRecordCollections.entries) {
      for (final entry in document[collection.value] as List<dynamic>) {
        final record = entry as Map<String, dynamic>;
        final id = record['id'] as String;
        records[(kind: collection.key, id: id)] = record;
      }
    }
  }

  final Map<String, dynamic> document;
  final records = <SyncRecordKey, Map<String, dynamic>>{};
  final _parsed = <SyncRecordKey, WorkspaceSyncRecord?>{};
  late final Map<SyncRecordKind, Set<String>?> _excluded;

  bool supports(SyncRecordKey key) =>
      workspaceRecordCollections.containsKey(key.kind) &&
      (_excluded[key.kind]?.contains(key.id) == false ||
          !_excluded.containsKey(key.kind)) &&
      !key.id.startsWith('apple:') &&
      !key.id.startsWith('ics:');

  WorkspaceSyncRecord? read(SyncRecordKey key) {
    if (!supports(key)) return null;
    return _parsed.putIfAbsent(key, () {
      final json = records[key];
      if (json == null) return null;
      try {
        return WorkspaceSyncRecord.fromSaved(key.kind, json);
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      } on ArgumentError {
        return null;
      }
    });
  }
}

Set<String>? _seriesIds(Object? section) {
  if (section == null) return {};
  if (section is! List || section.length > 500) return null;
  final ids = <String>{};
  for (final row in section) {
    if (row is! Map || row['id'] is! String || !ids.add(row['id'] as String)) {
      return null;
    }
  }
  return ids;
}

WorkspaceSyncRecord? _readJournalRecord(SyncRecord record) {
  try {
    return WorkspaceSyncRecord.fromJournal(record);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  } on ArgumentError {
    return null;
  }
}

({List<WorkspaceSyncRecord> records, bool hasMore}) _reviewOutgoing(
  (WorkspaceSnapshot, String) request,
) {
  final (snapshot, query) = request;
  final index = _WorkspaceIndex(snapshot);
  final search = query.trim().toLowerCase();
  final records = <WorkspaceSyncRecord>[];
  for (final key in index.records.keys) {
    if (search.isNotEmpty) {
      final row = index.records[key]!;
      if (!['title', 'category', 'body', 'notes', 'description', 'location']
          .map((field) => row[field])
          .whereType<String>()
          .any((value) => value.toLowerCase().contains(search))) {
        continue;
      }
    }
    final record = index.read(key);
    if (record == null ||
        !record.references.every((target) => index.read(target) != null)) {
      continue;
    }
    if (records.length == _maximumOutgoingReviewRows) {
      return (records: records, hasMore: true);
    }
    records.add(record);
  }
  return (records: records, hasMore: false);
}

List<_ProjectionRow> _reviewIncoming(
  (WorkspaceSnapshot, List<SyncRecordChange>) request,
) {
  final (snapshot, changes) = request;
  final index = _WorkspaceIndex(snapshot);
  final rows = <_ProjectionRow>[];
  final seen = <SyncRecordKey>{};
  for (final change in changes) {
    final key = change.key;
    if (!seen.add(key)) continue;
    final after = change.after;
    if (after == null) continue;
    final fromPeer = _readJournalRecord(after);
    final local = index.read(key);
    final saved = index.records[key];
    final title = local?.title ?? fromPeer?.title ?? 'Unavailable record';

    void blocked(String reason) {
      rows.add((
        review: ManualSyncProjectionRecord(
          key: key,
          title: title,
          details: reason,
          action: ManualSyncProjectionAction.resolveConflict,
          localDetails: local?.details,
          incomingDetails: fromPeer?.details,
        ),
        replacement: null,
      ));
    }

    if (!index.supports(key) ||
        fromPeer == null ||
        (saved != null && local == null)) {
      blocked('This record falls outside local task, event and note sync.');
      continue;
    }
    if (after.hasConflicts) {
      blocked(
        'Review the competing journal changes before applying this record.',
      );
      continue;
    }
    final removing = after.state == SyncRecordState.deleted;
    if (removing && local == null) continue;
    if (removing && local?.canonical != fromPeer.canonical) {
      blocked(
        'This device has edited the record since the version being removed.',
      );
      continue;
    }
    if (!removing && local?.canonical == fromPeer.canonical) continue;
    rows.add((
      review: ManualSyncProjectionRecord(
        key: key,
        title: fromPeer.title,
        action: removing
            ? ManualSyncProjectionAction.remove
            : local == null
            ? ManualSyncProjectionAction.add
            : ManualSyncProjectionAction.update,
        details: switch ((removing, local != null)) {
          (true, _) => 'Remove this record from the local workspace.',
          (false, true) =>
            'Replace the saved local version with the incoming version.',
          (false, false) => 'Add this record to the local workspace.',
        },
        localDetails: local == null
            ? null
            : '${local.title} · ${local.details}',
        incomingDetails: removing ? null : fromPeer.details,
      ),
      replacement: removing ? null : fromPeer,
    ));
  }
  return rows;
}

WorkspaceBackupPreview _projectRecords(
  (WorkspaceRevision, List<_ProjectionRow>) request,
) {
  final (base, rows) = request;
  final index = _WorkspaceIndex(base.snapshot);
  final replacements = {
    for (final row in rows) row.review.key: row.replacement,
  };
  final removals = {
    for (final row in rows)
      if (row.replacement == null) row.review.key,
  };
  final updated = {...index.records};
  for (final entry in replacements.entries) {
    if (entry.value case final record?) {
      updated[entry.key] = Map<String, dynamic>.of(record.toSaved());
    } else {
      updated.remove(entry.key);
    }
  }
  for (final replacement
      in replacements.values.whereType<WorkspaceSyncRecord>()) {
    if (replacement.references.any(
      (key) =>
          !index.supports(key) ||
          !(replacements[key] != null ||
              (updated.containsKey(key) && index.read(key) != null)),
    )) {
      throw const SyncJournalException(
        'Select the linked task or event too, or add it to this device first.',
      );
    }
  }
  if (removals.isNotEmpty &&
      updated.entries.any(
        (entry) => _savedReferences(
          entry.key.kind,
          entry.value,
        ).any(removals.contains),
      )) {
    throw const SyncJournalException(
      'A record still links to a selected removal. Keep it or review its linked records together.',
    );
  }

  final updatedTasks = replacements.values
      .whereType<WorkspaceSyncRecord>()
      .where((record) => record.key.kind == SyncRecordKind.task)
      .toList();
  if (updatedTasks.isNotEmpty) {
    final tasks = [
      for (final entry in updated.entries)
        if (entry.key.kind == SyncRecordKind.task)
          TaskItem(
            id: entry.key.id,
            title: entry.value['title'] as String,
            category: entry.value['category'] as String,
            parentId: entry.value['parentId'] as String?,
            prerequisiteIds:
                (entry.value['prerequisiteIds'] as List?)
                    ?.whereType<String>()
                    .toList() ??
                const [],
          ),
    ];
    final hierarchy = TaskHierarchy(tasks);
    final dependencies = TaskDependencyGraph(tasks);
    for (final record in updatedTasks) {
      final json = updated[record.key]!;
      final parentIssue = hierarchy.parentIssue(
        record.key.id,
        json['parentId'] as String?,
      );
      final prerequisiteIssue = dependencies.prerequisiteIssue(
        record.key.id,
        (json['prerequisiteIds'] as List?)?.cast<String>() ?? const [],
      );
      if (parentIssue != null || prerequisiteIssue != null) {
        throw SyncJournalException(
          parentIssue?.message ?? prerequisiteIssue!.message,
        );
      }
    }
  }

  final document = index.document;
  for (final collection in workspaceRecordCollections.entries) {
    if (replacements.keys.any((key) => key.kind == collection.key)) {
      document[collection.value] = [
        for (final entry in updated.entries)
          if (entry.key.kind == collection.key) entry.value,
      ];
    }
  }
  final snapshot = WorkspaceSnapshot(
    workspaceJson: jsonEncode(document),
    gymSessionJson: base.snapshot.gymSessionJson,
    workoutPlanJson: base.snapshot.workoutPlanJson,
  );
  return WorkspaceBackupPreview(
    snapshot: snapshot,
    sourceRevision: base.revision,
    counts: validateSnapshot(snapshot),
  );
}

Iterable<SyncRecordKey> _savedReferences(
  SyncRecordKind kind,
  Map<String, dynamic> row,
) sync* {
  switch (kind) {
    case SyncRecordKind.task:
      if (row['parentId'] case final String parent) {
        yield (kind: SyncRecordKind.task, id: parent);
      }
      if (row['prerequisiteIds'] case final List prerequisites) {
        for (final id in prerequisites.whereType<String>()) {
          yield (kind: SyncRecordKind.task, id: id);
        }
      }
    case SyncRecordKind.calendarEvent:
      if (row['plannedTaskId'] case final String task) {
        yield (kind: SyncRecordKind.task, id: task);
      }
    case SyncRecordKind.note:
      if (row['links'] case final List links) {
        for (final link in links.whereType<Map>()) {
          if (link['id'] case final String id) {
            final target = switch (link['kind']) {
              'task' => SyncRecordKind.task,
              'event' => SyncRecordKind.calendarEvent,
              _ => null,
            };
            if (target != null) yield (kind: target, id: id);
          }
        }
      }
    default:
      break;
  }
}
