import 'package:easy/activities/activity_model.dart';
import 'package:easy/task_context/task_context.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

final _now = DateTime.utc(2026, 11, 24, 17);

TaskContextTarget _task(
  String id, {
  String title = 'Client handoff',
  String category = 'work',
  String? seriesId,
  DateTime? completed,
}) => TaskContextTarget(
  id: id,
  title: title,
  category: category,
  seriesId: seriesId,
  completedAt: completed,
);

ActivityRecord _log(
  TaskContextTarget task,
  DateTime start,
  int minutes, {
  String? id,
  ActivityTargetKind? kind = ActivityTargetKind.task,
  bool finished = true,
  bool split = false,
}) {
  final end = start.add(Duration(minutes: minutes + (split ? 6 : 0)));
  return ActivityRecord(
    id: id ?? 'activity-${task.id}',
    title: task.title,
    category: task.category,
    target: kind == null
        ? null
        : ActivityTarget(
            id: task.id,
            title: task.title,
            category: task.category,
            kind: kind,
          ),
    spans: [
      if (split) ...[
        ActivitySpan(start: start, end: start.add(const Duration(minutes: 4))),
        ActivitySpan(start: start.add(const Duration(minutes: 10)), end: end),
      ] else
        ActivitySpan(start: start, end: end),
    ],
    finishedAt: finished ? end : null,
  );
}

void main() {
  test('exact elapsed unions finished intervals and ignores other targets', () {
    final current = _task('focused');
    final start = _now.subtract(const Duration(hours: 3));
    final logged = _log(current, start, 20, id: 'first');
    final index = TaskContextIndex.build(
      tasks: [current],
      activities: [
        _log(current, start, 20, id: 'first'),
        logged,
        _log(current, start.add(const Duration(minutes: 10)), 20, id: 'second'),
        _log(current, start, 50, id: 'unlinked', kind: null),
        _log(current, start, 60, id: 'event', kind: ActivityTargetKind.event),
        _log(current, start, 70, id: 'unfinished', finished: false),
        _log(current, _now, 80, id: 'future'),
      ],
      asOf: _now,
    );
    final result = index.evidenceFor(current);
    expect(result.exactElapsed?.elapsed, const Duration(minutes: 30));
    expect(result.exactElapsed?.activityCount, 2);
    expect(result.exactElapsed?.segments, 1);
    expect(result.exactElapsed?.firstStartedAt, start);
    expect(result.duration, isNull);
    expect(result.recurrence, isNull);
  });

  test('a planned block and unchecked completion provenance never train', () {
    final marked = _task(
      'marked',
      completed: _now.subtract(const Duration(days: 1)),
    );
    final legacy = TaskContextTarget.fromTask(
      const TaskItem(
        id: 'legacy',
        title: 'Client handoff',
        category: 'work',
        done: true,
      ),
    );
    final contradicted = _task('late', completed: marked.completedAt);
    final future = _task(
      'future',
      completed: _now.add(const Duration(days: 1)),
    );
    final index = TaskContextIndex.build(
      tasks: [marked, legacy, contradicted, future],
      activities: [
        ActivityRecord(
          id: 'planned',
          title: marked.title,
          category: marked.category,
          plan: ActivityWindow(
            marked.completedAt!.subtract(const Duration(hours: 1)),
            marked.completedAt!,
          ),
          target: ActivityTarget(
            id: marked.id,
            title: marked.title,
            category: marked.category,
            kind: ActivityTargetKind.task,
          ),
        ),
        _log(legacy, marked.completedAt!, 20),
        _log(contradicted, marked.completedAt!, 25),
        _log(future, marked.completedAt!, 10),
      ],
      asOf: _now,
    );
    expect(index.evidenceFor(marked).exactElapsed, isNull);
    expect(index.evidenceFor(legacy).exactElapsed?.elapsed.inMinutes, 20);
    expect(index.evidenceFor(contradicted).exactElapsed?.elapsed.inMinutes, 25);
    expect(index.evidenceFor(_task('new')).duration, isNull);
  });

  test('cohorts use canonical series, exact category and normalized title', () {
    final start = _now.subtract(const Duration(days: 6));
    final completed = start.add(const Duration(hours: 5));
    final series = _task(
      'renamed',
      title: 'Retired title',
      seriesId: 'series-a',
      completed: completed,
    );
    final sameTitle = _task(
      'same',
      title: '  CLIENT   Handoff  ',
      completed: completed,
    );
    final otherTitle = _task('other', title: 'Team sync', completed: completed);
    final otherCategory = _task(
      'other-category',
      category: 'home',
      seriesId: 'series-a',
      completed: completed,
    );
    final samples = [series, sameTitle, otherTitle, otherCategory];
    final index = TaskContextIndex.build(
      tasks: samples,
      activities: [
        for (final (ordinal, task) in samples.indexed)
          _log(task, start, (ordinal + 1) * 16),
      ],
      asOf: _now,
    );
    final bySeries = index
        .evidenceFor(_task('new', seriesId: 'series-a'))
        .duration!;
    expect(bySeries.cohort, TaskEvidenceCohort.series);
    expect(bySeries.compatibleMinutes, [16]);
    final byTitle = index.evidenceFor(_task('new')).duration!;
    expect(byTitle.cohort, TaskEvidenceCohort.titleAndCategory);
    expect(byTitle.compatibleMinutes, [32]);
    expect(byTitle.lower, byTitle.upper);
    expect(byTitle.strength, TaskEvidenceStrength.limited);
    final broad = index.evidenceFor(_task('new', title: 'Write a new report'));
    expect(broad.duration?.cohort, TaskEvidenceCohort.category);
    expect(broad.duration?.sampleCount, 3);
    expect(broad.duration?.strength, TaskEvidenceStrength.limited);
    expect(broad.recurrence, isNull);
    expect(
      index.evidenceFor(_task('new', category: 'unclassified')).duration,
      isNull,
    );
  });

  test('outliers stay visible and the recurrence profile uses workspace local days', () {
    timezone_data.initializeTimeZones();
    final location = timezone.getLocation('Europe/London');
    final durations = [19, 19, 20, 20, 20, 21, 21, 22, 280];
    final starts = [
      for (var sample = 0; sample < durations.length; sample++)
        timezone.TZDateTime(location, 2026, 9, 29 + 7 * sample, 9),
    ];
    expect(starts.map((date) => date.toUtc().hour).toSet(), {8, 9});
    final samples = [
      for (final (index, started) in starts.indexed)
        _task(
          'completed-$index',
          seriesId: 'weekly',
          completed: started.add(const Duration(hours: 6)),
        ),
    ];
    final index = TaskContextIndex.build(
      tasks: samples.reversed,
      activities: [
        for (final (ordinal, task) in samples.indexed)
          _log(
            task,
            starts[ordinal].toUtc(),
            durations[ordinal],
            split: ordinal == 2,
          ),
      ],
      asOf: _now,
      localClock: (value) => timezone.TZDateTime.from(value, location),
    );
    final result = index.evidenceFor(_task('new', seriesId: 'weekly'));
    final duration = result.duration!;
    expect(duration.median.inMinutes, 20);
    expect(duration.lower.inMinutes, 20);
    expect(duration.upper.inMinutes, 21);
    expect(duration.maximum.inMinutes, 280);
    expect(duration.outlierCount, 1);
    expect(duration.sampleCount, 9);
    expect(duration.last90DaysCount, 9);
    expect(duration.strength, TaskEvidenceStrength.consistent);
    expect(duration.oldestAge.inDays, 56);
    expect(duration.newestAge.inDays, 0);
    expect(duration.optionalMetadata().values, isNot(contains('completed-0')));
    expect(duration.optionalMetadata()['maximumSeconds'], 16800);
    final repeat = result.recurrence!;
    expect(repeat.commonWeekday, DateTime.tuesday);
    expect(repeat.commonStartHour, 9);
    expect(repeat.distinctStartDays, 9);
    expect(repeat.splitObservations, 1);
    expect(repeat.cadence?.observedGaps, 8);
    expect(repeat.cadence?.medianDays, 7);
  });

  test(
    'recent evidence is capped, preserves counts and excludes the target',
    () {
      final samples = [
        for (var caseNo = 0; caseNo < 45; caseNo++)
          _task(
            'case-$caseNo',
            completed: _now.subtract(Duration(days: caseNo + 1)),
          ),
      ];
      final logs = [
        for (final (caseNo, sample) in samples.indexed)
          _log(
            sample,
            sample.completedAt!.subtract(const Duration(hours: 3)),
            caseNo + 5,
          ),
      ];
      final index = TaskContextIndex.build(
        tasks: samples,
        activities: logs.reversed,
        asOf: _now,
      );
      final duration = index.evidenceFor(samples.first).duration!;
      expect(duration.sampleCount, TaskContextIndex.sampleLimit);
      expect(duration.matchingSamples, 44);
      expect(duration.unsampledCount, 12);
      expect(duration.compatibleMinutes.first, 6);
      expect(duration.compatibleMinutes.last, 37);
      expect(duration.latestCompletion, samples[1].completedAt);
      expect(duration.earliestCompletion, samples[32].completedAt);
      expect(duration.compatibleMinutes, isNot(contains(5)));
    },
  );

  test(
    'one fresh observation alongside old evidence keeps confidence limited',
    () {
      final samples = [
        _task('fresh', completed: _now.subtract(const Duration(days: 3))),
        for (var age = 150; age < 160; age++)
          _task('old-$age', completed: _now.subtract(Duration(days: age))),
      ];
      final index = TaskContextIndex.build(
        tasks: samples,
        activities: [
          for (final entry in samples)
            _log(
              entry,
              entry.completedAt!.subtract(const Duration(hours: 1)),
              20,
            ),
        ],
        asOf: _now,
      );
      final result = index.evidenceFor(_task('candidate')).duration!;
      expect(result.median.inMinutes, 20);
      expect(result.last90DaysCount, 1);
      expect(result.strength, TaskEvidenceStrength.limited);
      expect(result.newestAge.inDays, 3);
      expect(result.oldestAge.inDays, 159);
    },
  );

  test('ambiguous target identities contribute no observed evidence', () {
    final closed = _now.subtract(const Duration(hours: 6));
    final conflicting = _task('duplicate', completed: closed);
    final index = TaskContextIndex.build(
      tasks: [
        conflicting,
        _task('duplicate', category: 'another', completed: closed),
      ],
      activities: [
        _log(conflicting, closed.subtract(const Duration(hours: 1)), 20),
      ],
      asOf: _now,
    );
    expect(index.evidenceFor(conflicting).exactElapsed, isNull);
    expect(index.evidenceFor(_task('new')).duration, isNull);
  });

  test('conflicting replay records are excluded in either input order', () {
    final closed = _now.subtract(const Duration(hours: 6));
    final first = _task('first', completed: closed);
    final second = _task('second', completed: closed);
    final start = closed.subtract(const Duration(hours: 1));
    final records = [
      _log(first, start, 20, id: 'conflict'),
      _log(second, start, 20, id: 'conflict'),
    ];
    for (final sequence in [records, records.reversed]) {
      final index = TaskContextIndex.build(
        tasks: [first, second],
        activities: sequence,
        asOf: _now,
      );
      expect(index.evidenceFor(first).exactElapsed, isNull);
      expect(index.evidenceFor(second).exactElapsed, isNull);
      expect(index.evidenceFor(_task('new')).duration, isNull);
    }
  });
}
