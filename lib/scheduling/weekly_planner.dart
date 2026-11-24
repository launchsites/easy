import 'dart:convert';

import '../calendar_page.dart';
import '../task_model.dart';
import '../tasks/task_workspace_feed.dart';
import 'availability_settings.dart';
import 'plan_day_sheet.dart' show planWorkspaceDay;
import 'planner.dart';

DateTime weeklyPlanStart(DateTime day, {int startsOn = DateTime.monday}) {
  if (startsOn < DateTime.monday || startsOn > DateTime.sunday) {
    throw ArgumentError.value(startsOn, 'startsOn', 'Choose an ISO weekday.');
  }
  final local = day.toLocal();
  return DateTime(
    local.year,
    local.month,
    local.day - (local.weekday - startsOn) % 7,
  );
}

DateTime weeklyPlanEnd(DateTime weekStart) {
  final local = weekStart.toLocal();
  return DateTime(local.year, local.month, local.day + 7);
}

TimeSpan? weeklyPlanningWindow(DateTime weekStart, {DateTime? notBefore}) {
  final local = weekStart.toLocal();
  final beginning = DateTime(local.year, local.month, local.day);
  final end = weeklyPlanEnd(beginning);
  final start = notBefore != null && notBefore.isAfter(beginning)
      ? notBefore
      : beginning;
  return end.isAfter(start) ? TimeSpan(start, end) : null;
}

/// Temporary hours for this review when the workspace has no saved hours.
final class WeeklyPlanHours {
  WeeklyPlanHours({
    required Iterable<int> weekdays,
    required int startMinute,
    required int endMinute,
  }) : _window = WeeklyAvailability(
         id: 'week-review-hours',
         weekdays: weekdays,
         startMinute: startMinute,
         endMinute: endMinute,
       ) {
    if (endMinute <= startMinute) {
      throw ArgumentError('End time must be after start time.');
    }
  }

  final WeeklyAvailability _window;
  Set<int> get weekdays => _window.weekdays;
  int get startMinute => _window.startMinute;
  int get endMinute => _window.endMinute;
}

/// Keeps each repeating occurrence on its own effective civil date.
List<TaskItem> weeklyWorkspaceTasks({
  required TaskWorkspaceFeed feed,
  required List<TaskItem> tasks,
  required DateTime weekStart,
}) {
  if (feed.series.isEmpty) return List.unmodifiable(tasks);
  final standalone = feed.standalone(tasks).toList();
  final added = standalone.map((task) => task.id).toSet();
  final output = [...standalone];
  final local = weekStart.toLocal();
  for (var index = 0; index < 7; index++) {
    final day = DateTime(local.year, local.month, local.day + index);
    for (final task in feed.planningOccurrences(day)) {
      if (added.add(task.id)) output.add(_onOrAfter(task, day));
    }
  }
  return List.unmodifiable(output);
}

TaskItem _onOrAfter(TaskItem task, DateTime day) {
  if (task.earliestStart case final earliest? when !earliest.isBefore(day)) {
    return task;
  }
  return TaskItem(
    id: task.id,
    title: task.title,
    category: task.category,
    date: task.date,
    done: task.done,
    estimatedMinutes: task.estimatedMinutes,
    priority: task.priority,
    parentId: task.parentId,
    notes: task.notes,
    earliestStart: day,
    prerequisiteIds: task.prerequisiteIds,
    allowSplit: task.allowSplit,
    minimumChunkMinutes: task.minimumChunkMinutes,
    dueAt: task.dueAt,
    completedAt: task.completedAt,
    schedulingHold: task.schedulingHold,
  );
}

final class WeeklyPlanPreview {
  WeeklyPlanPreview._({
    required this.window,
    required this.reservationStart,
    required this.proposal,
    required SchedulingSettings? settings,
    required this.hours,
    Set<String>? categories,
    Set<String>? taskIds,
  }) : _settings = settings == null ? null : jsonEncode(settings.toJson()),
       _categories = categories == null ? null : Set.unmodifiable(categories),
       _taskIds = taskIds == null ? null : Set.unmodifiable(taskIds);

  final TimeSpan window;
  final DateTime reservationStart;
  final ScheduleProposal proposal;
  final WeeklyPlanHours? hours;
  final String? _settings;
  final Set<String>? _categories;
  final Set<String>? _taskIds;

  WeeklyPlanSelection? select(Iterable<String> taskIds) {
    final requested = taskIds.toList();
    final selected = requested.toSet();
    if (selected.isEmpty || selected.length != requested.length) return null;
    final tasks = [
      for (final schedule in proposal.scheduled)
        if (selected.contains(schedule.task.id)) schedule,
    ];
    if (tasks.length != selected.length ||
        !_includesPrerequisites(tasks, selected, proposal)) {
      return null;
    }
    return WeeklyPlanSelection._(this, tasks);
  }
}

final class WeeklyPlanSelection {
  WeeklyPlanSelection._(this._preview, List<ScheduledTask> tasks)
    : tasks = List.unmodifiable(tasks);

  final WeeklyPlanPreview _preview;
  final List<ScheduledTask> tasks;

  TimeSpan get window => _preview.window;
  DateTime get reservationStart => _preview.reservationStart;

  /// Rebuilds this review from the latest events, tasks and workspace rules.
  List<ScheduledTask>? verify({
    required List<CalendarEvent> events,
    required List<TaskItem> tasks,
    required DateTime notBefore,
    SchedulingSettings? settings,
    Set<String>? categories,
  }) {
    final savedSettings = settings == null
        ? null
        : jsonEncode(settings.toJson());
    if (savedSettings != _preview._settings ||
        !_sameCategories(categories, _preview._categories)) {
      return null;
    }
    final ScheduleProposal current;
    try {
      current = _proposal(
        window: window,
        events: events,
        tasks: tasks,
        reservationStart: reservationStart,
        settings: settings,
        hours: _preview.hours,
        categories: categories,
        taskIds: _preview._taskIds,
      );
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    final selectedIds = {for (final entry in this.tasks) entry.task.id};
    final byId = {for (final entry in current.scheduled) entry.task.id: entry};
    final verified = <ScheduledTask>[];
    for (final original in this.tasks) {
      final candidate = byId[original.task.id];
      if (candidate == null ||
          !_sameSchedule(original, candidate) ||
          candidate.blocks.any((block) => block.start.isBefore(notBefore))) {
        return null;
      }
      verified.add(candidate);
    }
    return _includesPrerequisites(verified, selectedIds, current)
        ? List.unmodifiable(verified)
        : null;
  }
}

/// A single solver run shares remaining duration and occupancy across all days.
WeeklyPlanPreview? planWorkspaceWeek({
  required DateTime weekStart,
  required DateTime notBefore,
  required List<CalendarEvent> events,
  required List<TaskItem> tasks,
  DateTime? reservationStart,
  SchedulingSettings? settings,
  WeeklyPlanHours? hours,
  Set<String>? categories,
  Set<String>? taskIds,
}) {
  final window = weeklyPlanningWindow(weekStart, notBefore: notBefore);
  if (window == null) return null;
  final cutoff = reservationStart ?? notBefore;
  return WeeklyPlanPreview._(
    window: window,
    reservationStart: cutoff,
    settings: settings,
    hours: hours,
    categories: categories,
    taskIds: taskIds,
    proposal: _proposal(
      window: window,
      events: events,
      tasks: tasks,
      reservationStart: cutoff,
      settings: settings,
      hours: hours,
      categories: categories,
      taskIds: taskIds,
    ),
  );
}

bool hasSavedWeeklyHours(SchedulingSettings? settings) =>
    settings?.availability.any(
      (entry) => entry.kind == AvailabilityKind.available,
    ) ??
    false;

ScheduleProposal _proposal({
  required TimeSpan window,
  required List<CalendarEvent> events,
  required List<TaskItem> tasks,
  required DateTime reservationStart,
  required SchedulingSettings? settings,
  required WeeklyPlanHours? hours,
  required Set<String>? categories,
  required Set<String>? taskIds,
}) {
  if (hours != null && hasSavedWeeklyHours(settings)) {
    throw ArgumentError('Temporary hours apply when no availability is saved.');
  }
  final effective = hours == null
      ? settings ?? SchedulingSettings()
      : SchedulingSettings(
          timeZoneId: settings?.timeZoneId,
          availability: [
            ...?settings?.availability,
            WeeklyAvailability(
              id: _temporaryHoursId(settings),
              weekdays: hours.weekdays,
              startMinute: hours.startMinute,
              endMinute: hours.endMinute,
            ),
          ],
          places: settings?.places ?? const [],
          routes: settings?.routes ?? const [],
          beforeMinutes: settings?.beforeMinutes ?? 0,
          afterMinutes: settings?.afterMinutes ?? 0,
        );
  return planWorkspaceDay(
    window: window,
    events: _uniqueEvents(events),
    tasks: tasks,
    reservationStart: reservationStart,
    settings: effective,
    categories: categories,
    taskIds: taskIds,
  );
}

String _temporaryHoursId(SchedulingSettings? settings) {
  final ids =
      settings?.availability.map((entry) => entry.id).toSet() ??
      const <String>{};
  var index = 0;
  while (ids.contains('week-review-hours-$index')) {
    index++;
  }
  return 'week-review-hours-$index';
}

List<CalendarEvent> _uniqueEvents(List<CalendarEvent> events) {
  final byId = <String, CalendarEvent>{};
  for (final event in events) {
    final existing = byId[event.id];
    if (existing == null) {
      byId[event.id] = event;
    } else if (!_sameInstant(existing.start, event.start) ||
        !_sameInstant(existing.end, event.end) ||
        existing.plannedTaskId != event.plannedTaskId ||
        existing.savedPlaceId != event.savedPlaceId) {
      throw const FormatException('A calendar event has conflicting times.');
    }
  }
  return byId.values.toList();
}

bool _includesPrerequisites(
  Iterable<ScheduledTask> tasks,
  Set<String> ids,
  ScheduleProposal proposal,
) => tasks.every(
  (entry) => entry.task.prerequisites.every(
    (id) => ids.contains(id) || proposal.satisfiedPrerequisites.contains(id),
  ),
);

bool _sameSchedule(ScheduledTask earlier, ScheduledTask current) {
  final old = earlier.task;
  final task = current.task;
  if (old.title != task.title ||
      old.category != task.category ||
      old.remainingMinutes != task.remainingMinutes ||
      old.priority != task.priority ||
      old.allowSplit != task.allowSplit ||
      old.minimumChunkMinutes != task.minimumChunkMinutes ||
      !_sameInstant(old.deadline, task.deadline) ||
      !_sameInstant(old.earliest, task.earliest) ||
      !_sameCategories(old.prerequisites, task.prerequisites) ||
      earlier.blocks.length != current.blocks.length) {
    return false;
  }
  for (final (index, block) in earlier.blocks.indexed) {
    final next = current.blocks[index];
    if (!_sameInstant(block.start, next.start) ||
        !_sameInstant(block.end, next.end)) {
      return false;
    }
  }
  return true;
}

bool _sameInstant(DateTime? a, DateTime? b) =>
    a == null || b == null ? a == b : a.isAtSameMomentAs(b);

bool _sameCategories(Set<String>? a, Set<String>? b) =>
    a == null || b == null ? a == b : a.length == b.length && a.containsAll(b);
