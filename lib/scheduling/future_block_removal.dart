import '../calendar_page.dart';
import '../task_model.dart';

final class FutureBlockRemovalReview {
  factory FutureBlockRemovalReview.prepare({
    required TaskItem task,
    required List<CalendarEvent> events,
    required DateTime now,
    Set<String> protectedEventIds = const {},
  }) {
    if (!task.done) return FutureBlockRemovalReview._(task, const []);
    final candidates = <String, CalendarEvent>{};
    final seen = <String>{};
    final duplicates = <String>{};
    for (final event in events) {
      if (!seen.add(event.id)) duplicates.add(event.id);
      if (_eligible(event, task.id, now, protectedEventIds)) {
        candidates[event.id] = event;
      }
    }
    final blocks =
        [
          for (final entry in candidates.entries)
            if (!duplicates.contains(entry.key)) entry.value,
        ]..sort((left, right) {
          final time = left.start.compareTo(right.start);
          return time == 0 ? left.id.compareTo(right.id) : time;
        });
    return FutureBlockRemovalReview._(task, List.unmodifiable(blocks));
  }

  const FutureBlockRemovalReview._(this._task, this.blocks);

  final TaskItem _task;
  final List<CalendarEvent> blocks;

  String get taskId => _task.id;
  String get taskTitle => _task.title;

  FutureBlockRemovalSelection? select(Iterable<String> eventIds) {
    final ids = <String>{};
    for (final id in eventIds) {
      if (!ids.add(id) || ids.length > blocks.length) return null;
    }
    if (ids.isEmpty) return null;
    final selected = [
      for (final block in blocks)
        if (ids.contains(block.id)) block,
    ];
    return selected.length == ids.length
        ? FutureBlockRemovalSelection._(_task, List.unmodifiable(selected))
        : null;
  }
}

final class FutureBlockRemovalSelection {
  const FutureBlockRemovalSelection._(this._task, this.blocks);

  final TaskItem _task;
  final List<CalendarEvent> blocks;

  String get taskId => _task.id;

  /// Validates the approved rows as a whole before the workspace transaction.
  List<CalendarEvent>? remainingEvents({
    required TaskItem task,
    required List<CalendarEvent> events,
    required DateTime now,
    Set<String> protectedEventIds = const {},
  }) {
    if (!task.done ||
        task.id != _task.id ||
        task.title != _task.title ||
        task.completedAt?.microsecondsSinceEpoch !=
            _task.completedAt?.microsecondsSinceEpoch) {
      return null;
    }
    final selected = {for (final block in blocks) block.id: block};
    final confirmed = <String>{};
    final retained = <CalendarEvent>[];
    for (final event in events) {
      final approved = selected[event.id];
      if (approved == null) {
        retained.add(event);
      } else if (!confirmed.add(event.id) ||
          !_eligible(event, task.id, now, protectedEventIds) ||
          _version(approved) != _version(event)) {
        return null;
      }
    }
    return confirmed.length == selected.length
        ? List.unmodifiable(retained)
        : null;
  }
}

bool _eligible(
  CalendarEvent event,
  String taskId,
  DateTime now,
  Set<String> protectedIds,
) =>
    event.id.trim().isNotEmpty &&
    event.plannedTaskId == taskId &&
    !event.isReadOnly &&
    event.recurringSeriesId == null &&
    !event.allDay &&
    event.start.isAfter(now) &&
    event.end.isAfter(event.start) &&
    !protectedIds.contains(event.id);

Object _version(CalendarEvent event) => (
  event.start.microsecondsSinceEpoch,
  event.end.microsecondsSinceEpoch,
  event.title,
  event.category,
  event.location,
  event.savedPlaceId,
  event.description,
  event.color,
  event.initialPlannedStart?.microsecondsSinceEpoch,
  event.initialPlannedEnd?.microsecondsSinceEpoch,
);
