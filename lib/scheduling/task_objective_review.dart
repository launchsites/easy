import '../calendar_page.dart';
import '../task_model.dart';
import 'planner.dart' show TimeSpan;

enum ObjectiveReadiness {
  ready,
  needsDetails,
  prerequisiteUnavailable,
  waitingForPrerequisite,
  startsLater,
  missedDeadline,
  reservedTime,
  reservationUnavailable,
  hasSubtasks,
}

enum ObjectiveFit { complete, split, needsMoreTime, unknown }

/// An explicitly timed downstream task. This deadline belongs to that task.
final class ObjectiveDependencyDeadline {
  const ObjectiveDependencyDeadline._(this.taskId, this.title, this.dueAt);

  final String taskId;
  final String title;
  final DateTime dueAt;
}

final class TaskObjective {
  const TaskObjective._({
    required this.id,
    required this.title,
    required this.readiness,
    required this.fit,
    required this.dueAt,
    required this.preferredDate,
    required this.priority,
    required this.earliestStart,
    required this.hold,
    required this.prerequisiteTitle,
    required this.additionalPrerequisiteCount,
    required this.dependencyDeadline,
    required this.unreservedEffort,
    required this.reservedEffort,
    required this.nextReservation,
    required this.inReservedTime,
  });

  final String id;
  final String title;
  final ObjectiveReadiness readiness;
  final ObjectiveFit fit;
  final DateTime? dueAt;
  final DateTime? preferredDate;
  final TaskPriority? priority;
  final DateTime? earliestStart;
  final TaskSchedulingHold? hold;
  final String? prerequisiteTitle;
  final int additionalPrerequisiteCount;
  final ObjectiveDependencyDeadline? dependencyDeadline;
  final Duration? unreservedEffort;
  final Duration reservedEffort;
  final TimeSpan? nextReservation;
  final bool inReservedTime;

  bool get availableToStart =>
      readiness == ObjectiveReadiness.ready &&
      fit != ObjectiveFit.needsMoreTime;
}

final class TaskObjectiveReview {
  TaskObjectiveReview._({
    required this.reviewedAt,
    required this.availableTime,
    required List<TaskObjective> ready,
    required List<TaskObjective> needsAttention,
    required List<TaskObjective> later,
  }) : ready = List.unmodifiable(ready),
       needsAttention = List.unmodifiable(needsAttention),
       later = List.unmodifiable(later);

  final DateTime reviewedAt;
  final Duration? availableTime;
  final List<TaskObjective> ready;
  final List<TaskObjective> needsAttention;
  final List<TaskObjective> later;

  bool get isEmpty => ready.isEmpty && needsAttention.isEmpty && later.isEmpty;
}

/// Ranks the current snapshot without editing tasks or reserving calendar time.
/// The optional window must represent known availability and contain [now].
TaskObjectiveReview reviewTaskObjectives({
  required List<TaskItem> tasks,
  required List<CalendarEvent> events,
  required DateTime now,
  required DateTime horizonEnd,
  Set<String>? focusCategories,
  TimeSpan? workWindow,
}) {
  if (!horizonEnd.isAfter(now)) {
    throw ArgumentError.value(horizonEnd, 'horizonEnd', 'Must follow now.');
  }

  final indexed = <String, TaskItem>{};
  final ambiguous = <String>{};
  for (final task in tasks) {
    if (task.id.trim().isEmpty) continue;
    if (indexed.containsKey(task.id)) ambiguous.add(task.id);
    indexed[task.id] = task;
  }
  for (final id in ambiguous) {
    indexed.remove(id);
  }
  final open = {
    for (final task in indexed.values)
      if (!task.done) task.id: _ObjectiveNode(task),
  };
  for (final node in open.values) {
    final task = node.task;
    if (task.parentId != task.id) open[task.parentId]?.hasSubtasks = true;
    for (final id in task.prerequisiteIds.toSet()) {
      if (open[id] case final prerequisite?) {
        node.prerequisites.add(prerequisite);
        prerequisite.dependants.add(node);
      } else {
        final prerequisite = indexed[id];
        if (prerequisite == null ||
            (prerequisite.completedAt?.isAfter(now) ?? false)) {
          node.unavailable = true;
        }
      }
    }
    node.unvisitedPrerequisites = node.prerequisites.length;
  }
  _prioritizePrerequisites(open.values, now, horizonEnd);

  final reservationSpans = <String, List<TimeSpan>>{};
  final knownWindow =
      workWindow != null &&
          !workWindow.start.isAfter(now) &&
          workWindow.end.isAfter(now)
      ? workWindow
      : null;
  var availableTime = knownWindow?.end.difference(now);
  var activeCommitments = 0;
  final reservationIds = <String>{};
  final duplicateReservations = <String>{};
  for (final event in events) {
    if (!reservationIds.add(event.id)) duplicateReservations.add(event.id);
    if (!event.end.isAfter(event.start) || !event.end.isAfter(now)) continue;
    if (!event.start.isAfter(now)) {
      activeCommitments++;
      availableTime = Duration.zero;
    } else if (availableTime != null) {
      final untilEvent = event.start.difference(now);
      if (untilEvent < availableTime) availableTime = untilEvent;
    }
  }
  for (final event in events) {
    final taskId = event.plannedTaskId;
    if (taskId == null ||
        !open.containsKey(taskId) ||
        event.id.trim().isEmpty ||
        event.isReadOnly ||
        event.allDay ||
        event.recurringSeriesId != null ||
        !event.end.isAfter(now) ||
        !event.end.isAfter(event.start)) {
      continue;
    }
    if (duplicateReservations.contains(event.id)) {
      open[taskId]!.reservationUnavailable = true;
      continue;
    }
    (reservationSpans[taskId] ??= []).add(TimeSpan(event.start, event.end));
  }

  final ready = <TaskObjective>[];
  final needsAttention = <TaskObjective>[];
  final later = <TaskObjective>[];
  for (final node in open.values) {
    if (!(focusCategories?.contains(node.task.category) ?? true)) continue;
    final objective = node.objective(
      now,
      _reservations(reservationSpans[node.task.id], now),
      availableTime,
      clearActiveReservation: activeCommitments == 1,
    );
    switch (objective.readiness) {
      case ObjectiveReadiness.ready when objective.availableToStart:
      case ObjectiveReadiness.reservedTime when objective.inReservedTime:
        ready.add(objective);
      case ObjectiveReadiness.needsDetails:
      case ObjectiveReadiness.prerequisiteUnavailable:
      case ObjectiveReadiness.waitingForPrerequisite:
      case ObjectiveReadiness.missedDeadline:
      case ObjectiveReadiness.reservationUnavailable:
        needsAttention.add(objective);
      case ObjectiveReadiness.ready:
      case ObjectiveReadiness.startsLater:
      case ObjectiveReadiness.reservedTime:
      case ObjectiveReadiness.hasSubtasks:
        later.add(objective);
    }
  }

  int rank(TaskObjective left, TaskObjective right) {
    if (left.inReservedTime != right.inReservedTime) {
      return left.inReservedTime ? -1 : 1;
    }
    final deadline = _compareDates(
      _urgency(left, horizonEnd),
      _urgency(right, horizonEnd),
    );
    if (deadline != 0) return deadline;
    final priority = (right.priority ?? TaskPriority.normal).index.compareTo(
      (left.priority ?? TaskPriority.normal).index,
    );
    if (priority != 0) return priority;
    final preferred = _compareDates(left.preferredDate, right.preferredDate);
    if (preferred != 0) return preferred;
    return left.id.compareTo(right.id);
  }

  return TaskObjectiveReview._(
    reviewedAt: now,
    availableTime: availableTime,
    ready: ready..sort(rank),
    needsAttention: needsAttention..sort(rank),
    later: later..sort(rank),
  );
}

final class _ObjectiveNode {
  _ObjectiveNode(this.task);

  final TaskItem task;
  final prerequisites = <_ObjectiveNode>[];
  final dependants = <_ObjectiveNode>[];
  int unvisitedPrerequisites = 0;
  bool unavailable = false;
  bool hasSubtasks = false;
  bool reservationUnavailable = false;
  ObjectiveDependencyDeadline? dependencyDeadline;

  TaskObjective objective(
    DateTime now,
    _Reservations reserved,
    Duration? availableTime, {
    required bool clearActiveReservation,
  }) {
    final estimate = task.estimatedMinutes;
    final estimatedEffort = estimate != null && estimate > 0 && estimate <= 1440
        ? Duration(minutes: estimate)
        : null;
    final remaining = estimatedEffort == null
        ? null
        : estimatedEffort > reserved.effort
        ? estimatedEffort - reserved.effort
        : Duration.zero;
    final deadline = task.dueAt;
    final start = task.earliestStart;
    final activeReservation =
        reserved.next != null && !reserved.next!.start.isAfter(now);
    final readiness = switch (this) {
      _ when task.schedulingHold != null => ObjectiveReadiness.needsDetails,
      _ when deadline != null && !deadline.isAfter(now) =>
        ObjectiveReadiness.missedDeadline,
      _ when unavailable || unvisitedPrerequisites > 0 =>
        ObjectiveReadiness.prerequisiteUnavailable,
      _ when prerequisites.isNotEmpty =>
        ObjectiveReadiness.waitingForPrerequisite,
      _ when start != null && start.isAfter(now) =>
        ObjectiveReadiness.startsLater,
      _ when hasSubtasks => ObjectiveReadiness.hasSubtasks,
      _ when reservationUnavailable =>
        ObjectiveReadiness.reservationUnavailable,
      _
          when reserved.next != null &&
              (remaining == null ||
                  remaining == Duration.zero ||
                  activeReservation) =>
        ObjectiveReadiness.reservedTime,
      _ => ObjectiveReadiness.ready,
    };
    final untilDue = deadline?.difference(now);
    final usableTime =
        untilDue != null && availableTime != null && untilDue < availableTime
        ? untilDue
        : availableTime;
    final minimum = task.minimumChunkMinutes;
    final fit = switch (usableTime) {
      _ when readiness != ObjectiveReadiness.ready => ObjectiveFit.unknown,
      _ when usableTime != null && usableTime <= Duration.zero =>
        ObjectiveFit.needsMoreTime,
      final gap? when remaining != null && remaining <= gap =>
        ObjectiveFit.complete,
      final gap?
          when remaining != null &&
              task.allowSplit &&
              minimum > 0 &&
              minimum <= estimate! &&
              remaining >= Duration(minutes: minimum * 2) &&
              gap >= Duration(minutes: minimum) =>
        ObjectiveFit.split,
      _ when usableTime != null && remaining != null =>
        ObjectiveFit.needsMoreTime,
      _ => ObjectiveFit.unknown,
    };
    return TaskObjective._(
      id: task.id,
      title: task.title,
      readiness: readiness,
      fit: fit,
      dueAt: deadline,
      preferredDate: task.date,
      priority: task.priority,
      earliestStart: start,
      hold: task.schedulingHold,
      prerequisiteTitle: prerequisites.firstOrNull?.task.title,
      additionalPrerequisiteCount: prerequisites.isEmpty
          ? 0
          : prerequisites.length - 1,
      dependencyDeadline: dependencyDeadline,
      unreservedEffort: remaining,
      reservedEffort: reserved.effort,
      nextReservation: reserved.next,
      inReservedTime:
          readiness == ObjectiveReadiness.reservedTime &&
          activeReservation &&
          clearActiveReservation,
    );
  }
}

void _prioritizePrerequisites(
  Iterable<_ObjectiveNode> nodes,
  DateTime now,
  DateTime horizonEnd,
) {
  final visited = [
    for (final node in nodes)
      if (node.unvisitedPrerequisites == 0) node,
  ];
  for (var index = 0; index < visited.length; index++) {
    final prerequisite = visited[index];
    for (final node in prerequisite.dependants) {
      if (prerequisite.unavailable) node.unavailable = true;
      node.unvisitedPrerequisites--;
      if (node.unvisitedPrerequisites == 0) visited.add(node);
    }
  }
  for (final node in visited.reversed) {
    if (node.unavailable) continue;
    final task = node.task;
    final date = task.dueAt;
    final explicit =
        date != null && date.isAfter(now) && !date.isAfter(horizonEnd)
        ? ObjectiveDependencyDeadline._(task.id, task.title, date)
        : null;
    final best = _earlierDeadline(explicit, node.dependencyDeadline);
    if (best == null) continue;
    for (final prerequisite in node.prerequisites) {
      prerequisite.dependencyDeadline = _earlierDeadline(
        prerequisite.dependencyDeadline,
        best,
      );
    }
  }
}

ObjectiveDependencyDeadline? _earlierDeadline(
  ObjectiveDependencyDeadline? left,
  ObjectiveDependencyDeadline? right,
) {
  if (left == null) return right;
  if (right == null) return left;
  final time = left.dueAt.compareTo(right.dueAt);
  if (time != 0) return time < 0 ? left : right;
  return left.taskId.compareTo(right.taskId) <= 0 ? left : right;
}

DateTime? _urgency(TaskObjective objective, DateTime horizonEnd) {
  final own = objective.dueAt;
  final downstream = objective.dependencyDeadline?.dueAt;
  if (own == null || own.isAfter(horizonEnd)) return downstream;
  return downstream != null && downstream.isBefore(own) ? downstream : own;
}

int _compareDates(DateTime? left, DateTime? right) => switch ((left, right)) {
  (final a?, final b?) => a.compareTo(b),
  (null, final _?) => 1,
  (final _?, null) => -1,
  (null, null) => 0,
};

typedef _Reservations = ({Duration effort, TimeSpan? next});

_Reservations _reservations(List<TimeSpan>? spans, DateTime now) {
  if (spans == null) return (effort: Duration.zero, next: null);
  spans.sort((left, right) {
    final start = left.start.compareTo(right.start);
    return start == 0 ? left.end.compareTo(right.end) : start;
  });
  final first = spans.first;
  var start = first.start.isBefore(now) ? now : first.start;
  var end = first.end;
  var total = Duration.zero;
  for (final span in spans.skip(1)) {
    if (span.start.isAfter(end)) {
      total += end.difference(start);
      start = span.start;
      end = span.end;
    } else if (span.end.isAfter(end)) {
      end = span.end;
    }
  }
  return (effort: total + end.difference(start), next: first);
}
