import 'dart:convert';

import '../calendar_page.dart';
import '../task_model.dart';
import 'availability_settings.dart';
import 'planner.dart';
import 'task_reservations.dart';

const maxManualBlockMinutes = 24 * 60;

enum ManualBlockProblem {
  missingTask('This task is unavailable.'),
  missingBlock('This calendar block has changed.'),
  invalidDuration('Choose a block from 1 minute to 24 hours.'),
  pastStart('Choose a start time in the future.'),
  needsDetails('This task needs more details before scheduling.'),
  earliestStart('The block starts before this task is available.'),
  deadline('The block ends after the hard deadline.'),
  prerequisite('A prerequisite must finish before this block.'),
  dependent('A later block depends on this task finishing first.'),
  unavailable('This time falls outside the task’s availability.'),
  busy('This time overlaps a calendar event.'),
  travelUnknown('This time needs a saved travel duration.'),
  buffer('This time leaves too little buffer or travel time.'),
  calendarConflict('Review the calendar and availability again.');

  const ManualBlockProblem(this.message);
  final String message;
}

typedef _ManualProblem = ({ManualBlockProblem kind, String? relatedTitle});

final class ManualBlockReview {
  ManualBlockReview._({
    required this.span,
    required this.taskId,
    required TaskItem? task,
    required this.existingEventId,
    required this._existing,
    required this._settings,
    required Set<String> eventIds,
    required this.remainingEstimateMinutes,
    required this.requiresSoftDateOverride,
    required _ManualProblem? problem,
  }) : _task = task,
       _taskSource = task == null ? null : _taskSourceFor(task),
       _eventIds = Set.unmodifiable(eventIds),
       problem = problem?.kind,
       relatedTitle = problem?.relatedTitle;

  final TimeSpan span;
  final String taskId;
  final TaskItem? _task;
  final String? _taskSource;
  final String? existingEventId;
  final CalendarEvent? _existing;
  final String? _settings;
  final Set<String> _eventIds;
  final int? remainingEstimateMinutes;
  final bool requiresSoftDateOverride;
  final ManualBlockProblem? problem;
  final String? relatedTitle;

  bool get exceedsRemainingEstimate {
    final remaining = remainingEstimateMinutes;
    return remaining != null && span.length > Duration(minutes: remaining);
  }

  ManualBlockSelection? approve({
    bool allowSoftDateOverride = false,
    bool allowEstimateOverrun = false,
  }) {
    if (problem != null ||
        (requiresSoftDateOverride && !allowSoftDateOverride) ||
        (exceedsRemainingEstimate && !allowEstimateOverrun)) {
      return null;
    }
    return ManualBlockSelection._(
      this,
      requiresSoftDateOverride && allowSoftDateOverride,
      exceedsRemainingEstimate && allowEstimateOverrun,
    );
  }
}

final class ManualBlockSelection {
  ManualBlockSelection._(
    this._review,
    this.overridesSoftDate,
    this.overridesEstimate,
  );

  final ManualBlockReview _review;
  final bool overridesSoftDate;
  final bool overridesEstimate;

  String get taskId => _review.taskId;
  String? get existingEventId => _review.existingEventId;
  TimeSpan get span => _review.span;

  /// Recheck the interval against a fresh workspace snapshot before writing.
  ManualBlockSelection? verify({
    required List<TaskItem> tasks,
    required List<CalendarEvent> events,
    required DateTime notBefore,
    SchedulingSettings? settings,
  }) {
    final review = reviewManualTimeBlock(
      taskId: taskId,
      span: span,
      tasks: tasks,
      events: events,
      notBefore: notBefore,
      settings: settings,
      existingEventId: existingEventId,
    );
    if (review._taskSource != _review._taskSource ||
        review._settings != _review._settings ||
        review.remainingEstimateMinutes != _review.remainingEstimateMinutes ||
        !_matchesEvent(review._existing, _review._existing)) {
      return null;
    }
    return review.approve(
      allowSoftDateOverride: overridesSoftDate,
      allowEstimateOverrun: overridesEstimate,
    );
  }

  CalendarEvent calendarEvent({String? newId}) {
    final existing = _review._existing;
    final id = existing?.id ?? newId;
    if (id == null ||
        id.trim().isEmpty ||
        (existing == null && _review._eventIds.contains(id))) {
      throw ArgumentError('Choose a new calendar block ID.');
    }
    final task = _review._task!;
    return CalendarEvent(
      id: id,
      title: existing?.title ?? task.title,
      start: span.start,
      end: span.end,
      category: existing?.category ?? task.category,
      location: existing?.location,
      description: existing?.description,
      savedPlaceId: existing?.savedPlaceId,
      color: existing?.color,
      plannedTaskId: task.id,
      initialPlannedStart:
          existing?.initialPlannedStart ?? existing?.start ?? span.start,
      initialPlannedEnd:
          existing?.initialPlannedEnd ?? existing?.end ?? span.end,
    );
  }
}

ManualBlockReview reviewManualTimeBlock({
  required String taskId,
  required TimeSpan span,
  required List<TaskItem> tasks,
  required List<CalendarEvent> events,
  required DateTime notBefore,
  SchedulingSettings? settings,
  String? existingEventId,
}) {
  final taskRows = tasks.where((task) => task.id == taskId);
  final task = taskRows.length == 1 ? taskRows.single : null;
  final byId = <String, CalendarEvent>{};
  var conflictingEvents = false;
  for (final event in events) {
    final existing = byId[event.id];
    if (existing == null) {
      byId[event.id] = event;
    } else if (!_matchesEvent(existing, event)) {
      conflictingEvents = true;
    }
  }
  final existing = byId[existingEventId];
  final relevantEvents = byId.values
      .where((event) => event.id != existingEventId)
      .toList();
  final reservations = reviewTaskReservations(
    tasks: tasks,
    events: relevantEvents,
    cutoff: notBefore,
  );
  final taskDate = task?.date?.toLocal();
  final dueDate = task?.dueAt?.toLocal();
  final dateStart = taskDate == null
      ? null
      : DateTime(taskDate.year, taskDate.month, taskDate.day);
  final dateEnd = taskDate == null
      ? null
      : DateTime(taskDate.year, taskDate.month, taskDate.day + 1);
  final dueIsSameDay =
      dueDate != null &&
      dateStart != null &&
      !dueDate.isBefore(dateStart) &&
      dueDate.isBefore(dateEnd!);
  final needsOverride =
      dateStart != null &&
      !dueIsSameDay &&
      (span.start.isBefore(dateStart) || span.end.isAfter(dateEnd!));
  final estimate = task?.estimatedMinutes;
  final remaining = estimate == null || estimate <= 0
      ? null
      : (estimate - (reservations.reservations[taskId]?.minutes ?? 0)).clamp(
          0,
          estimate,
        );
  final _ManualProblem? problem;
  if (task == null || task.done) {
    problem = (kind: ManualBlockProblem.missingTask, relatedTitle: null);
  } else if (existingEventId != null &&
      (existing == null ||
          !isOwnedTaskReservation(existing) ||
          existing.plannedTaskId != taskId)) {
    problem = (kind: ManualBlockProblem.missingBlock, relatedTitle: null);
  } else if (conflictingEvents) {
    problem = (kind: ManualBlockProblem.calendarConflict, relatedTitle: null);
  } else {
    problem = _checkBlock(
      task,
      span,
      tasks,
      relevantEvents,
      reservations,
      notBefore,
      settings,
      existing,
    );
  }
  return ManualBlockReview._(
    span: span,
    taskId: taskId,
    task: task,
    existingEventId: existingEventId,
    existing: existing,
    settings: settings == null ? null : jsonEncode(settings.toJson()),
    eventIds: byId.keys.toSet(),
    remainingEstimateMinutes: remaining,
    requiresSoftDateOverride: needsOverride,
    problem: problem,
  );
}

_ManualProblem? _checkBlock(
  TaskItem task,
  TimeSpan span,
  List<TaskItem> tasks,
  List<CalendarEvent> events,
  TaskReservationReview reservations,
  DateTime notBefore,
  SchedulingSettings? settings,
  CalendarEvent? existing,
) {
  _ManualProblem issue(ManualBlockProblem kind, [String? relatedTitle]) =>
      (kind: kind, relatedTitle: relatedTitle);
  if (task.schedulingHold case final hold?) {
    return issue(ManualBlockProblem.needsDetails, hold.message);
  }
  if (span.length < const Duration(minutes: 1) ||
      span.length > const Duration(minutes: maxManualBlockMinutes) ||
      span.start.year < 1 ||
      span.end.year > 9999) {
    return issue(ManualBlockProblem.invalidDuration);
  }
  if (span.start.isBefore(notBefore)) {
    return issue(ManualBlockProblem.pastStart);
  }
  if (task.earliestStart case final earliest?
      when span.start.isBefore(earliest)) {
    return issue(ManualBlockProblem.earliestStart);
  }
  if (task.dueAt case final deadline? when span.end.isAfter(deadline)) {
    return issue(ManualBlockProblem.deadline);
  }
  if (task.prerequisiteIds.isNotEmpty) {
    final ids = task.prerequisiteIds.toSet();
    for (final id in ids) {
      if (id == task.id || !reservations.satisfiesAt(id, span.start)) {
        final prerequisite = tasks
            .where((record) => record.id == id)
            .firstOrNull;
        return issue(ManualBlockProblem.prerequisite, prerequisite?.title);
      }
    }
  }
  for (final event in events) {
    if (event.blocksTime &&
        event.end.isAfter(event.start) &&
        event.start.isBefore(span.end) &&
        span.start.isBefore(event.end)) {
      return issue(ManualBlockProblem.busy, event.title);
    }
  }
  final estimate = task.estimatedMinutes;
  if (existing != null && estimate != null && estimate > 0) {
    final old = reviewTaskReservations(
      tasks: tasks,
      events: [...events, existing],
      cutoff: notBefore,
    );
    final replacement = CalendarEvent(
      id: existing.id,
      title: existing.title,
      start: span.start,
      end: span.end,
      category: existing.category,
      plannedTaskId: task.id,
    );
    final updated = reviewTaskReservations(
      tasks: tasks,
      events: [...events, replacement],
      cutoff: notBefore,
    );
    final dependants = {
      for (final dependent in tasks)
        if (!dependent.done && dependent.prerequisiteIds.contains(task.id))
          dependent.id: dependent.title,
    };
    for (final block in events) {
      final dependant = dependants[block.plannedTaskId];
      if (dependant != null &&
          isOwnedTaskReservation(block) &&
          !block.start.isBefore(notBefore) &&
          old.satisfiesAt(task.id, block.start) &&
          !updated.satisfiesAt(task.id, block.start)) {
        return issue(ManualBlockProblem.dependent, dependant);
      }
    }
  }
  if (settings == null) return null;
  try {
    final inputs = _calendarInputs(
      settings,
      task.category,
      span,
      events,
      existing,
    );
    if (!_covered(span, inputs.availability, task.category)) {
      return issue(ManualBlockProblem.unavailable);
    }
    final plannedPlaceTravel = inputs.travelIssues.where(
      (travel) =>
          travel.fromCommitmentId == existing?.id ||
          travel.toCommitmentId == existing?.id,
    );
    for (final travel in plannedPlaceTravel) {
      return issue(
        travel.kind == TravelIssueKind.missingDuration
            ? ManualBlockProblem.travelUnknown
            : ManualBlockProblem.buffer,
      );
    }
    if (inputs.commitments.any(
      (commitment) =>
          !identical(commitment.span, span) &&
          commitment.span.start
              .subtract(commitment.before)
              .isBefore(span.end) &&
          span.start.isBefore(commitment.span.end.add(commitment.after)),
    )) {
      return issue(
        _crossesUnknownTravel(span, events, inputs.travelIssues)
            ? ManualBlockProblem.travelUnknown
            : ManualBlockProblem.buffer,
      );
    }
  } on ArgumentError {
    return issue(ManualBlockProblem.calendarConflict);
  }
  return null;
}

bool _crossesUnknownTravel(
  TimeSpan span,
  List<CalendarEvent> events,
  Iterable<TravelIssue> issues,
) {
  final missing = issues.where(
    (issue) => issue.kind == TravelIssueKind.missingDuration,
  );
  if (missing.isEmpty) return false;
  final byId = {for (final event in events) event.id: event};
  for (final issue in missing) {
    final from = byId[issue.fromCommitmentId];
    final to = byId[issue.toCommitmentId];
    if (from != null &&
        to != null &&
        from.end.isBefore(to.start) &&
        span.start.isBefore(to.start) &&
        from.end.isBefore(span.end)) {
      return true;
    }
  }
  return false;
}

SchedulingInputs _calendarInputs(
  SchedulingSettings source,
  String category,
  TimeSpan span,
  List<CalendarEvent> events,
  CalendarEvent? existing,
) {
  final hasHours = source.availability.any(
    (entry) => entry.kind == AvailabilityKind.available,
  );
  final settings = hasHours
      ? source
      : SchedulingSettings(
          timeZoneId: source.timeZoneId,
          availability: [
            ...source.availability,
            WeeklyAvailability(
              id: _manualAvailabilityId(source),
              weekdays: const [1, 2, 3, 4, 5, 6, 7],
              startMinute: 0,
              endMinute: 1440,
            ),
          ],
          places: source.places,
          routes: source.routes,
          beforeMinutes: source.beforeMinutes,
          afterMinutes: source.afterMinutes,
        );
  final places = source.places.map((place) => place.id).toSet();
  final withPlace = existing != null && places.contains(existing.savedPlaceId);
  // A neighboring travel issue may begin or end exactly at the selected edge.
  const instant = Duration(microseconds: 1);
  return settings.planningInputs(
    horizon: withPlace
        ? TimeSpan(span.start.subtract(instant), span.end.add(instant))
        : span,
    categories: [category],
    commitments: [
      for (final event in events)
        if (event.blocksTime && event.end.isAfter(event.start))
          PlacedCommitment(
            id: event.id,
            span: TimeSpan(event.start, event.end),
            placeId: places.contains(event.savedPlaceId)
                ? event.savedPlaceId
                : null,
          ),
      if (withPlace)
        PlacedCommitment(
          id: existing.id,
          span: span,
          placeId: existing.savedPlaceId,
        ),
    ],
  );
}

String _manualAvailabilityId(SchedulingSettings settings) {
  final used = settings.availability.map((item) => item.id).toSet();
  var index = 0;
  while (used.contains('manual-selection-$index')) {
    index++;
  }
  return 'manual-selection-$index';
}

bool _covered(
  TimeSpan span,
  Iterable<PlanningWindow> windows,
  String category,
) {
  var cursor = span.start;
  for (final window in windows) {
    if (!window.allows(category) || !window.span.end.isAfter(cursor)) continue;
    if (window.span.start.isAfter(cursor)) return false;
    cursor = window.span.end;
    if (!cursor.isBefore(span.end)) return true;
  }
  return false;
}

String _taskSourceFor(TaskItem task) => jsonEncode([
  task.id,
  task.title,
  task.category,
  task.parentId,
  task.done,
  task.estimatedMinutes,
  task.allowSplit,
  task.minimumChunkMinutes,
  task.date?.toIso8601String(),
  task.earliestStart?.toIso8601String(),
  task.dueAt?.toIso8601String(),
  task.schedulingHold?.toJson(),
  task.prerequisiteIds.toSet().toList()..sort(),
]);

bool _matchesEvent(CalendarEvent? a, CalendarEvent? b) =>
    a == null || b == null ? a == b : _eventSource(a) == _eventSource(b);

Object _eventSource(CalendarEvent event) => (
  event.id,
  event.title,
  event.start.microsecondsSinceEpoch,
  event.end.microsecondsSinceEpoch,
  event.category,
  event.allDay,
  event.blocksTime,
  event.location,
  event.description,
  event.savedPlaceId,
  event.plannedTaskId,
  event.initialPlannedStart?.microsecondsSinceEpoch,
  event.initialPlannedEnd?.microsecondsSinceEpoch,
  event.recurringSeriesId,
  event.sourceLabel,
  event.color,
);
