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
  });

  final int events;
  final int tasks;
  final int notes;
  final int gymSessions;
  final int workoutPlans;
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
