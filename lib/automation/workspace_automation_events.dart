import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../calendar_page.dart';
import '../gym_session.dart';
import '../review/review_data.dart';
import '../task_model.dart';
import 'automation_models.dart';

const _maximumIdentifierLength = 1500;

/// Projects a persisted, explicitly completed task. Legacy checked tasks
/// without a completion instant have no automation occurrence.
AutomationEvent? automationForTask(TaskItem task) {
  final completed = task.completedAt;
  if (!task.done ||
      completed == null ||
      !_validSource(task.id, task.category)) {
    return null;
  }
  final occurrence = completed.microsecondsSinceEpoch;
  return AutomationEvent(
    trigger: AutomationTrigger.taskCompleted,
    sourceId: task.id,
    occurrenceId: '$occurrence',
    sourceRevision: _revision([
      'task',
      task.id,
      task.title,
      task.category,
      occurrence,
      task.date?.microsecondsSinceEpoch,
      task.dueAt?.microsecondsSinceEpoch,
      task.earliestStart?.microsecondsSinceEpoch,
      task.parentId,
      task.estimatedMinutes,
      task.priority?.name,
      task.allowSplit,
      task.minimumChunkMinutes,
      task.schedulingHold?.reason.name,
      task.prerequisiteIds.toSet().toList()..sort(),
    ]),
    occurredAt: completed,
    category: _category(task.category),
    sourceTitle: task.title,
  );
}

/// Projects an accepted local occurrence. The caller supplies only saved
/// events, including occurrences of saved recurring local events.
AutomationEvent? automationForCalendar(CalendarEvent event) {
  if (event.isReadOnly ||
      event.allDay ||
      !event.end.isAfter(event.start) ||
      !_validSource(event.id, event.category)) {
    return null;
  }
  final occurrence = event.start.microsecondsSinceEpoch;
  return AutomationEvent(
    trigger: AutomationTrigger.acceptedEventStarted,
    sourceId: event.id,
    occurrenceId: '$occurrence',
    sourceRevision: _revision([
      'calendar',
      event.id,
      event.title,
      event.category,
      occurrence,
      event.end.microsecondsSinceEpoch,
      event.plannedTaskId,
      event.recurringSeriesId,
      event.savedPlaceId,
      event.initialPlannedStart?.microsecondsSinceEpoch,
      event.initialPlannedEnd?.microsecondsSinceEpoch,
    ]),
    occurredAt: event.start,
    eligibleUntil: event.end,
    category: _category(event.category),
    sourceTitle: event.title,
    origin: AutomationOrigin.acceptedSchedule,
  );
}

/// Projects a finished session. Point-in-time entries saved from a capture
/// have no elapsed workout and therefore no finish occurrence.
AutomationEvent? automationForWorkout(GymSession session) {
  final finished = session.finishedAt;
  if (finished == null || !finished.isAfter(session.startedAt)) return null;
  final sourceId = 'workout-${session.startedAt.microsecondsSinceEpoch}';
  final occurrence = finished.microsecondsSinceEpoch;
  final title = session.workoutTitle;
  return AutomationEvent(
    trigger: AutomationTrigger.workoutFinished,
    sourceId: sourceId,
    occurrenceId: '$occurrence',
    sourceRevision: _revision([
      'workout',
      sourceId,
      occurrence,
      title,
      session.planId,
      session.planned,
      session.structured,
    ]),
    occurredAt: finished,
    category: 'gym',
    sourceTitle: title,
  );
}

/// Projects an immutable saved reflection without carrying its private text.
AutomationEvent? automationForReflection(ReviewReflection reflection) {
  final occurrence = reflection.savedAt.microsecondsSinceEpoch;
  return AutomationEvent(
    trigger: AutomationTrigger.reviewSaved,
    sourceId: reflection.id,
    occurrenceId: '$occurrence',
    sourceRevision: _revision(['reflection', reflection.id, occurrence]),
    occurredAt: reflection.savedAt,
    sourceTitle: 'Reflection saved',
  );
}

bool _validSource(String id, String category) =>
    id.trim().isNotEmpty &&
    id.length <= _maximumIdentifierLength &&
    category.length <= _maximumIdentifierLength;

String? _category(String category) => category.trim().isEmpty ? null : category;

// Keep the revision exactly representable on the web and native runtimes.
int _revision(List<Object?> fields) {
  final digest = sha256.convert(
    utf8.encode(jsonEncode(['workspace-automation-v1', ...fields])),
  );
  var revision = 0;
  for (var index = 0; index < 6; index++) {
    revision = revision * 256 + digest.bytes[index];
  }
  return revision;
}
