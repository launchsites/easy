import 'dart:typed_data';

/// A logical snapshot of the persisted workspace documents.
///
/// The current app's record codecs own these JSON shapes. Keeping the original
/// JSON through migration and recovery also preserves fields from newer codecs.
final class WorkspaceSnapshot {
  WorkspaceSnapshot({
    required this.workspaceJson,
    required List<String> gymSessionJson,
    required List<String> workoutPlanJson,
  }) : gymSessionJson = List.unmodifiable(gymSessionJson),
       workoutPlanJson = List.unmodifiable(workoutPlanJson);

  final String workspaceJson;
  final List<String> gymSessionJson;
  final List<String> workoutPlanJson;
}

final class WorkspaceRevision {
  const WorkspaceRevision({required this.revision, required this.snapshot});

  final int revision;
  final WorkspaceSnapshot snapshot;
}

sealed class WorkspaceMutation {
  const WorkspaceMutation();

  const factory WorkspaceMutation.workspace(String json) = SetWorkspace;
  factory WorkspaceMutation.gymSessions(List<String> json) = SetGymSessions;
  factory WorkspaceMutation.workoutPlans(List<String> json) = SetWorkoutPlans;
  const factory WorkspaceMutation.replace(WorkspaceSnapshot snapshot) =
      ReplaceWorkspace;

  WorkspaceSnapshot apply(WorkspaceSnapshot current);
}

final class SetWorkspace extends WorkspaceMutation {
  const SetWorkspace(this.json);

  final String json;

  @override
  WorkspaceSnapshot apply(WorkspaceSnapshot current) => WorkspaceSnapshot(
    workspaceJson: json,
    gymSessionJson: current.gymSessionJson,
    workoutPlanJson: current.workoutPlanJson,
  );
}

final class SetGymSessions extends WorkspaceMutation {
  SetGymSessions(List<String> json) : json = List.unmodifiable(json);

  final List<String> json;

  @override
  WorkspaceSnapshot apply(WorkspaceSnapshot current) => WorkspaceSnapshot(
    workspaceJson: current.workspaceJson,
    gymSessionJson: json,
    workoutPlanJson: current.workoutPlanJson,
  );
}

final class SetWorkoutPlans extends WorkspaceMutation {
  SetWorkoutPlans(List<String> json) : json = List.unmodifiable(json);

  final List<String> json;

  @override
  WorkspaceSnapshot apply(WorkspaceSnapshot current) => WorkspaceSnapshot(
    workspaceJson: current.workspaceJson,
    gymSessionJson: current.gymSessionJson,
    workoutPlanJson: json,
  );
}

final class ReplaceWorkspace extends WorkspaceMutation {
  const ReplaceWorkspace(this.snapshot);

  final WorkspaceSnapshot snapshot;

  @override
  WorkspaceSnapshot apply(WorkspaceSnapshot current) => snapshot;
}

/// What a recovery point would replace, without applying any writes.
final class WorkspaceBackupPreview {
  const WorkspaceBackupPreview({
    required this.snapshot,
    required this.sourceRevision,
    required this.counts,
  });

  final WorkspaceSnapshot snapshot;
  final int sourceRevision;
  final WorkspaceRecordCounts counts;
}

final class WorkspaceRecordCounts {
  const WorkspaceRecordCounts({
    required this.events,
    required this.tasks,
    required this.notes,
    required this.gymSessions,
    required this.workoutPlans,
    this.captures = 0,
    this.meals = 0,
    this.foods = 0,
    this.activities = 0,
    this.routines = 0,
  });

  final int events;
  final int tasks;
  final int notes;
  final int gymSessions;
  final int workoutPlans;
  final int captures;
  final int meals;
  final int foods;
  final int activities;
  final int routines;
}

final class WorkspaceStoreException implements Exception {
  const WorkspaceStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class WorkspaceRevisionConflict implements Exception {
  const WorkspaceRevisionConflict({
    required this.expected,
    required this.actual,
  });

  final int expected;
  final int actual;

  @override
  String toString() =>
      'The workspace changed. Expected revision $expected, '
      'but the current revision is $actual.';
}

abstract interface class WorkspaceStore {
  Future<WorkspaceRevision> read();

  /// Applies a logical command. An optional revision prevents stale overwrite.
  ///
  /// Supplying an operation ID makes retrying the same command idempotent.
  Future<WorkspaceRevision> save(
    WorkspaceMutation mutation, {
    int? expectedRevision,
    String? operationId,
  });

  Future<Uint8List> createBackup();

  Future<WorkspaceBackupPreview> previewBackup(Uint8List data);

  /// Stores the previous state as a recovery point in the same transaction.
  Future<WorkspaceRevision> restoreBackup(
    WorkspaceBackupPreview preview, {
    required int expectedRevision,
  });

  Future<Uint8List?> readRecoveryBackup();

  Future<void> close();
}

final class WorkspaceHistoryPoint {
  const WorkspaceHistoryPoint({
    required this.revision,
    required this.recordedAt,
    required this.kind,
    this.name,
  });

  final int revision;
  final DateTime recordedAt;
  final String kind;
  final String? name;
}

enum WorkspaceHistoryRecordKind {
  task,
  event,
  note,
  capture,
  gymSession,
  workoutPlan,
  meal,
  food,
  activity,
  routine,
}

typedef WorkspaceHistoryRecordKey = ({
  WorkspaceHistoryRecordKind kind,
  String id,
});

enum WorkspaceHistoryReversion { recoverMissing, restorePrevious, removeAdded }

final class WorkspaceHistoryRecordChange {
  const WorkspaceHistoryRecordChange({
    required this.key,
    required this.title,
    required this.reversion,
  });

  final WorkspaceHistoryRecordKey key;
  final String title;
  final WorkspaceHistoryReversion reversion;
}

final class WorkspaceHistoryDiff {
  const WorkspaceHistoryDiff({
    required this.sourceRevision,
    required this.expectedRevision,
    required this.totalChanges,
    required this.changes,
  });

  final int sourceRevision;
  final int expectedRevision;
  final int totalChanges;
  final List<WorkspaceHistoryRecordChange> changes;
}

final class WorkspaceHistorySelectionPreview {
  const WorkspaceHistorySelectionPreview({
    required this.expectedRevision,
    required this.backup,
    required this.changes,
  });

  final int expectedRevision;
  final WorkspaceBackupPreview backup;
  final List<WorkspaceHistoryRecordChange> changes;
}

/// Available from native workspace stores that retain reconstructable history.
abstract interface class WorkspaceHistoryStore implements WorkspaceStore {
  Future<List<WorkspaceHistoryPoint>> listHistory();

  Future<WorkspaceHistoryPoint> nameHistoryPoint(
    String name, {
    required int expectedRevision,
  });

  Future<void> removeHistoryPointName(
    int revision, {
    required int expectedRevision,
  });

  Future<WorkspaceBackupPreview> previewHistoryPoint(int revision);

  Future<WorkspaceHistoryDiff> diffHistoryPoint(
    int sourceRevision, {
    int offset = 0,
    int limit = 100,
    int? expectedRevision,
  });

  Future<WorkspaceHistorySelectionPreview> previewHistorySelection({
    required int sourceRevision,
    required int expectedRevision,
    required Set<WorkspaceHistoryRecordKey> records,
  });
}
