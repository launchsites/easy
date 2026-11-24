import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_workspace_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final first = DateTime(2026, 11, 24);
  const plain = TaskItem(id: 'plain', title: 'Independent', category: 'work');
  const repeating = TaskItem(
    id: 'repeat',
    title: 'Send the report',
    category: '',
    estimatedMinutes: 20,
  );
  final originals = [plain, repeating];

  RecurringTaskSeries daily() => RecurringTaskSeries(
    id: repeating.id,
    task: repeating,
    startDate: first,
    rule: InternalRecurrenceRule(frequency: InternalRecurrenceFrequency.daily),
  );

  test('uses one template with bounded independent occurrence rows', () {
    final series = daily();
    final feed = TaskWorkspaceFeed(readTaskSeries([series.toJson()]));
    final today = DateTime(2026, 11, 26);
    final visible = feed.workspaceTasks(originals, today);
    expect(visible.length, 16);
    expect(feed.workspaceTasks(originals, today), same(visible));
    expect(visible.where((task) => task.id == repeating.id), isEmpty);
    expect(visible.first, same(plain));
    expect(visible[1].date, today);
    expect(visible[1].category, isEmpty);
    expect(feed.planningTasks(originals, today), [plain, sameTask(visible[1])]);
    expect(feed.reviewTasks(originals, first).last.date, first);

    final done = series.complete(
      series.occurrences(windowStart: first, windowEnd: today).first,
      at: DateTime.utc(2026, 11, 24, 19),
    );
    final later = TaskWorkspaceFeed(readTaskSeries([done.toJson()]));
    expect(
      later.workspaceTasks(originals, today)[1].completedAt,
      DateTime.utc(2026, 11, 24, 19),
    );
    expect(later.insightTasks(originals).last.done, isTrue);
    expect(later.planningTasks(originals, first), [plain]);
  });

  test(
    'rejects duplicate durable series and protects a colliding standalone ID',
    () {
      final series = daily();
      final encoded = series.toJson();
      expect(() => readTaskSeries([encoded, encoded]), throwsFormatException);
      final expected = series
          .occurrences(windowStart: first, windowEnd: DateTime(2026, 11, 25))
          .single;
      final collision = TaskItem(
        id: expected.id,
        title: 'Already occupied',
        category: 'work',
      );
      final records = [...originals, collision];
      final feed = TaskWorkspaceFeed([series]);
      expect(feed.planningTasks(records, first), [plain, collision]);
      expect(feed.row(collision.id, records, first, sourceDate: first), isNull);
    },
  );

  test('rule edits can move civil fields across daylight saving', () {
    final series = RecurringTaskSeries(
      id: 'london',
      task: TaskItem(
        id: 'london',
        title: 'Check the file',
        category: 'work',
        date: DateTime(2026, 3, 27),
        earliestStart: DateTime.utc(2026, 3, 27, 9),
        dueAt: DateTime.utc(2026, 3, 27, 15),
      ),
      startDate: DateTime(2026, 3, 27),
      timeZoneId: 'Europe/London',
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.daily,
      ),
    );
    final first = series
        .occurrences(
          windowStart: DateTime(2026, 3, 27),
          windowEnd: DateTime(2026, 3, 28),
        )
        .single;
    final shifted = series.fieldsForDate(first, DateTime(2026, 3, 30));
    expect(shifted.earliestStart?.toUtc(), DateTime.utc(2026, 3, 30, 8));
    expect(shifted.dueAt?.toUtc(), DateTime.utc(2026, 3, 30, 14));
    expect(shifted.date, DateTime(2026, 3, 30));
  });
}

Matcher sameTask(TaskItem task) => isA<TaskItem>()
    .having((other) => other.id, 'id', task.id)
    .having((other) => other.date, 'date', task.date);
