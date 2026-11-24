import 'dart:convert';
import 'dart:io';

import 'package:easy/scheduling/planner.dart';

void main(List<String> args) {
  final profile = args.isEmpty ? 'ordinary' : args[0];
  final spec = switch (profile) {
    'ordinary' => (days: 7, busy: 25, count: 850, effort: 30, gap: 20),
    'wide' => (days: 31, busy: 30, count: 15000, effort: 25, gap: 30),
    'packed' => (days: 21, busy: 180, count: 18000, effort: 1, gap: 3),
    'blocked' => (days: 31, busy: 180, count: 18000, effort: 15, gap: 3),
    _ => throw ArgumentError.value(profile),
  };
  final base = DateTime.utc(2030, 9, 2);
  DateTime at(int minute) => base.add(Duration(minutes: minute));
  final open = [
    for (var day = 0; day < spec.days; day++)
      PlanningWindow(
        TimeSpan(at(day * 1440 + 8 * 60), at(day * 1440 + 21 * 60)),
      ),
  ];
  final step = 13 * 60 ~/ spec.busy;
  final commitments = [
    for (var day = 0; day < spec.days; day++)
      for (var slot = 0; slot < spec.busy; slot++)
        if (step > spec.gap)
          FixedCommitment(
            TimeSpan(
              at(day * 1440 + 8 * 60 + slot * step),
              at(day * 1440 + 8 * 60 + slot * step + step - spec.gap),
            ),
          ),
  ];
  final tasks = [
    for (var index = 0; index < spec.count; index++)
      PlanningTask(
        id: 'work-${index.toString().padLeft(6, '0')}',
        title: 'Focus work $index',
        category: 'area-${index % 4}',
        remainingMinutes: spec.effort,
        allowSplit: profile != 'packed' && index.isEven,
        minimumChunkMinutes: profile == 'blocked' ? 5 : 1,
        earliest: profile == 'ordinary' && index % 10 == 0
            ? at((index % spec.days) * 1440 + 8 * 60)
            : null,
        deadline: profile == 'ordinary' && index % 5 == 0
            ? at(((index % spec.days) + 1) * 1440)
            : null,
      ),
  ];
  final watch = Stopwatch()..start();
  final plan = proposeSchedule(
    horizon: TimeSpan(base, at(spec.days * 1440)),
    availability: open,
    commitments: commitments,
    tasks: tasks,
  );
  watch.stop();
  var proof = 0;
  for (final placement in plan.scheduled) {
    for (final block in placement.blocks) {
      final start = block.start.difference(base).inMinutes;
      final end = block.end.difference(base).inMinutes;
      proof = (proof * 499 + start * 43 + end) % 2147483647;
    }
  }
  stdout.writeln(
    jsonEncode({
      'profile': profile,
      'days': spec.days,
      'commitments': commitments.length,
      'tasks': tasks.length,
      'scheduled': plan.scheduled.length,
      'unscheduled': plan.unscheduled.length,
      'placementProof': proof,
      'elapsedMs': watch.elapsedMilliseconds,
    }),
  );
}
