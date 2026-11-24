import 'dart:collection';
import 'dart:math' as math;

import '../task_model.dart';

const _scanSliceSize = 1024;
const _mergeSliceSize = 4096;

/// Returns an immutable snapshot of tasks eligible for automatic estimates.
///
/// Tasks with a due date or scheduled date come first, then higher priorities
/// and task IDs break ties. The caller still checks runtime eligibility before
/// requesting an estimate.
List<TaskItem> rankAutomaticEstimateTasks(
  Iterable<TaskItem> tasks, {
  Set<String> recurringBaseIds = const {},
}) {
  final candidates = <TaskItem>[];
  final recurring = recurringBaseIds.isEmpty ? null : recurringBaseIds;
  for (final task in tasks) {
    if (_isEligible(task, recurring)) {
      candidates.add(task);
    }
  }
  candidates.sort(_compareCandidates);
  return UnmodifiableListView(candidates);
}

/// Ranks a workspace snapshot in bounded turns on the calling isolate.
///
/// The tasks and recurring base IDs must stay fixed until the future completes.
/// Returns null if [shouldCancel] becomes true between turns.
Future<List<TaskItem>?> rankAutomaticEstimateTasksCooperatively(
  Iterable<TaskItem> tasks, {
  Set<String> recurringBaseIds = const {},
  bool Function()? shouldCancel,
}) async {
  if (shouldCancel?.call() ?? false) return null;
  final recurring = recurringBaseIds.isEmpty ? null : recurringBaseIds;
  var runs = <List<TaskItem>>[];
  var run = <TaskItem>[];
  var scanned = 0;
  for (final task in tasks) {
    if (_isEligible(task, recurring)) {
      run.add(task);
    }
    if (++scanned == _scanSliceSize) {
      if (run.isNotEmpty) {
        runs.add(run..sort(_compareCandidates));
        run = [];
      }
      scanned = 0;
      if (await _yieldAndCheckCancellation(shouldCancel)) return null;
    }
  }
  if (run.isNotEmpty) runs.add(run..sort(_compareCandidates));
  if (runs.isEmpty) return const [];

  while (runs.length > 1) {
    final mergedRuns = <List<TaskItem>>[];
    for (var index = 0; index + 1 < runs.length; index += 2) {
      final merged = await _mergeRuns(
        runs[index],
        runs[index + 1],
        shouldCancel,
      );
      if (merged == null) return null;
      mergedRuns.add(merged);
    }
    if (runs.length.isOdd) mergedRuns.add(runs.last);
    runs = mergedRuns;
  }
  return UnmodifiableListView(runs.single);
}

bool _isEligible(TaskItem task, Set<String>? recurringBaseIds) =>
    !task.done &&
    task.estimatedMinutes == null &&
    task.schedulingHold == null &&
    task.title.length <= 300 &&
    (recurringBaseIds == null || !recurringBaseIds.contains(task.id));

Future<List<TaskItem>?> _mergeRuns(
  List<TaskItem> first,
  List<TaskItem> second,
  bool Function()? shouldCancel,
) async {
  final merged = List<TaskItem>.filled(
    first.length + second.length,
    first.first,
  );
  var left = 0;
  var right = 0;
  var written = 0;
  while (written < merged.length) {
    final end = math.min(written + _mergeSliceSize, merged.length);
    while (written < end) {
      if (right == second.length ||
          (left < first.length &&
              _compareCandidates(first[left], second[right]) <= 0)) {
        merged[written++] = first[left++];
      } else {
        merged[written++] = second[right++];
      }
    }
    if (await _yieldAndCheckCancellation(shouldCancel)) return null;
  }
  return merged;
}

Future<bool> _yieldAndCheckCancellation(bool Function()? shouldCancel) async {
  // Give frames and input a turn on the event queue between CPU slices.
  await Future<void>.delayed(Duration.zero);
  return shouldCancel?.call() ?? false;
}

int _compareCandidates(TaskItem first, TaskItem second) {
  final firstDate = first.dueAt ?? first.date;
  final secondDate = second.dueAt ?? second.date;
  if (firstDate == null) {
    if (secondDate != null) return 1;
  } else {
    if (secondDate == null) return -1;
    final order = firstDate.compareTo(secondDate);
    if (order != 0) return order;
  }
  final priority =
      (second.priority ?? TaskPriority.normal).index -
      (first.priority ?? TaskPriority.normal).index;
  return priority == 0 ? first.id.compareTo(second.id) : priority;
}
