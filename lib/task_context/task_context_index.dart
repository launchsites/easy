import '../activities/activity_model.dart';
import '../insights/insight_models.dart' show InsightWindow;
import '../insights/insight_report.dart'
    show insightDuration, mergeInsightWindows;
import 'task_context_models.dart';

class TaskContextIndex {
  TaskContextIndex._(this._asOf);

  /// Indexes only supplied workspace-visible tasks and finished, linked timers.
  factory TaskContextIndex.build({
    required Iterable<TaskContextTarget> tasks,
    required Iterable<ActivityRecord> activities,
    required DateTime asOf,
    DateTime Function(DateTime instant)? localClock,
  }) {
    final index = TaskContextIndex._(asOf);
    final targets = <String, TaskContextTarget?>{};
    for (final task in tasks) {
      if (task.id.trim().isEmpty) continue;
      if (!targets.containsKey(task.id)) {
        targets[task.id] = task;
      } else if (targets[task.id] case final existing?
          when !_sameTarget(existing, task)) {
        targets[task.id] = null;
      }
    }
    final logs = <String, ActivityRecord?>{};
    for (final record in activities) {
      final target = record.target;
      final finished = record.finishedAt;
      if (target == null ||
          target.kind != ActivityTargetKind.task ||
          targets[target.id] == null ||
          finished == null ||
          finished.isAfter(asOf)) {
        continue;
      }
      if (!logs.containsKey(record.id)) {
        logs[record.id] = record;
      } else if (logs[record.id] case final existing?
          when !_sameLog(existing, record)) {
        logs[record.id] = null;
      }
    }
    final byTarget = <String, _LinkedLog>{};
    for (final record in logs.values.nonNulls) {
      byTarget.putIfAbsent(record.target!.id, _LinkedLog.new).add(record.spans);
    }

    for (final entry in byTarget.entries) {
      final log = entry.value;
      final merged = mergeInsightWindows(log.spans);
      if (merged.isEmpty) continue;
      final exact = TaskElapsedEvidence(
        elapsed: insightDuration(merged),
        activityCount: log.recordCount,
        segments: merged.length,
        firstStartedAt: merged.first.start,
        lastEndedAt: merged.last.end,
      );
      if (exact.elapsed <= Duration.zero) continue;
      index._elapsed[entry.key] = exact;
      final task = targets[entry.key]!;
      final completed = task.completedAt;
      if (completed == null ||
          completed.isAfter(asOf) ||
          exact.lastEndedAt.isAfter(completed) ||
          task.category.isEmpty) {
        continue;
      }
      final local =
          localClock?.call(exact.firstStartedAt) ??
          exact.firstStartedAt.toLocal();
      final outcome = _Outcome(
        id: task.id,
        completed: completed,
        duration: exact.elapsed,
        startDay: DateTime.utc(local.year, local.month, local.day),
        startHour: local.hour,
        split: exact.segments > 1,
      );
      final title = _titleKey(task.title);
      final seriesId = task.seriesId;
      index._profiles[task.id] = (
        category: task.category,
        title: title,
        series: seriesId,
      );
      index._categories.putIfAbsent(task.category, _Samples.new).add(outcome);
      if (title.isNotEmpty) {
        index._titles
            .putIfAbsent((task.category, title), _Samples.new)
            .add(outcome);
      }
      if (seriesId != null && seriesId.isNotEmpty) {
        index._series
            .putIfAbsent((task.category, seriesId), _Samples.new)
            .add(outcome);
      }
    }
    return index;
  }

  static const sampleLimit = 32;

  final DateTime _asOf;
  final _elapsed = <String, TaskElapsedEvidence>{};
  final _profiles =
      <String, ({String category, String title, String? series})>{};
  final _categories = <String, _Samples>{};
  final _titles = <(String, String), _Samples>{};
  final _series = <(String, String), _Samples>{};

  TaskContextEvidence evidenceFor(TaskContextTarget target) {
    final exact = _elapsed[target.id];
    final cohort = _chooseCohort(target);
    if (cohort == null) return TaskContextEvidence(exactElapsed: exact);
    final (kind, bucket, matching) = cohort;
    final recent = bucket.recent
        .where((sample) => sample.id != target.id)
        .take(sampleLimit)
        .toList();
    return TaskContextEvidence(
      exactElapsed: exact,
      duration: _duration(kind, recent, matching, _asOf),
      recurrence: kind == TaskEvidenceCohort.category || recent.length < 3
          ? null
          : _recurrence(kind, recent),
    );
  }

  (TaskEvidenceCohort, _Samples, int)? _chooseCohort(TaskContextTarget task) {
    final key = task.category;
    final title = _titleKey(task.title);
    final series = task.seriesId;
    final own = _profiles[task.id];
    final inCategory = own?.category == key;
    for (final (kind, bucket, hasOwnSample) in [
      (
        TaskEvidenceCohort.series,
        _series[(key, series ?? '')],
        inCategory && own?.series == series,
      ),
      (
        TaskEvidenceCohort.titleAndCategory,
        _titles[(key, title)],
        inCategory && own?.title == title,
      ),
      (TaskEvidenceCohort.category, _categories[key], inCategory),
    ]) {
      if (bucket == null) continue;
      final matching = bucket.count - (hasOwnSample ? 1 : 0);
      if (matching > 0) return (kind, bucket, matching);
    }
    return null;
  }
}

class _LinkedLog {
  final spans = <InsightWindow>[];
  var recordCount = 0;

  void add(List<ActivitySpan> actual) {
    final before = spans.length;
    for (final span in actual) {
      final end = span.end;
      if (end != null && end.isAfter(span.start)) {
        spans.add(InsightWindow(span.start, end));
      }
    }
    if (spans.length > before) recordCount++;
  }
}

class _Outcome {
  const _Outcome({
    required this.id,
    required this.completed,
    required this.duration,
    required this.startDay,
    required this.startHour,
    required this.split,
  });

  final String id;
  final DateTime completed;
  final Duration duration;
  final DateTime startDay;
  final int startHour;
  final bool split;

  int newestFirst(_Outcome other) {
    final order = other.completed.compareTo(completed);
    return order == 0 ? id.compareTo(other.id) : order;
  }
}

class _Samples {
  /// Keep one extra so the target itself can be omitted from its own evidence.
  static const _retained = TaskContextIndex.sampleLimit + 1;
  final recent = <_Outcome>[];
  var count = 0;

  void add(_Outcome sample) {
    count++;
    if (recent.length == _retained && sample.newestFirst(recent.last) >= 0) {
      return;
    }
    var first = 0;
    var last = recent.length;
    while (first < last) {
      final middle = (first + last) ~/ 2;
      if (sample.newestFirst(recent[middle]) < 0) {
        last = middle;
      } else {
        first = middle + 1;
      }
    }
    recent.insert(first, sample);
    if (recent.length > _retained) recent.removeLast();
  }
}

bool _sameTarget(TaskContextTarget a, TaskContextTarget b) =>
    a.category == b.category &&
    a.title == b.title &&
    a.seriesId == b.seriesId &&
    _sameInstant(a.completedAt, b.completedAt);

bool _sameLog(ActivityRecord a, ActivityRecord b) {
  if (identical(a, b)) return true;
  if (a.target!.id != b.target!.id ||
      !_sameInstant(a.finishedAt, b.finishedAt) ||
      a.spans.length != b.spans.length) {
    return false;
  }
  for (final (index, first) in a.spans.indexed) {
    final second = b.spans[index];
    if (!_sameInstant(first.start, second.start) ||
        !_sameInstant(first.end, second.end)) {
      return false;
    }
  }
  return true;
}

bool _sameInstant(DateTime? a, DateTime? b) =>
    a == b || a != null && b != null && a.isAtSameMomentAs(b);

final _whitespace = RegExp(r'\s+');

String _titleKey(String title) =>
    title.trim().toLowerCase().replaceAll(_whitespace, ' ');

TaskDurationEvidence _duration(
  TaskEvidenceCohort cohort,
  List<_Outcome> recent,
  int matching,
  DateTime asOf,
) {
  final micros = [for (final item in recent) item.duration.inMicroseconds]
    ..sort();
  final small = micros.length < 5;
  final median = _quartile(micros, 2);
  final lower = small ? micros.first : _quartile(micros, 1);
  final upper = small ? micros.last : _quartile(micros, 3);
  final spread = upper - lower;
  final outlierWidth = spread * 1.5;
  final outliers = small
      ? null
      : micros
            .where(
              (value) =>
                  value < lower - outlierWidth || value > upper + outlierWidth,
            )
            .length;
  final age = asOf.difference(recent.first.completed);
  final last90DaysCount = recent
      .where(
        (sample) =>
            asOf.difference(sample.completed) <= const Duration(days: 90),
      )
      .length;
  final limited = last90DaysCount < 3 || cohort == TaskEvidenceCohort.category;
  final consistent =
      last90DaysCount >= 8 &&
      age <= const Duration(days: 45) &&
      spread <= median / 2 &&
      outliers! * 4 <= recent.length;
  final strength = limited
      ? TaskEvidenceStrength.limited
      : consistent
      ? TaskEvidenceStrength.consistent
      : TaskEvidenceStrength.indicative;
  return TaskDurationEvidence(
    cohort: cohort,
    strength: strength,
    median: Duration(microseconds: median),
    lower: Duration(microseconds: lower),
    upper: Duration(microseconds: upper),
    minimum: Duration(microseconds: micros.first),
    maximum: Duration(microseconds: micros.last),
    sampleCount: recent.length,
    matchingSamples: matching,
    last90DaysCount: last90DaysCount,
    outlierCount: outliers,
    earliestCompletion: recent.last.completed,
    latestCompletion: recent.first.completed,
    asOf: asOf,
    compatibleMinutes: [
      for (final sample in recent)
        if (sample.duration.inMinutes case final minutes
            when minutes >= 1 && minutes <= 1440)
          minutes,
    ],
  );
}

int _quartile(List<int> ordered, int quartile) {
  final fraction = (ordered.length - 1) * quartile;
  final lower = fraction ~/ 4;
  final remainder = fraction % 4;
  if (remainder == 0) return ordered[lower];
  return ordered[lower] +
      ((ordered[lower + 1] - ordered[lower]) * (remainder / 4)).round();
}

TaskRecurrenceEvidence _recurrence(
  TaskEvidenceCohort cohort,
  List<_Outcome> recent,
) {
  final days = recent.map((item) => item.startDay).toSet().toList()..sort();
  final weekdayCounts = <int, int>{};
  for (final day in days) {
    weekdayCounts.update(day.weekday, (count) => count + 1, ifAbsent: () => 1);
  }
  final hours = <int, int>{};
  for (final sample in recent) {
    hours.update(sample.startHour, (count) => count + 1, ifAbsent: () => 1);
  }
  return TaskRecurrenceEvidence(
    cohort: cohort,
    observations: recent.length,
    distinctStartDays: days.length,
    splitObservations: recent.where((item) => item.split).length,
    weekdayCounts: weekdayCounts,
    startHourCounts: hours,
    firstStartDay: days.first,
    lastStartDay: days.last,
    commonWeekday: _dominant(weekdayCounts, days.length),
    commonStartHour: days.length < 5 ? null : _dominant(hours, recent.length),
    cadence: days.length < 4 ? null : _cadence(days),
  );
}

int? _dominant(Map<int, int> counts, int total) {
  if (total < 5) return null;
  for (final entry in counts.entries) {
    if (entry.value * 10 >= total * 7) return entry.key;
  }
  return null;
}

TaskCadenceEvidence _cadence(List<DateTime> days) {
  final gaps = [
    for (var index = 1; index < days.length; index++)
      days[index].difference(days[index - 1]).inDays,
  ]..sort();
  final mid = gaps.length ~/ 2;
  return TaskCadenceEvidence(
    observedGaps: gaps.length,
    minimumDays: gaps.first,
    medianDays: gaps.length.isOdd
        ? gaps[mid].toDouble()
        : (gaps[mid - 1] + gaps[mid]) / 2,
    maximumDays: gaps.last,
  );
}
