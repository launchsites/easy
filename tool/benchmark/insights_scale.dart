import 'dart:convert';
import 'dart:io';

import 'package:easy/insights/insight_models.dart';
import 'package:easy/insights/insight_report.dart';
import 'package:easy/insights/duration_learning.dart';

void main() {
  final now = DateTime(2026, 11, 24);
  final start = shiftInsightDay(now, -365);
  const categories = ['work', 'study', 'fitness', 'personal', 'routine'];
  DateTime date(int index) => shiftInsightDay(
    start,
    index % 365,
  ).add(Duration(hours: 8 + index % 12, minutes: index % 30));
  final tasks = [
    for (var index = 0; index < 100000; index++)
      InsightTask(
        id: 'task-$index',
        title: 'Synthetic task ${index % 85}',
        category: categories[index % categories.length],
        projectId: 'project-${index % 40}',
        taskType: 'sample',
        dueAt: index % 3 == 0
            ? date(index).add(const Duration(hours: 2))
            : null,
        completedAt: index % 7 == 0
            ? null
            : date(index).add(const Duration(hours: 1)),
        forecastMinutes: index % 3 == 0 ? 32 : null,
      ),
  ];
  final activities = [
    for (var index = 0; index < 50000; index++)
      InsightActivity(
        id: 'activity-$index',
        category: categories[index % categories.length],
        taskId: 'task-$index',
        spans: [
          InsightWindow(
            date(index),
            date(index).add(const Duration(minutes: 27)),
          ),
          InsightWindow(
            date(index).add(const Duration(minutes: 20)),
            date(index).add(const Duration(minutes: 39)),
          ),
        ],
      ),
  ];
  final plans = [
    for (var index = 0; index < 30000; index++)
      InsightPlan(
        id: 'plan-$index',
        category: categories[index % categories.length],
        initial: InsightWindow(
          date(index),
          date(index).add(const Duration(minutes: 30)),
        ),
        accepted: InsightWindow(
          date(index).add(const Duration(minutes: 6)),
          date(index).add(const Duration(minutes: 36)),
        ),
        actual: index % 7 == 0 ? const [] : activities[index].spans,
        outcome: index % 7 == 0
            ? InsightPlanOutcome.skipped
            : InsightPlanOutcome.completed,
      ),
  ];
  InsightReport work() => buildInsightReport(
    range: InsightRange(start, now),
    activities: activities,
    tasks: tasks,
    plans: plans,
  );
  work();
  final timings = <double>[];
  InsightReport? latest;
  for (var index = 0; index < 11; index++) {
    final clock = Stopwatch()..start();
    latest = work();
    timings.add(clock.elapsedMicroseconds / 1000);
  }
  timings.sort();
  final learningClock = Stopwatch()..start();
  final samples = buildDurationObservations(
    tasks: tasks,
    activities: activities,
  );
  final result = learnDuration(tasks.last, samples);
  stdout.writeln(
    jsonEncode({
      'tasks': tasks.length,
      'activities': activities.length,
      'plans': plans.length,
      'repetitions': timings.length,
      'median_ms': timings[5],
      'max_ms': timings.last,
      'rss_mib': (ProcessInfo.currentRss / (1 << 20)).round(),
      'learning_ms': learningClock.elapsedMicroseconds / 1000,
      'samples': samples.length,
      'cohort': result?.samples,
      'recorded_days': latest?.days.length,
      'completed': latest?.completedTasks,
    }),
  );
}
