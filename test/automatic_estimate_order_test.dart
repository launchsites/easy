import 'package:easy/ai/automatic_estimate_order.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('excludes tasks that cannot be sent for automatic estimates', () {
    final eligible = _task('eligible', title: '🧪' * 150);
    final recurring = _task('recurring-base');
    final tasks = [
      _task('completed', done: true),
      _task('estimated', minutes: 30),
      _task('legacy-zero-estimate', minutes: 0),
      _task('legacy-negative-estimate', minutes: -1),
      for (final reason in TaskSchedulingHoldReason.values)
        _task(reason.name, hold: TaskSchedulingHold(reason: reason)),
      _task('oversize', title: '${'🧪' * 150}a'),
      recurring,
      eligible,
    ];

    final candidates = rankAutomaticEstimateTasks(
      tasks,
      recurringBaseIds: {'recurring-base'},
    );

    expect(candidates.single, same(eligible));
    expect(rankAutomaticEstimateTasks([recurring]).single, same(recurring));
    expect(
      rankAutomaticEstimateTasks(
        tasks.where((task) => task != eligible),
        recurringBaseIds: {recurring.id},
      ),
      isEmpty,
    );
    expect(rankAutomaticEstimateTasks(const <TaskItem>[]), isEmpty);
  });

  test('orders by due or scheduled instant before priority and ID', () {
    final first = DateTime.utc(2026, 11, 24, 9, 1, 2, 3, 4);
    final second = first.add(const Duration(microseconds: 1));
    final earlier = first.subtract(const Duration(days: 1));
    final candidates = rankAutomaticEstimateTasks(
      [
        _task('due-over-date', dueAt: second, date: earlier),
        _task('aaa', date: first),
        _task('bbb', dueAt: first.toLocal(), priority: TaskPriority.normal),
        _task('zz-dated-high', date: first, priority: TaskPriority.high),
        _task('undated-high', priority: TaskPriority.high),
        _task('dated-low', dueAt: first, priority: TaskPriority.low),
        _task('undated-normal'),
        _task('undated-low', priority: TaskPriority.low),
      ].reversed,
    );

    expect(candidates.map((task) => task.id), [
      'zz-dated-high',
      'aaa',
      'bbb',
      'dated-low',
      'due-over-date',
      'undated-high',
      'undated-normal',
      'undated-low',
    ]);
  });

  test('returns an immutable snapshot without sorting the source', () {
    final last = _task('z');
    final first = _task('a');
    final tasks = [last, first];

    final candidates = rankAutomaticEstimateTasks(tasks);

    expect(tasks, [same(last), same(first)]);
    expect(candidates, [same(first), same(last)]);
    expect(() => candidates.add(_task('another')), throwsUnsupportedError);
    expect(() => candidates[0] = last, throwsUnsupportedError);
    tasks.clear();
    expect(candidates, [same(first), same(last)]);
  });

  test(
    'cooperative order matches the synchronous snapshot across slices',
    () async {
      final start = DateTime.utc(2026, 11, 24);
      final tasks = List.generate(5197, (index) {
        return _task(
          'task-$index',
          date: index.isOdd
              ? start.add(Duration(microseconds: index * 2531 % 1777))
              : null,
          dueAt: index % 13 == 0 ? start : null,
          priority: TaskPriority.values[index % TaskPriority.values.length],
          done: index % 43 == 0,
          minutes: index % 81 == 0 ? 10 : null,
          hold: index % 31 == 0
              ? const TaskSchedulingHold(
                  reason: TaskSchedulingHoldReason.details,
                )
              : null,
        );
      });
      final recurringBaseIds = {'task-3', 'task-5000'};
      final expected = rankAutomaticEstimateTasks(
        tasks,
        recurringBaseIds: recurringBaseIds,
      );
      var reachedEventQueue = false;
      final event = Future<void>.delayed(Duration.zero, () {
        reachedEventQueue = true;
      });

      final ranked = await rankAutomaticEstimateTasksCooperatively(
        tasks,
        recurringBaseIds: recurringBaseIds,
      );

      expect(reachedEventQueue, isTrue);
      await event;
      expect(ranked, expected);
      expect(() => ranked!.clear(), throwsUnsupportedError);
      expect(tasks.first.id, 'task-0');
    },
  );

  test('cooperative scan stops after a cancellation event', () async {
    final tasks = List.generate(5000, (index) => _task('task-$index'));
    var scanned = 0;
    final counted = tasks.where((task) {
      scanned++;
      return true;
    });
    var cancelled = false;
    final event = Future<void>.delayed(Duration.zero, () {
      cancelled = true;
    });

    final ranked = await rankAutomaticEstimateTasksCooperatively(
      counted,
      shouldCancel: () => cancelled,
    );

    await event;
    expect(ranked, isNull);
    expect(scanned, inExclusiveRange(0, tasks.length));
    expect(
      await rankAutomaticEstimateTasksCooperatively(
        counted,
        shouldCancel: () => true,
      ),
      isNull,
    );
  });

  test(
    'cooperative merge checks cancellation before returning a result',
    () async {
      final tasks = List.generate(5197, (index) => _task('task-$index'));
      var scanned = 0;
      final counted = tasks.where((task) {
        scanned++;
        return true;
      });

      final ranked = await rankAutomaticEstimateTasksCooperatively(
        counted,
        shouldCancel: () => scanned == tasks.length,
      );

      expect(scanned, tasks.length);
      expect(ranked, isNull);
    },
  );
}

TaskItem _task(
  String id, {
  String title = 'Read notes',
  DateTime? date,
  DateTime? dueAt,
  bool done = false,
  int? minutes,
  TaskPriority? priority,
  TaskSchedulingHold? hold,
}) => TaskItem(
  id: id,
  title: title,
  category: 'Work',
  date: date,
  dueAt: dueAt,
  done: done,
  estimatedMinutes: minutes,
  priority: priority,
  schedulingHold: hold,
);
