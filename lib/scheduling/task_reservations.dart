import '../calendar_page.dart';
import '../task_model.dart';

final class TaskReservationEvidence {
  const TaskReservationEvidence._({
    required this.minutes,
    required this.lastEnd,
    required this.coveredAt,
    required this.requiresReview,
  });

  /// Counts existing owned blocks once, even if they need review.
  final int minutes;
  final DateTime lastEnd;

  /// The estimate is covered by current, usable blocks from this instant.
  final DateTime? coveredAt;
  final bool requiresReview;
}

final class TaskReservationReview {
  TaskReservationReview._(
    Map<String, DateTime?> completedAt,
    Map<String, TaskReservationEvidence> reservations,
  ) : completedAt = Map.unmodifiable(completedAt),
      reservations = Map.unmodifiable(reservations);

  /// A legacy checked task has a trusted state and an unknown instant.
  final Map<String, DateTime?> completedAt;
  final Map<String, TaskReservationEvidence> reservations;

  bool satisfiesAt(String id, DateTime instant) {
    if (completedAt.containsKey(id)) {
      return !(completedAt[id]?.isAfter(instant) ?? false);
    }
    final finish = reservations[id]?.coveredAt;
    return finish != null && !finish.isAfter(instant);
  }
}

bool isOwnedTaskReservation(CalendarEvent event) =>
    event.plannedTaskId != null &&
    !event.isReadOnly &&
    !event.allDay &&
    event.recurringSeriesId == null;

/// Revalidates accepted blocks against the task's release, deadline and
/// prerequisite requirements.
/// The caller keeps every calendar interval occupied independently of this
/// evidence. A proposed upstream block becomes evidence after acceptance.
TaskReservationReview reviewTaskReservations({
  required List<TaskItem> tasks,
  required List<CalendarEvent> events,
  required DateTime cutoff,
}) {
  final byTask = <String, TaskItem>{};
  final duplicateTasks = <String>{};
  for (final task in tasks) {
    if (byTask.containsKey(task.id)) duplicateTasks.add(task.id);
    byTask[task.id] = task;
  }
  for (final duplicate in duplicateTasks) {
    byTask.remove(duplicate);
  }
  final completed = {
    for (final task in byTask.values)
      if (task.done && !(task.completedAt?.isAfter(cutoff) ?? false))
        task.id: task.completedAt,
  };
  final nodes = <String, _ReservedTask>{};
  final seen = <String>{};
  final duplicateEvents = <String>{};
  for (final event in events) {
    if (!seen.add(event.id)) duplicateEvents.add(event.id);
    if (!isOwnedTaskReservation(event) ||
        !event.end.isAfter(cutoff) ||
        !event.end.isAfter(event.start)) {
      continue;
    }
    final task = byTask[event.plannedTaskId];
    if (task != null && !task.done) {
      (nodes[task.id] ??= _ReservedTask(task)).blocks.add(event);
    }
  }
  if (nodes.isEmpty) return TaskReservationReview._(completed, {});

  final ready = <_ReservedTask>[];
  for (final node in nodes.values) {
    for (final id in node.task.prerequisiteIds.toSet()) {
      if (completed.containsKey(id)) {
        node.waitUntil(completed[id]);
      } else if (nodes[id] case final prerequisite?) {
        node.waiting++;
        prerequisite.dependants.add(node);
      } else {
        node.prerequisiteUnavailable = true;
      }
    }
    if (node.waiting == 0) ready.add(node);
  }

  final evidence = <String, TaskReservationEvidence>{};
  for (var index = 0; index < ready.length; index++) {
    final node = ready[index];
    final current = node.evidence(cutoff, duplicateEvents);
    evidence[node.task.id] = current;
    for (final dependant in node.dependants) {
      if (current.coveredAt case final finish?) {
        dependant.waitUntil(finish);
      } else {
        dependant.prerequisiteUnavailable = true;
      }
      dependant.waiting--;
      if (dependant.waiting == 0) ready.add(dependant);
    }
  }
  for (final node in nodes.values) {
    if (node.waiting > 0) {
      evidence[node.task.id] = node.evidence(cutoff, duplicateEvents);
    }
  }
  return TaskReservationReview._(completed, evidence);
}

final class _ReservedTask {
  _ReservedTask(this.task) : release = task.earliestStart;

  final TaskItem task;
  final blocks = <CalendarEvent>[];
  final dependants = <_ReservedTask>[];
  DateTime? release;
  int waiting = 0;
  bool prerequisiteUnavailable = false;

  void waitUntil(DateTime? finish) {
    if (finish != null && (release == null || finish.isAfter(release!))) {
      release = finish;
    }
  }

  TaskReservationEvidence evidence(DateTime cutoff, Set<String> duplicateIds) {
    blocks.sort((left, right) => left.start.compareTo(right.start));
    final estimate = task.estimatedMinutes;
    final scheduled = _Effort(cutoff);
    final usable = _Effort(cutoff);
    var needsReview = false;
    DateTime? covered;
    for (final block in blocks) {
      scheduled.add(block);
      if (waiting > 0 ||
          prerequisiteUnavailable ||
          task.schedulingHold != null ||
          block.id.trim().isEmpty ||
          duplicateIds.contains(block.id) ||
          (release?.isAfter(block.start) ?? false) ||
          (task.dueAt?.isBefore(block.end) ?? false)) {
        needsReview = true;
        continue;
      }
      final previously = usable.total;
      final start = usable.add(block);
      if (covered == null &&
          estimate != null &&
          estimate > 0 &&
          usable.total.inMinutes >= estimate) {
        covered = start.add(Duration(minutes: estimate) - previously);
      }
    }
    return TaskReservationEvidence._(
      minutes: scheduled.total.inMinutes,
      lastEnd: scheduled.end,
      coveredAt: covered,
      requiresReview: needsReview,
    );
  }
}

final class _Effort {
  _Effort(this.end);

  DateTime end;
  Duration total = Duration.zero;

  DateTime add(CalendarEvent block) {
    final start = end.isAfter(block.start) ? end : block.start;
    if (block.end.isAfter(start)) {
      total += block.end.difference(start);
      end = block.end;
    }
    return start;
  }
}
