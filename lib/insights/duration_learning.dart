import 'insight_models.dart';
import 'insight_report.dart';

class DurationObservation {
  const DurationObservation({
    required this.task,
    required this.actual,
    required this.finishedAt,
  });

  final InsightTask task;
  final Duration actual;
  final DateTime finishedAt;
}

enum DurationCohort {
  sameTitle('Same task title'),
  sameProjectAndType('Same project and task type'),
  sameCategoryAndType('Same category and task type'),
  sameProject('Same project'),
  sameCategory('Same category');

  const DurationCohort(this.label);
  final String label;
}

class LearnedDuration {
  const LearnedDuration({
    required this.duration,
    required this.lower,
    required this.upper,
    required this.samples,
    required this.cohort,
  });

  final Duration duration;
  final Duration lower;
  final Duration upper;
  final int samples;
  final DurationCohort cohort;

  bool get hasLimitedEvidence => samples < 5;

  Map<String, Object> toJson() => {
    'medianSeconds': duration.inSeconds,
    'lowerSeconds': lower.inSeconds,
    'upperSeconds': upper.inSeconds,
    'sampleSize': samples,
    'cohort': cohort.name,
    'rangeKind': hasLimitedEvidence ? 'observedRange' : 'middleHalf',
  };
}

/// A task contributes one elapsed sample regardless of how many times its
/// activity restarted. Tasks without an observed completion stay out.
List<DurationObservation> buildDurationObservations({
  required Iterable<InsightTask> tasks,
  required Iterable<InsightActivity> activities,
}) {
  final taskWindows = <String, List<InsightWindow>>{};
  for (final activity in activities) {
    final id = activity.taskId;
    if (id == null) continue;
    for (final span in activity.spans) {
      if (span.isValid) (taskWindows[id] ??= []).add(span);
    }
  }
  return List.unmodifiable([
    for (final task in distinctInsightRecords(tasks, (task) => task.id))
      if (task.completedAt case final completion?)
        if (taskWindows[task.id] case final windows?)
          DurationObservation(
            task: task,
            actual: insightDuration(mergeInsightWindows(windows)),
            finishedAt: completion,
          ),
  ]);
}

/// Chooses the narrowest cohort with several samples when possible. The range
/// describes observations and is not a prediction interval.
LearnedDuration? learnDuration(
  InsightTask query,
  Iterable<DurationObservation> observations,
) {
  final title = _normalized(query.title);
  final history =
      distinctInsightRecords(observations, (sample) => sample.task.id)
          .where(
            (sample) =>
                sample.task.id != query.id && sample.actual > Duration.zero,
          )
          .toList();
  (DurationCohort, List<DurationObservation>)? weak;
  for (final cohort in DurationCohort.values) {
    final matched = [
      for (final sample in history)
        if (switch (cohort) {
          DurationCohort.sameTitle =>
            query.category == sample.task.category &&
                title.isNotEmpty &&
                _normalized(sample.task.title) == title,
          DurationCohort.sameProjectAndType =>
            _matches(query.projectId, sample.task.projectId) &&
                _matches(query.taskType, sample.task.taskType),
          DurationCohort.sameCategoryAndType =>
            query.category == sample.task.category &&
                _matches(query.taskType, sample.task.taskType),
          DurationCohort.sameProject => _matches(
            query.projectId,
            sample.task.projectId,
          ),
          DurationCohort.sameCategory =>
            query.category.isNotEmpty && query.category == sample.task.category,
        })
          sample,
    ];
    if (matched.length >= 3) return _learn(cohort, matched);
    if (matched.isNotEmpty) weak ??= (cohort, matched);
  }
  return weak == null ? null : _learn(weak.$1, weak.$2);
}

bool _matches(String? first, String? second) =>
    first != null && first.isNotEmpty && first == second;

String _normalized(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

LearnedDuration _learn(
  DurationCohort cohort,
  List<DurationObservation> samples,
) {
  final micros = samples.map((item) => item.actual.inMicroseconds).toList()
    ..sort();
  final last = micros.length - 1;
  final mid = micros.length ~/ 2;
  final median = micros.length.isOdd
      ? micros[mid]
      : micros[mid - 1] + (micros[mid] - micros[mid - 1]) ~/ 2;
  return LearnedDuration(
    duration: Duration(microseconds: median),
    lower: Duration(microseconds: micros[samples.length < 5 ? 0 : last ~/ 4]),
    upper: Duration(
      microseconds: micros[samples.length < 5 ? last : (last * 3 + 3) ~/ 4],
    ),
    samples: samples.length,
    cohort: cohort,
  );
}
