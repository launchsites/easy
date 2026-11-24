import 'dart:convert';

import 'package:easy/scheduling/planner.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an undated template starts today without acquiring a due or preferred date', () {
    final series = RecurringTaskSeries(
      id: 'today',
      task: _task(),
      rule: _daily(count: 2),
      today: DateTime.utc(2026, 11, 24, 2),
      timeZoneId: 'America/New_York',
    );
    final visible = _days(series, 23, 27);
    expect(visible.map((item) => item.scheduledDate.day), [23, 24]);
    for (final item in visible) {
      expect(item.task.date, isNull);
      expect(item.task.dueAt, isNull);
      expect(item.task.earliestStart, isNull);
      expect(item.reminderAt, isNull);
    }
    final dated = RecurringTaskSeries(
      id: 'dated',
      task: _task(date: DateTime(2026, 11, 25)),
      rule: _daily(count: 2),
      today: DateTime.utc(2026, 11, 24),
    );
    expect(_days(dated, 23, 28).map((item) => item.task.date?.day), [25, 26]);
    expect(
      _days(dated, 23, 28).every((item) => item.task.dueAt == null),
      isTrue,
    );
  });

  test(
    'completion and one skip preserve upcoming IDs and survive serialization',
    () {
      final initial = _series();
      final initialRows = _days(initial, 24, 30);
      final completed = initial.complete(
        initialRows[0],
        at: DateTime.utc(2026, 11, 24, 15),
      );
      expect(
        () => completed.complete(initialRows[1], at: DateTime.utc(2026)),
        throwsStateError,
      );
      final skipped = completed.skip(
        _days(completed, 24, 30)[1],
        scope: InternalOccurrenceScope.one,
      );
      final restored = _reopen(skipped);
      final visible = _days(restored, 24, 30);
      expect(visible.map((item) => item.id), [
        initialRows[0].id,
        initialRows[2].id,
        initialRows[3].id,
        initialRows[4].id,
      ]);
      expect(visible.first.task.done, isTrue);
      expect(visible.first.task.completedAt, DateTime.utc(2026, 11, 24, 15));
      expect(visible.skip(1).every((item) => !item.task.done), isTrue);
      final all = _days(restored, 24, 30, includeSkipped: true);
      expect(all[1].id, initialRows[1].id);
      expect(all[1].status, RecurringTaskStatus.skipped);
      final undone = restored.reopen(all[1]);
      expect(
        _days(undone, 24, 30).map((item) => item.id),
        initialRows.map((item) => item.id),
      );
      expect((skipped.toJson()['outcomes'] as List).length, 2);
      expect((skipped.toJson()['templates'] as List).length, 1);
    },
  );

  test(
    'one move and future edit keep stable rows and frozen completion history',
    () {
      final initial = _series();
      final before = _days(initial, 24, 30);
      final moved = initial.edit(
        before[1],
        scope: InternalOccurrenceScope.one,
        task: _task(title: 'Moved'),
        startDate: DateTime(2026, 11, 29),
      );
      final movedRows = _days(moved, 24, 30);
      expect(movedRows.last.id, before[1].id);
      expect(movedRows.last.scheduledDate.day, 29);
      final completed = moved.complete(
        movedRows.last,
        at: DateTime.utc(2026, 11, 29, 12),
      );
      final upcoming = _days(completed, 24, 30);
      final changed = completed.edit(
        upcoming[1],
        scope: InternalOccurrenceScope.future,
        task: _task(title: 'Revised'),
      );
      final result = _days(_reopen(changed), 24, 30);
      expect(result.map((item) => item.task.title), [
        'Wash',
        'Revised',
        'Revised',
        'Revised',
        'Moved',
      ]);
      expect(result.last.status, RecurringTaskStatus.completed);
      expect(
        result.map((item) => item.id).toSet(),
        before.map((item) => item.id).toSet(),
      );
      final all = changed.edit(
        _days(changed, 24, 30).first,
        scope: InternalOccurrenceScope.series,
        task: _task(title: 'Always revised'),
      );
      expect(_days(all, 24, 30).map((item) => item.task.title), [
        'Always revised',
        'Always revised',
        'Always revised',
        'Always revised',
        'Moved',
      ]);
      expect(all.id, initial.id);
    },
  );

  test(
    'future and series skips keep history while removing pending coverage',
    () {
      final initial = _series();
      final completed = initial.complete(
        _days(initial, 24, 30).first,
        at: DateTime.utc(2026, 11, 24, 13),
      );
      final future = completed.skip(
        _days(completed, 24, 30)[2],
        scope: InternalOccurrenceScope.future,
      );
      expect(_days(future, 24, 30).map((item) => item.scheduledDate.day), [
        24,
        25,
      ]);
      final stopped = future.skip(
        _days(future, 24, 30)[1],
        scope: InternalOccurrenceScope.series,
      );
      final history = _days(_reopen(stopped), 24, 30);
      expect(history.single.status, RecurringTaskStatus.completed);
      expect(history.single.scheduledDate.day, 24);
    },
  );

  test('named clocks preserve dates across DST and flag gaps in explicit constraints', () {
    final series = RecurringTaskSeries(
      id: 'clock',
      task: _task(
        date: DateTime(2026, 3, 7),
        earliest: DateTime.utc(2026, 3, 7, 7, 30),
        due: DateTime.utc(2026, 3, 7, 18),
      ),
      startDate: DateTime(2026, 3, 7),
      timeZoneId: 'America/New_York',
      rule: _daily(count: 3),
      reminder: TaskReminderPreference(minuteOfDay: 8 * 60),
    );
    final rows = _reopen(series).occurrences(
      windowStart: DateTime(2026, 3, 7),
      windowEnd: DateTime(2026, 3, 11),
    );
    expect(rows.map((row) => row.task.date?.day), [7, 8, 9]);
    expect(rows.map((row) => row.task.earliestStart), [
      DateTime.utc(2026, 3, 7, 7, 30),
      null,
      DateTime.utc(2026, 3, 9, 6, 30),
    ]);
    expect(rows.map((row) => row.task.dueAt?.hour), [18, 17, 17]);
    expect(rows.map((row) => row.reminderAt?.hour), [13, 12, 12]);
    expect(rows[1].canSchedule, isFalse);
    expect(
      rows[1].constraintIssue,
      RecurringTaskScheduleIssue.unavailableClock,
    );
    expect(rows.last.canSchedule, isTrue);
  });

  test('an explicit due time in the second clock fold keeps its instant', () {
    final due = DateTime.utc(2026, 10, 25, 1, 30, 18, 32, 120);
    final series = RecurringTaskSeries(
      id: 'fold',
      task: _task(due: due),
      startDate: DateTime(2026, 10, 25),
      timeZoneId: 'Europe/London',
      rule: _daily(count: 2),
    );
    final rows = _reopen(series).occurrences(
      windowStart: DateTime(2026, 10, 25),
      windowEnd: DateTime(2026, 10, 27),
    );
    expect(rows.first.task.dueAt, due);
    expect(
      rows.last.task.dueAt,
      DateTime.utc(2026, 10, 26, 1, 30, 18, 32, 120),
    );
  });

  test(
    'manual scheduling checks timing, prerequisites, availability and overlap',
    () {
      final series = _series(
        task: _task(
          date: DateTime(2026, 11, 24),
          earliest: DateTime.utc(2026, 11, 24, 8),
          due: DateTime.utc(2026, 11, 24, 18),
          prerequisites: ['prep'],
          estimatedMinutes: 30,
        ),
      );
      final first = _days(series, 24, 30).first;
      TimeSpan block(int from, int end) => TimeSpan(
        DateTime.utc(2026, 11, 24, from),
        DateTime.utc(2026, 11, 24, end),
      );
      expect(
        series.manualScheduleIssue(first, span: block(7, 8)),
        RecurringTaskScheduleIssue.beforeEarliest,
      );
      expect(
        series.manualScheduleIssue(first, span: block(17, 19)),
        RecurringTaskScheduleIssue.afterDeadline,
      );
      expect(
        series.manualScheduleIssue(first, span: block(10, 11)),
        RecurringTaskScheduleIssue.prerequisite,
      );
      expect(
        series.manualScheduleIssue(
          first,
          span: block(10, 11),
          completedPrerequisiteIds: {'prep'},
          availability: [
            PlanningWindow(block(10, 11), categories: {'study'}),
          ],
        ),
        RecurringTaskScheduleIssue.unavailable,
      );
      expect(
        series.manualScheduleIssue(
          first,
          span: block(10, 11),
          completedPrerequisiteIds: {'prep'},
          commitments: [block(9, 11)],
        ),
        RecurringTaskScheduleIssue.commitment,
      );
      final scheduled = series.scheduleManually(
        first,
        span: block(10, 11),
        completedPrerequisiteIds: {'prep'},
        availability: [PlanningWindow(block(9, 12))],
        commitments: [block(9, 10), block(11, 12)],
      );
      final restored = _reopen(scheduled);
      final located = _days(restored, 24, 30).first;
      expect(located.manualSchedule?.start, block(10, 11).start);
      expect(
        () => restored.edit(
          located,
          scope: InternalOccurrenceScope.one,
          task: _task(due: DateTime.utc(2026, 11, 24, 10)),
        ),
        throwsA(isA<RecurringTaskScheduleException>()),
      );
    },
  );

  test('a soft date can be deliberately overridden and replay does not duplicate blocks', () {
    final series = _series(task: _task(date: DateTime(2026, 11, 24)));
    final first = _days(series, 24, 30).first;
    final moved = TimeSpan(
      DateTime.utc(2026, 11, 25, 10),
      DateTime.utc(2026, 11, 25, 11),
    );
    expect(
      series.manualScheduleIssue(first, span: moved),
      RecurringTaskScheduleIssue.softDate,
    );
    final scheduled = series.scheduleManually(
      first,
      span: moved,
      allowOutsideSoftDate: true,
    );
    final rows = _days(scheduled, 24, 30);
    expect(
      scheduled.manualScheduleIssue(rows[1], span: moved),
      RecurringTaskScheduleIssue.commitment,
    );
    final completed = scheduled.complete(
      rows[0],
      at: DateTime.utc(2026, 11, 25, 11),
    );
    final restored = _reopen(completed);
    expect(_days(restored, 24, 30).first.manualSchedule?.start, moved.start);
    expect(
      restored.manualScheduleIssue(_days(restored, 24, 30)[1], span: moved),
      isNull,
    );
    final open = restored.reopen(_days(restored, 24, 30).first);
    expect(_days(open, 24, 30).first.manualSchedule, isNull);
  });

  test('manual changes can use a soft date while retaining a missing hard deadline', () {
    final series = _series(task: _task(date: DateTime(2026, 11, 24)));
    expect(_days(series, 24, 30).first.task.dueAt, isNull);
    expect(
      () => series.occurrences(
        windowStart: DateTime(2026),
        windowEnd: DateTime(2029),
      ),
      throwsArgumentError,
    );
    expect(
      () => _series(
        task: _task(
          earliest: DateTime.utc(2026, 11, 24, 15),
          due: DateTime.utc(2026, 11, 24, 14),
        ),
      ),
      throwsArgumentError,
    );
  });
}

TaskItem _task({
  String title = 'Wash',
  DateTime? date,
  DateTime? earliest,
  DateTime? due,
  List<String> prerequisites = const [],
  int? estimatedMinutes,
}) => TaskItem(
  id: 'base',
  title: title,
  category: 'personal',
  date: date,
  earliestStart: earliest,
  dueAt: due,
  prerequisiteIds: prerequisites,
  estimatedMinutes: estimatedMinutes,
);

InternalRecurrenceRule _daily({int count = 5}) => InternalRecurrenceRule(
  frequency: InternalRecurrenceFrequency.daily,
  count: count,
);

RecurringTaskSeries _series({TaskItem? task}) => RecurringTaskSeries(
  id: 'task/wash',
  task: task ?? _task(),
  startDate: DateTime.utc(2026, 11, 24),
  timeZoneId: 'Etc/UTC',
  rule: _daily(),
);

RecurringTaskSeries _reopen(RecurringTaskSeries series) =>
    RecurringTaskSeries.fromJson(
      jsonDecode(jsonEncode(series.toJson())) as Map<String, Object?>,
    );

List<RecurringTaskOccurrence> _days(
  RecurringTaskSeries series,
  int from,
  int until, {
  bool includeSkipped = false,
}) => series.occurrences(
  windowStart: DateTime(2026, 11, from),
  windowEnd: DateTime(2026, 11, until),
  includeSkipped: includeSkipped,
);
