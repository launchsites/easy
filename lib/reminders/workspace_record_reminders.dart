import '../calendar_page.dart';
import '../task_model.dart';
import '../tasks/recurring_task.dart';
import 'local_reminder.dart';

const recordRemindersSection = 'recordReminders';
const maxRecordReminderPreferences = 10000;

ReminderTarget targetForLocalCalendarEvent(CalendarEvent event) =>
    ReminderTarget(
      kind: event.plannedTaskId == null
          ? ReminderTargetKind.event
          : ReminderTargetKind.plannedBlock,
      recordId: event.id,
    );

Map<String, RecordReminderPreference> readRecordReminderPreferences(
  Object? raw,
) {
  if (raw == null) return const {};
  if (raw is! List || raw.length > maxRecordReminderPreferences) {
    throw const FormatException('Invalid workspace reminder preferences.');
  }
  final preferences = <String, RecordReminderPreference>{};
  for (final entry in raw) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('Invalid reminder preference.');
    }
    final preference = RecordReminderPreference.fromJson(entry);
    final key = preference.target.notificationId;
    if (preference.target.occurrenceId != null ||
        preferences.containsKey(key)) {
      throw const FormatException('Duplicate or invalid record reminder.');
    }
    preferences[key] = preference;
  }
  return Map.unmodifiable(preferences);
}

List<LocalReminder> composeWorkspaceReminders({
  required DateTime now,
  required List<TaskItem> tasks,
  required List<CalendarEvent> events,
  required List<RecurringTaskSeries> taskSeries,
  required Set<String> eventSeriesIds,
  required Iterable<RecordReminderPreference> preferences,
  required bool planningEnabled,
}) {
  final desired = remindersForRecurringTasks(taskSeries, now: now).toList();
  if (preferences.isEmpty) return List.unmodifiable(desired);

  final taskSeriesIds = {for (final series in taskSeries) series.id};
  final requested = {for (final item in preferences) item.target.recordId};
  final completedLinkedIds = <String>{};
  final activeEvents = <String, CalendarEvent>{};
  for (final event in events) {
    if (!requested.contains(event.id) ||
        event.isReadOnly ||
        eventSeriesIds.contains(event.id)) {
      continue;
    }
    if (event.plannedTaskId != null && !planningEnabled) continue;
    activeEvents[event.id] = event;
  }
  final linked = activeEvents.values
      .map((event) => event.plannedTaskId)
      .nonNulls
      .toSet();
  final activeTasks = <String, TaskItem>{};
  for (final task in tasks) {
    if (task.done && linked.contains(task.id)) completedLinkedIds.add(task.id);
    if (task.done ||
        !requested.contains(task.id) ||
        taskSeriesIds.contains(task.id)) {
      continue;
    }
    activeTasks[task.id] = task;
  }
  if (linked.isNotEmpty) {
    for (final series in taskSeries) {
      for (final occurrence in series.completions) {
        if (linked.contains(occurrence.id)) {
          completedLinkedIds.add(occurrence.id);
        }
      }
    }
  }

  for (final preference in preferences) {
    final target = preference.target;
    final task = activeTasks[target.recordId];
    final event = activeEvents[target.recordId];
    if (target.kind == ReminderTargetKind.task && task != null) {
      if (preference.resolve(title: task.title) case final reminder?) {
        desired.add(reminder);
      }
    } else if (target.kind != ReminderTargetKind.task &&
        event != null &&
        target.kind == targetForLocalCalendarEvent(event).kind &&
        !completedLinkedIds.contains(event.plannedTaskId)) {
      if (preference.resolve(start: event.start, title: event.title)
          case final reminder?) {
        desired.add(reminder);
      }
    }
  }
  return List.unmodifiable(desired);
}
