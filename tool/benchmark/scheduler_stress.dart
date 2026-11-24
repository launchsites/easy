import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy/scheduling/planner.dart';

const seed = 20261124;

typedef Workload = ({
  String name,
  TimeSpan horizon,
  List<PlanningWindow> availability,
  List<FixedCommitment> commitments,
  List<PlanningTask> tasks,
});

Workload buildWorkload(
  String name, {
  required int days,
  required int taskCount,
  required int commitmentsPerDay,
}) {
  final random = Random(seed);
  final begin = DateTime.utc(2026, 11, 24);
  DateTime at(int day, int minute) =>
      begin.add(Duration(days: day, minutes: minute));
  const categories = ['work', 'study', 'personal', 'gym'];

  final availability = <PlanningWindow>[];
  final commitments = <FixedCommitment>[];
  for (var day = 0; day < days; day++) {
    availability.addAll([
      PlanningWindow(
        TimeSpan(at(day, 8 * 60), at(day, 12 * 60)),
        categories: {'work', 'study'},
      ),
      PlanningWindow(
        TimeSpan(at(day, 13 * 60), at(day, 16 * 60)),
        categories: {'work', 'personal'},
      ),
      PlanningWindow(
        TimeSpan(at(day, 17 * 60), at(day, 20 * 60)),
        categories: {'study', 'personal', 'gym'},
      ),
    ]);
    for (var index = 0; index < commitmentsPerDay; index++) {
      final start = 8 * 60 + random.nextInt(11 * 60);
      final minutes = 15 + random.nextInt(36);
      commitments.add(
        FixedCommitment(
          TimeSpan(at(day, start), at(day, start + minutes)),
          before: const Duration(minutes: 5),
          after: const Duration(minutes: 10),
        ),
      );
    }
  }

  final tasks = <PlanningTask>[];
  for (var index = 0; index < taskCount; index++) {
    final releaseDay = random.nextInt(days);
    final deadlineDay = min(days - 1, releaseDay + random.nextInt(5));
    tasks.add(
      PlanningTask(
        id: 'task-$index',
        title: 'Synthetic task $index',
        category: categories[random.nextInt(categories.length)],
        remainingMinutes: index % 37 == 0 ? null : 15 + random.nextInt(86),
        priority: PlannerPriority.values[random.nextInt(3)],
        earliest: at(releaseDay, 7 * 60 + random.nextInt(4 * 60)),
        deadline: at(deadlineDay, 18 * 60 + random.nextInt(3 * 60)),
        allowSplit: index.isEven,
        minimumChunkMinutes: 15,
        prerequisites: index % 5 == 1 ? {'task-${index - 1}'} : {},
        completed: index % 17 == 0,
      ),
    );
  }
  return (
    name: name,
    horizon: TimeSpan(begin, at(days, 0)),
    availability: availability,
    commitments: commitments,
    tasks: tasks,
  );
}

ScheduleProposal schedule(Workload input) => proposeSchedule(
  horizon: input.horizon,
  availability: input.availability,
  commitments: input.commitments,
  tasks: input.tasks,
);

void verify(Workload input, ScheduleProposal result) {
  final finished = {
    for (final task in input.tasks)
      if (task.completed) task.id: input.horizon.start,
    for (final task in result.scheduled) task.task.id: task.end,
  };
  final expected = {
    for (final task in input.tasks)
      if (!task.completed) task.id,
  };
  final blocked = [
    for (final commitment in input.commitments)
      TimeSpan(
        commitment.span.start.subtract(commitment.before),
        commitment.span.end.add(commitment.after),
      ),
  ];
  final blocks = <TimeSpan>[];
  for (final placement in result.scheduled) {
    final task = placement.task;
    if (!expected.remove(task.id)) {
      throw StateError('Unexpected or repeated decision for ${task.id}');
    }
    final received = placement.blocks.fold(
      0,
      (sum, block) => sum + block.length.inMinutes,
    );
    if (received != task.remainingMinutes ||
        (!task.allowSplit && placement.blocks.length != 1)) {
      throw StateError('Invalid assigned duration for ${task.id}');
    }
    for (final block in placement.blocks) {
      final inAvailability = input.availability.any(
        (window) =>
            window.allows(task.category) &&
            !block.start.isBefore(window.span.start) &&
            !block.end.isAfter(window.span.end),
      );
      if (!inAvailability ||
          block.start.isBefore(task.earliest!) ||
          block.end.isAfter(task.deadline!) ||
          block.start.isBefore(input.horizon.start) ||
          block.end.isAfter(input.horizon.end) ||
          blocked.any(block.overlaps) ||
          task.prerequisites.any(
            (id) =>
                !finished.containsKey(id) ||
                block.start.isBefore(finished[id]!),
          ) ||
          (placement.blocks.length > 1 &&
              block.length.inMinutes < task.minimumChunkMinutes)) {
        throw StateError('Invalid block for ${task.id}: ${block.start}');
      }
      blocks.add(block);
    }
  }
  for (final decision in result.unscheduled) {
    if (!expected.remove(decision.task.id)) {
      throw StateError(
        'Unexpected or repeated decision for ${decision.task.id}',
      );
    }
  }
  if (expected.isNotEmpty) throw StateError('Missing decisions: $expected');
  blocks.sort((a, b) => a.start.compareTo(b.start));
  for (var index = 1; index < blocks.length; index++) {
    if (blocks[index - 1].overlaps(blocks[index])) {
      throw StateError('Overlapping proposed blocks.');
    }
  }
}

Object signature(ScheduleProposal result) => [
  for (final placement in result.scheduled)
    [
      placement.task.id,
      for (final block in placement.blocks)
        [block.start.millisecondsSinceEpoch, block.end.millisecondsSinceEpoch],
    ],
  for (final decision in result.unscheduled)
    [decision.task.id, decision.problem.name, decision.prerequisiteId],
];

Map<String, Object> benchmark(Workload input, int repetitions) {
  final baseline = schedule(input);
  verify(input, baseline);
  final expected = jsonEncode(signature(baseline));
  final samples = <int>[];
  for (var index = 0; index < repetitions; index++) {
    final clock = Stopwatch()..start();
    final result = schedule(input);
    clock.stop();
    if (jsonEncode(signature(result)) != expected) {
      throw StateError('Non-deterministic result for ${input.name}');
    }
    samples.add(clock.elapsedMicroseconds);
  }
  final ordered = [...samples]..sort();
  return {
    'name': input.name,
    'tasks': input.tasks.length,
    'commitments': input.commitments.length,
    'availability_windows': input.availability.length,
    'scheduled': baseline.scheduled.length,
    'unscheduled': baseline.unscheduled.length,
    'claimed_blocks': baseline.scheduled.fold<int>(
      0,
      (count, task) => count + task.blocks.length,
    ),
    'sample_microseconds': samples,
    'median_ms': ordered[(ordered.length - 1) ~/ 2] / 1000,
    'p95_ms': ordered[(ordered.length * .95).ceil() - 1] / 1000,
    'max_ms': ordered.last / 1000,
    'process_peak_rss_bytes': ProcessInfo.maxRss,
  };
}

void main(List<String> arguments) {
  final repetitions = arguments.isEmpty ? 31 : int.parse(arguments.single);
  if (repetitions < 1) throw ArgumentError('Use at least one repetition.');
  final workloads = [
    buildWorkload(
      'two_week_mix',
      days: 14,
      taskCount: 160,
      commitmentsPerDay: 2,
    ),
    buildWorkload(
      'crowded_horizon',
      days: 60,
      taskCount: 1250,
      commitmentsPerDay: 6,
    ),
    buildWorkload(
      'oversubscribed',
      days: 90,
      taskCount: 3000,
      commitmentsPerDay: 6,
    ),
  ];
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'seed': seed,
      'at_utc': DateTime.now().toUtc().toIso8601String(),
      'dart': Platform.version,
      'operating_system': Platform.operatingSystemVersion,
      'repetitions': repetitions,
      'workloads': [
        for (final workload in workloads) benchmark(workload, repetitions),
      ],
    }),
  );
}
