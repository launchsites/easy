import 'dart:convert';

import 'contracts.dart';
import 'snapshot_codec.dart';

const _maximumSelectionCount = 1000;

const _workspaceCollections = {
  WorkspaceHistoryRecordKind.task: 'tasks',
  WorkspaceHistoryRecordKind.event: 'events',
  WorkspaceHistoryRecordKind.note: 'notes',
  WorkspaceHistoryRecordKind.capture: 'captures',
};

const _sectionCollections = {
  WorkspaceHistoryRecordKind.meal: (
    section: 'nutrition',
    list: 'meals',
    sibling: 'foods',
  ),
  WorkspaceHistoryRecordKind.food: (
    section: 'nutrition',
    list: 'foods',
    sibling: 'meals',
  ),
  WorkspaceHistoryRecordKind.activity: (
    section: 'activities',
    list: 'records',
    sibling: 'routines',
  ),
  WorkspaceHistoryRecordKind.routine: (
    section: 'activities',
    list: 'routines',
    sibling: 'records',
  ),
};

WorkspaceHistoryDiff diffWorkspaceHistory({
  required WorkspaceRevision current,
  required WorkspaceRevision source,
  required int offset,
  required int limit,
}) {
  if (offset < 0 || limit < 1 || limit > 500) {
    throw const WorkspaceStoreException(
      'Choose a history page of 1 to 500 changes.',
    );
  }
  final now = _SnapshotViews(current.snapshot);
  final then = _SnapshotViews(source.snapshot);
  final page = <WorkspaceHistoryRecordChange>[];
  var total = 0;
  for (final kind in WorkspaceHistoryRecordKind.values) {
    if (now.sharesCollection(then, kind)) continue;
    final active = now.records(kind);
    final archived = then.records(kind);
    final ids = {...active.keys, ...archived.keys}.toList()..sort();
    for (final id in ids) {
      final change = _change((kind: kind, id: id), active[id], archived[id]);
      if (change == null) continue;
      if (total++ >= offset && page.length < limit) page.add(change);
    }
  }
  return WorkspaceHistoryDiff(
    sourceRevision: source.revision,
    expectedRevision: current.revision,
    totalChanges: total,
    changes: List.unmodifiable(page),
  );
}

WorkspaceHistorySelectionPreview previewWorkspaceHistorySelection({
  required WorkspaceRevision current,
  required WorkspaceRevision source,
  required Set<WorkspaceHistoryRecordKey> selected,
}) {
  if (selected.isEmpty || selected.length > _maximumSelectionCount) {
    throw const WorkspaceStoreException('Select 1 to 1000 records to restore.');
  }
  final now = _SnapshotViews(current.snapshot);
  final then = _SnapshotViews(source.snapshot);
  final changes = <WorkspaceHistoryRecordChange>[];
  var currentWorkspace = now.workspace;
  var sessions = current.snapshot.gymSessionJson;
  var plans = current.snapshot.workoutPlanJson;

  final kinds = selected.map((key) => key.kind).toSet();
  for (final kind in WorkspaceHistoryRecordKind.values.where(kinds.contains)) {
    final active = now.records(kind);
    final archived = then.records(kind);
    final result = Map.of(active);
    for (final key in selected.where((key) => key.kind == kind)) {
      final before = archived[key.id];
      final change = _change(key, active[key.id], before);
      if (change == null) {
        throw const WorkspaceStoreException(
          'A selected record has no change to restore.',
        );
      }
      changes.add(change);
      if (before == null) {
        result.remove(key.id);
      } else {
        result[key.id] = before;
      }
    }
    switch (kind) {
      case WorkspaceHistoryRecordKind.gymSession:
        sessions = result.values.cast<String>().toList(growable: false);
      case WorkspaceHistoryRecordKind.workoutPlan:
        plans = result.values.cast<String>().toList(growable: false);
      default:
        final values = result.values.toList(growable: false);
        currentWorkspace = _replaceCollection(currentWorkspace, kind, values);
    }
  }

  if (!identical(currentWorkspace, now.workspace)) {
    final before = _missingReferences(now.workspace);
    if (_missingReferences(currentWorkspace)
        .any((reference) => !before.contains(reference))) {
      throw const WorkspaceStoreException(
        'Include related tasks and events to restore their references.',
      );
    }
  }
  final updated = WorkspaceSnapshot(
    workspaceJson: identical(currentWorkspace, now.workspace)
        ? current.snapshot.workspaceJson
        : jsonEncode(currentWorkspace),
    gymSessionJson: sessions,
    workoutPlanJson: plans,
  );
  return WorkspaceHistorySelectionPreview(
    expectedRevision: current.revision,
    changes: List.unmodifiable(changes),
    backup: WorkspaceBackupPreview(
      snapshot: updated,
      sourceRevision: source.revision,
      counts: validateSnapshot(updated),
    ),
  );
}

Map<String, dynamic> _replaceCollection(
  Map<String, dynamic> workspace,
  WorkspaceHistoryRecordKind kind,
  List<Object> values,
) {
  final nested = _sectionCollections[kind];
  if (nested == null) {
    return {...workspace, _workspaceCollections[kind]!: values};
  }
  final current =
      (workspace[nested.section] as Map<String, dynamic>?) ??
      {'version': 1, nested.sibling: const []};
  return {
    ...workspace,
    nested.section: {...current, nested.list: values},
  };
}

WorkspaceHistoryRecordChange? _change(
  WorkspaceHistoryRecordKey key,
  Object? active,
  Object? archived,
) {
  if (_sameValue(active, archived)) return null;
  final record = _recordMap(archived ?? active!);
  final heading = record['title'] ?? record['name'] ?? record['text'];
  final title = heading is String && heading.isNotEmpty
      ? String.fromCharCodes(heading.runes.take(120))
      : key.kind == WorkspaceHistoryRecordKind.gymSession
      ? 'Gym session'
      : key.id;
  return WorkspaceHistoryRecordChange(
    key: key,
    title: title,
    reversion: switch ((active, archived)) {
      (null, _) => WorkspaceHistoryReversion.recoverMissing,
      (_, null) => WorkspaceHistoryReversion.removeAdded,
      _ => WorkspaceHistoryReversion.restorePrevious,
    },
  );
}

Map<String, dynamic> _recordMap(Object record) => record is String
    ? jsonObject(decodeJson(record, 'history record'), 'history record')
    : jsonObject(record, 'history record');

bool _sameValue(Object? a, Object? b) {
  if (a == b) return true;
  if (a is List && b is List && a.length == b.length) {
    for (var index = 0; index < a.length; index++) {
      if (!_sameValue(a[index], b[index])) return false;
    }
    return true;
  }
  return a is Map &&
      b is Map &&
      a.length == b.length &&
      a.entries.every(
        (entry) =>
            b.containsKey(entry.key) && _sameValue(entry.value, b[entry.key]),
      );
}

typedef _Reference = ({String type, String id, String target});

Set<_Reference> _missingReferences(Map<String, dynamic> workspace) {
  final tasks = (workspace['tasks'] as List).cast<Map<String, dynamic>>();
  final events = (workspace['events'] as List).cast<Map<String, dynamic>>();
  final ids = tasks.map((task) => task['id'] as String).toSet();
  final invalid = <_Reference>{};
  void check(String type, String id, String? target) {
    if (target != null &&
        (!ids.contains(target) || id == target && type != 'plannedTaskId')) {
      invalid.add((type: type, id: id, target: target));
    }
  }

  for (final task in tasks) {
    final id = task['id'] as String;
    check('parentId', id, task['parentId'] as String?);
    for (final other in task['prerequisiteIds'] as List? ?? const []) {
      check('prerequisiteIds', id, other as String);
    }
  }
  for (final event in events) {
    check(
      'plannedTaskId',
      event['id'] as String,
      event['plannedTaskId'] as String?,
    );
  }
  return invalid;
}

final class _SnapshotViews {
  _SnapshotViews(this.snapshot);

  final WorkspaceSnapshot snapshot;
  late final workspace = jsonObject(
    decodeJson(snapshot.workspaceJson, 'workspace'),
    'workspace',
  );

  bool sharesCollection(
    _SnapshotViews other,
    WorkspaceHistoryRecordKind kind,
  ) => switch (kind) {
    WorkspaceHistoryRecordKind.gymSession => _sameValue(
      snapshot.gymSessionJson,
      other.snapshot.gymSessionJson,
    ),
    WorkspaceHistoryRecordKind.workoutPlan => _sameValue(
      snapshot.workoutPlanJson,
      other.snapshot.workoutPlanJson,
    ),
    _ => snapshot.workspaceJson == other.snapshot.workspaceJson,
  };

  Map<String, Object> records(WorkspaceHistoryRecordKind kind) =>
      switch (kind) {
        WorkspaceHistoryRecordKind.gymSession => {
          for (final text in snapshot.gymSessionJson)
            DateTime.parse(stringField(_recordMap(text), 'startedAt'))
                    .toUtc()
                    .toIso8601String():
                text,
        },
        WorkspaceHistoryRecordKind.workoutPlan => {
          for (final text in snapshot.workoutPlanJson)
            stringField(_recordMap(text), 'id'): text,
        },
        _ => {
          for (final record in _workspaceList(kind))
            stringField(record as Map<String, dynamic>, 'id'): record,
        },
      };

  List<dynamic> _workspaceList(WorkspaceHistoryRecordKind kind) {
    final nested = _sectionCollections[kind];
    final parent = nested == null
        ? workspace
        : workspace[nested.section] as Map<String, dynamic>?;
    final key = nested?.list ?? _workspaceCollections[kind]!;
    return (parent?[key] as List<dynamic>?) ?? const [];
  }
}
