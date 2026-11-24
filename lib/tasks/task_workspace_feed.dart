import '../task_model.dart';
import 'recurring_task.dart';

const recurringTasksSection = 'recurringTasks';
const maximumTaskSeries = 500;

List<RecurringTaskSeries> readTaskSeries(Object? saved) {
  if (saved == null) return const [];
  if (saved is! List || saved.length > maximumTaskSeries) {
    throw const FormatException('Invalid workspace repeating tasks.');
  }
  final result = <RecurringTaskSeries>[];
  final ids = <String>{};
  for (final entry in saved) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException('Invalid repeating task.');
    }
    final series = RecurringTaskSeries.fromJson(entry);
    if (series.id.isEmpty || !ids.add(series.id)) {
      throw const FormatException('Duplicate repeating task.');
    }
    result.add(series);
  }
  return List.unmodifiable(result);
}

typedef TaskSeriesRow = ({
  RecurringTaskSeries series,
  RecurringTaskOccurrence occurrence,
  TaskItem task,
});

/// Keeps repeat templates durable and projects ordinary task rows only where
/// needed. An open occurrence from a past date stays available in its review.
class TaskWorkspaceFeed {
  TaskWorkspaceFeed([this.series = const []])
    : ids = {for (final value in series) value.id};

  final List<RecurringTaskSeries> series;
  final Set<String> ids;
  (List<TaskItem>, DateTime)? _lastInput;
  List<TaskItem> _lastTasks = const [];
  Map<String, TaskSeriesRow> _lastRows = const {};

  Iterable<TaskItem> standalone(List<TaskItem> tasks) =>
      ids.isEmpty ? tasks : tasks.where((task) => !ids.contains(task.id));

  List<TaskItem> workspaceTasks(List<TaskItem> tasks, DateTime today) {
    if (series.isEmpty) return tasks;
    final day = _civilDay(today);
    final input = (tasks, day);
    if (input == _lastInput) return _lastTasks;
    final rows = _rows(
      day.subtract(const Duration(days: 30)),
      day.add(const Duration(days: 15)),
    );
    final occupied = {for (final task in standalone(tasks)) task.id};
    _lastRows = {
      for (final row in rows)
        if ((row.task.done || !row.occurrence.scheduledDate.isBefore(day)) &&
            occupied.add(row.task.id))
          row.task.id: row,
    };
    _lastTasks = List.unmodifiable([
      ...standalone(tasks),
      for (final value in _lastRows.values) value.task,
    ]);
    _lastInput = input;
    return _lastTasks;
  }

  TaskSeriesRow? row(
    String id,
    List<TaskItem> tasks,
    DateTime today, {
    DateTime? sourceDate,
  }) {
    workspaceTasks(tasks, today);
    if (_lastRows[id] case final current?) return current;
    if (sourceDate == null || tasks.any((task) => task.id == id)) return null;
    final day = _civilDay(sourceDate);
    return _rows(
      day,
      day.add(const Duration(days: 1)),
    ).where((row) => row.task.id == id).firstOrNull;
  }

  Iterable<TaskItem> reviewTasks(List<TaskItem> tasks, DateTime day) sync* {
    yield* standalone(tasks);
    if (series.isEmpty) return;
    final start = _civilDay(day);
    final occupied = {for (final task in standalone(tasks)) task.id};
    for (final row in _rows(start, start.add(const Duration(days: 1)))) {
      if (occupied.add(row.task.id)) yield row.task;
    }
  }

  Iterable<TaskItem> insightTasks(List<TaskItem> tasks) sync* {
    yield* standalone(tasks);
    if (series.isEmpty) return;
    final occupied = {for (final task in standalone(tasks)) task.id};
    for (final value in series) {
      for (final occurrence in value.completions) {
        if (occupied.add(occurrence.id)) yield _taskRow(occurrence);
      }
    }
  }

  List<TaskItem> planningTasks(List<TaskItem> tasks, DateTime day) {
    if (series.isEmpty) return tasks;
    final available = standalone(tasks).toList();
    final occupied = {for (final task in available) task.id};
    for (final task in planningOccurrences(day)) {
      if (occupied.add(task.id)) available.add(task);
    }
    return available;
  }

  Iterable<TaskItem> planningOccurrences(DateTime day) sync* {
    final start = _civilDay(day);
    final end = start.add(const Duration(days: 1));
    for (final row in _rows(start, end)) {
      if (row.occurrence.canSchedule) yield row.task;
    }
  }

  Iterable<TaskSeriesRow> _rows(DateTime start, DateTime end) sync* {
    for (final value in series) {
      for (final occurrence in value.occurrences(
        windowStart: start,
        windowEnd: end,
      )) {
        yield (
          series: value,
          occurrence: occurrence,
          task: _taskRow(occurrence),
        );
      }
    }
  }
}

DateTime _civilDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

TaskItem _taskRow(RecurringTaskOccurrence occurrence) {
  if (occurrence.task.date != null) return occurrence.task;
  final day = occurrence.scheduledDate;
  return occurrence.task.withDate(DateTime(day.year, day.month, day.day));
}
