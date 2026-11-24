import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:easy/ai/automatic_estimate_order.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/task_workspace_feed.dart' show maximumTaskSeries;

typedef _Input = ({List<TaskItem> tasks, Set<String> recurringBaseIds});

enum _Profile { allEligible, mixedHistory, mostlyIneligible }

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 120000 : int.parse(args.single);
  if (count < 100) throw ArgumentError.value(count, 'task count', 'Use ≥100');

  final startup = <int>[];
  for (var run = 0; run < 15; run++) {
    final watch = Stopwatch()..start();
    await Isolate.run(() => 1);
    if (run >= 3) startup.add(watch.elapsedMicroseconds);
  }

  final profiles = <Map<String, Object?>>[];
  for (final profile in _Profile.values) {
    final input = _buildInput(count, profile);
    final expected = _previousOrder(input.tasks)
        .where((task) => _previousEligible(task, input.recurringBaseIds))
        .map((task) => task.id)
        .toList();
    _checkOrder(expected, _rank(input));
    _checkOrder(expected, await _rankInWorker(input));
    _checkOrder(expected, (await _cooperativeRank(input)).ranked);

    final previous = <int>[];
    final synchronous = <int>[];
    final transferOnly = <int>[];
    final workerSubmission = <int>[];
    final worker = <int>[];
    final cooperative = <int>[];
    final cooperativeTurnGaps = <int>[];
    for (var run = 0; run < 15; run++) {
      final watch = Stopwatch()..start();
      final previousFirst = _previousOrder(
        input.tasks,
      ).firstWhere((task) => _previousEligible(task, input.recurringBaseIds));
      if (run >= 3) previous.add(watch.elapsedMicroseconds);
      if (previousFirst.id != expected.first) {
        throw StateError('Previous first candidate changed');
      }

      watch.reset();
      final candidates = _rank(input);
      if (run >= 3) synchronous.add(watch.elapsedMicroseconds);
      _checkFirstAndLength(expected, candidates);

      watch.reset();
      final transferred = await _transferInput(input);
      if (run >= 3) transferOnly.add(watch.elapsedMicroseconds);
      if (transferred != count + input.recurringBaseIds.length) {
        throw StateError('Ranking input was truncated during transfer');
      }

      watch.reset();
      final ranking = _rankInWorker(input);
      if (run >= 3) workerSubmission.add(watch.elapsedMicroseconds);
      final ranked = await ranking;
      if (run >= 3) worker.add(watch.elapsedMicroseconds);
      _checkFirstAndLength(expected, ranked);

      watch.reset();
      final chunked = await _cooperativeRank(input);
      if (run >= 3) {
        cooperative.add(watch.elapsedMicroseconds);
        cooperativeTurnGaps.addAll(chunked.turnGaps);
      }
      _checkFirstAndLength(expected, chunked.ranked);
    }

    profiles.add({
      'profile': profile.name,
      'candidate_count': expected.length,
      'recurring_base_count': input.recurringBaseIds.length,
      'full_order_matches': true,
      'previous_sort_and_first_eligible_ms': _stats(previous),
      'rank_sync_ms': _stats(synchronous),
      'worker_input_and_startup_ms': _stats(transferOnly),
      'worker_submission_ms': _stats(workerSubmission),
      'worker_rank_round_trip_ms': _stats(worker),
      'cooperative_rank_ms': _stats(cooperative),
      'cooperative_event_turn_gap_ms': {
        ..._stats(cooperativeTurnGaps),
        'max': cooperativeTurnGaps.last / 1000,
      },
    });
  }

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'task_count_per_profile': count,
      'warmups': 3,
      'measured_runs': 12,
      'empty_worker_startup_ms': _stats(startup),
      'profiles': profiles,
      'process_peak_rss_mib': (ProcessInfo.maxRss / (1 << 20)).round(),
    }),
  );
}

_Input _buildInput(int count, _Profile profile) {
  final random = Random(197);
  final anchor = DateTime.utc(2026, 11, 24);
  final dueDates = List.generate(
    1820,
    (day) => anchor.add(Duration(days: day)),
  );
  final tasks = <TaskItem>[];
  final recurringBaseIds = <String>{};
  final oversize = 'x' * 301;
  for (var index = 0; index < count; index++) {
    final id = 'task-$index';
    final slot = index % 100;
    final done = profile == _Profile.mixedHistory && slot < 82;
    final estimated = profile == _Profile.mixedHistory && slot < 92;
    final restrictions = switch (profile) {
      _Profile.allEligible => 0,
      _Profile.mixedHistory => slot >= 92 && slot < 96 ? slot - 91 : 0,
      _Profile.mostlyIneligible => slot < 96 ? slot % 3 + 1 : 0,
    };
    final recurring =
        restrictions == 2 && recurringBaseIds.length < maximumTaskSeries;
    if (recurring) recurringBaseIds.add(id);
    final held = restrictions == 1 || (restrictions == 2 && !recurring);
    final nominalDate = dueDates[random.nextInt(dueDates.length)];
    tasks.add(
      TaskItem(
        id: id,
        title: restrictions == 3
            ? oversize
            : 'Follow up on project item $index',
        category: 'category-${index % 8}',
        date: index % 4 == 0 ? null : nominalDate,
        dueAt: index % 7 == 0
            ? nominalDate.add(const Duration(hours: 2))
            : null,
        completedAt: done ? nominalDate : null,
        done: done,
        priority: index % 4 == 3 ? null : TaskPriority.values[index % 4],
        notes: index.isEven ? 'Reference $index for the next check-in.' : null,
        estimatedMinutes: estimated ? 20 : null,
        prerequisiteIds: index.isOdd ? ['task-${index - 1}'] : const [],
        schedulingHold: held
            ? const TaskSchedulingHold(reason: TaskSchedulingHoldReason.details)
            : null,
      ),
    );
  }
  tasks.shuffle(random);
  return (
    tasks: List.unmodifiable(tasks),
    recurringBaseIds: Set.unmodifiable(recurringBaseIds),
  );
}

// This is the original Main path up to the first statically eligible candidate.
List<TaskItem> _previousOrder(List<TaskItem> tasks) =>
    tasks.where((task) => !task.done && task.estimatedMinutes == null).toList()
      ..sort((first, second) {
        final a = first.dueAt ?? first.date;
        final b = second.dueAt ?? second.date;
        if (a != null && b != null) {
          final order = a.compareTo(b);
          if (order != 0) return order;
        }
        if ((a == null) != (b == null)) return a == null ? 1 : -1;
        final priority = (second.priority ?? TaskPriority.normal).index
            .compareTo((first.priority ?? TaskPriority.normal).index);
        return priority == 0 ? first.id.compareTo(second.id) : priority;
      });

bool _previousEligible(TaskItem task, Set<String> recurringBaseIds) =>
    !task.done &&
    !recurringBaseIds.contains(task.id) &&
    task.schedulingHold == null &&
    task.estimatedMinutes == null &&
    task.title.length <= 300;

List<TaskItem> _rank(_Input input) => rankAutomaticEstimateTasks(
  input.tasks,
  recurringBaseIds: input.recurringBaseIds,
);

Future<List<TaskItem>> _rankInWorker(_Input input) =>
    Isolate.run(() => _rank(input));

Future<int> _transferInput(_Input input) =>
    Isolate.run(() => input.tasks.length + input.recurringBaseIds.length);

Future<({List<TaskItem> ranked, List<int> turnGaps})> _cooperativeRank(
  _Input input,
) async {
  final gaps = <int>[];
  final watch = Stopwatch()..start();
  var active = true;
  void tick() {
    if (!active) return;
    gaps.add(watch.elapsedMicroseconds);
    watch.reset();
    Timer.run(tick);
  }

  Timer.run(tick);
  final ranked = await rankAutomaticEstimateTasksCooperatively(
    input.tasks,
    recurringBaseIds: input.recurringBaseIds,
  );
  active = false;
  gaps.add(watch.elapsedMicroseconds);
  if (ranked == null) throw StateError('Ranking unexpectedly cancelled');
  return (ranked: ranked, turnGaps: gaps);
}

void _checkOrder(List<String> expected, List<TaskItem> actual) {
  _checkFirstAndLength(expected, actual);
  for (var index = 1; index < expected.length; index++) {
    if (expected[index] != actual[index].id) {
      throw StateError('Candidate order changed at position $index');
    }
  }
}

void _checkFirstAndLength(List<String> expected, List<TaskItem> actual) {
  if (expected.length != actual.length || expected.first != actual.first.id) {
    throw StateError('Candidate count or first candidate changed');
  }
}

Map<String, double> _stats(List<int> times) {
  times.sort();
  final midpoint = times.length ~/ 2;
  return {
    'p50': times.length.isOdd
        ? times[midpoint] / 1000
        : (times[midpoint - 1] + times[midpoint]) / 2000,
    'p95': times[(times.length * .95).ceil() - 1] / 1000,
  };
}
