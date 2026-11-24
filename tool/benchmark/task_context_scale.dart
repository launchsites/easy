import 'dart:convert';
import 'dart:io';

import 'package:easy/activities/activity_model.dart';
import 'package:easy/task_context/task_context.dart';

void main() {
  const total = 100000;
  const groupCount = 1500;
  const queryCount = 1000;
  final anchor = DateTime.utc(2026, 11, 24, 12);
  final tasks = <TaskContextTarget>[];
  final records = <ActivityRecord>[];
  for (var index = 0; index < total; index++) {
    final group = index % groupCount;
    final completed = anchor.subtract(Duration(days: index % 450 + 1));
    final task = TaskContextTarget(
      id: 'task-$index',
      title: 'Project $group handoff',
      category: 'category-${group % 9}',
      seriesId: group.isEven ? 'series-$group' : null,
      completedAt: completed,
    );
    tasks.add(task);
    final end = completed.subtract(const Duration(minutes: 1));
    final start = end.subtract(Duration(minutes: 12 + (index % 31)));
    records.add(
      ActivityRecord(
        id: 'activity-$index',
        title: task.title,
        category: task.category,
        target: ActivityTarget(
          id: task.id,
          title: task.title,
          category: task.category,
          kind: ActivityTargetKind.task,
        ),
        spans: [ActivitySpan(start: start, end: end)],
        finishedAt: end,
      ),
    );
  }
  final timer = Stopwatch()..start();
  final index = TaskContextIndex.build(
    tasks: tasks,
    activities: records,
    asOf: anchor,
  );
  timer.stop();
  final queries = <double>[];
  var samples = 0;
  for (var run = 0; run <= queryCount; run++) {
    final candidate = tasks[run * 197 % total];
    final timer = Stopwatch()..start();
    final evidence = index.evidenceFor(candidate);
    timer.stop();
    if (evidence.exactElapsed == null ||
        evidence.duration?.sampleCount != TaskContextIndex.sampleLimit) {
      throw StateError(
        'Synthetic history did not produce the expected evidence.',
      );
    }
    if (run > 0) {
      queries.add(timer.elapsedMicroseconds / 1000);
      samples += evidence.duration!.sampleCount;
    }
  }
  queries.sort();
  stdout.writeln(
    jsonEncode({
      'task_count': tasks.length,
      'activity_count': records.length,
      'indexed_matching_groups': groupCount,
      'query_count': queryCount,
      'build_ms': timer.elapsedMicroseconds / 1000,
      'query_p50_ms': queries[queryCount ~/ 2],
      'query_p95_ms': queries[queryCount * 95 ~/ 100],
      'sample_total': samples,
      'rss_mib': (ProcessInfo.currentRss / (1 << 20)).round(),
    }),
  );
}
