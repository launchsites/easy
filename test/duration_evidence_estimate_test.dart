import 'package:easy/activities/activity_model.dart';
import 'package:easy/ai/duration_evidence_estimate.dart';
import 'package:easy/task_context/task_context_index.dart';
import 'package:easy/task_context/task_context_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retains the exact median and range of the confirmed task series', () {
    final history = _history([
      1560,
      1620,
      1680,
      1740,
      1800,
      1860,
      1920,
      1980,
    ], cohort: TaskEvidenceCohort.series)!;
    expect(history.strength, TaskEvidenceStrength.consistent);
    final estimate = estimateFromConfirmedHistory(history)!;
    expect(estimate.duration, const Duration(minutes: 29, seconds: 30));
    expect(estimate.lower, history.lower);
    expect(estimate.upper, history.upper);
    expect(estimate.sampleCount, 8);
    expect(estimate.cohort, TaskEvidenceCohort.series);
    expect(estimate.strength, TaskEvidenceStrength.consistent);
    expect(estimate.requiresReview, isTrue);
  });

  test('uses the observed range for three matching recent tasks', () {
    final history = _history([900, 1200, 1320])!;
    final estimate = estimateFromConfirmedHistory(history)!;
    expect(estimate.duration, const Duration(minutes: 20));
    expect(estimate.lower, const Duration(minutes: 15));
    expect(estimate.upper, const Duration(minutes: 22));
    expect(estimate.cohort, TaskEvidenceCohort.titleAndCategory);
    expect(estimate.strength, TaskEvidenceStrength.indicative);
  });

  test('withholds absent, sparse and category-only evidence', () {
    expect(estimateFromConfirmedHistory(null), isNull);
    expect(estimateFromConfirmedHistory(_history([900, 1200])), isNull);
    final broad = _history([
      900,
      1200,
      1320,
      1260,
      1100,
    ], cohort: TaskEvidenceCohort.category)!;
    expect(broad.cohort, TaskEvidenceCohort.category);
    expect(estimateFromConfirmedHistory(broad), isNull);
  });

  test('uses the inclusive 90-day boundary for every median sample', () {
    final old = _history([1200, 1260, 1100], ageDays: [91, 94, 96]);
    expect(estimateFromConfirmedHistory(old), isNull);
    final mixed = _history([1200, 1260, 1100, 1300], ageDays: [2, 4, 8, 91]);
    expect(mixed?.last90DaysCount, 3);
    expect(estimateFromConfirmedHistory(mixed), isNull);
    final recent = _history([1200, 1260, 1100], ageDays: [2, 4, 90]);
    expect(estimateFromConfirmedHistory(recent)?.duration.inMinutes, 20);
  });

  test('withholds very dispersed or unsupported durations', () {
    expect(estimateFromConfirmedHistory(_history([60, 1200, 6000])), isNull);
    expect(estimateFromConfirmedHistory(_history([30, 31, 33])), isNull);
    expect(
      estimateFromConfirmedHistory(_history([86520, 86640, 86760])),
      isNull,
    );
    expect(
      estimateFromConfirmedHistory(_history([60, 60, 60]))?.duration,
      const Duration(minutes: 1),
    );
    expect(
      estimateFromConfirmedHistory(_history([86400, 86400, 86400]))?.duration,
      const Duration(hours: 24),
    );
  });
}

TaskDurationEvidence? _history(
  List<int> durationSeconds, {
  TaskEvidenceCohort cohort = TaskEvidenceCohort.titleAndCategory,
  List<int>? ageDays,
}) {
  final now = DateTime.utc(2026, 11, 24, 12);
  final series = cohort == TaskEvidenceCohort.series ? 'recurring' : null;
  final task = TaskContextTarget(
    id: 'target',
    title: 'Review project invoices',
    category: 'work',
    seriesId: series,
  );
  final tasks = [task];
  final activity = <ActivityRecord>[];
  for (final (index, seconds) in durationSeconds.indexed) {
    final id = 'task-$index';
    final title = cohort == TaskEvidenceCohort.category
        ? 'Other work $index'
        : cohort == TaskEvidenceCohort.series
        ? 'Review invoice batch $index'
        : task.title;
    final ended = now.subtract(Duration(days: ageDays?[index] ?? index + 2));
    tasks.add(
      TaskContextTarget(
        id: id,
        title: title,
        category: task.category,
        seriesId: series,
        completedAt: ended,
      ),
    );
    activity.add(
      ActivityRecord(
        id: 'time-$index',
        title: title,
        category: task.category,
        target: ActivityTarget(
          id: id,
          title: title,
          category: task.category,
          kind: ActivityTargetKind.task,
        ),
        spans: [
          ActivitySpan(
            start: ended.subtract(Duration(seconds: seconds)),
            end: ended,
          ),
        ],
        finishedAt: ended,
      ),
    );
  }
  return TaskContextIndex.build(
    tasks: tasks,
    activities: activity,
    asOf: now,
  ).evidenceFor(task).duration;
}
