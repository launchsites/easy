import 'insight_models.dart';

InsightReport buildInsightReport({
  required InsightRange range,
  required Iterable<InsightActivity> activities,
  required Iterable<InsightTask> tasks,
  Iterable<InsightPlan> plans = const [],
  String? category,
}) {
  final scopedActivities = [
    for (final activity in activities)
      if (category == null || activity.category == category) activity,
  ];
  final daily = <String, _DayEvidence>{};
  for (final activity in scopedActivities) {
    for (final span in activity.spans) {
      final window = clipInsightWindow(span, range.start, range.end);
      if (window == null) continue;
      var first = window.start;
      while (first.isBefore(window.end)) {
        final day = insightDay(first.toLocal());
        final nextDay = shiftInsightDay(day, 1);
        final last = window.end.isBefore(nextDay) ? window.end : nextDay;
        daily
            .putIfAbsent(insightDayKey(day), () => _DayEvidence(day))
            .add(activity.id, activity.category, InsightWindow(first, last));
        first = last;
      }
    }
  }
  final days = {
    for (final entry in daily.entries) entry.key: entry.value.summarize(),
  };
  final byCategory = <String, Duration>{};
  for (final day in days.values) {
    for (final entry in day.byCategory.entries) {
      byCategory.update(
        entry.key,
        (current) => current + entry.value,
        ifAbsent: () => entry.value,
      );
    }
  }

  final completed = distinctInsightRecords(tasks, (task) => task.id).where((
    task,
  ) {
    final finishedAt = task.completedAt;
    return finishedAt != null &&
        range.contains(finishedAt) &&
        (category == null || task.category == category);
  }).toList();
  var comparableDeadlines = 0;
  var onTime = 0;
  final errors = <Duration>[];
  final forecasts = {
    for (final task in completed)
      if ((task.forecastMinutes ?? 0) > 0) task.id,
  };
  final actualTasks = forecasts.isEmpty
      ? const <String, List<InsightWindow>>{}
      : _actualByTask(scopedActivities, forecasts);
  for (final task in completed) {
    if (task.dueAt case final deadline?) {
      comparableDeadlines++;
      if (!task.completedAt!.isAfter(deadline)) onTime++;
    }
    final forecast = task.forecastMinutes;
    final logged = actualTasks[task.id];
    if (forecast != null && forecast > 0 && logged != null) {
      errors.add((insightDuration(logged) - Duration(minutes: forecast)).abs());
    }
  }

  final initialDelays = <Duration>[];
  final acceptedDeltas = <Duration>[];
  var moved = 0;
  var comparableMoves = 0;
  var skipped = 0;
  var confirmedOutcomes = 0;
  var acceptedTime = Duration.zero;
  var insideTime = Duration.zero;
  var comparableSlots = 0;
  for (final plan in distinctInsightRecords(plans, (plan) => plan.id)) {
    if (category != null && plan.category != category) continue;
    final initial = plan.initial?.isValid ?? false ? plan.initial : null;
    final accepted = plan.accepted?.isValid ?? false ? plan.accepted : null;
    final actual = mergeInsightWindows(plan.actual);
    final baseline =
        initial?.start ?? accepted?.start ?? actual.firstOrNull?.start;
    if (baseline == null || !range.contains(baseline)) continue;
    if (initial != null && accepted != null) {
      comparableMoves++;
      if (!initial.start.isAtSameMomentAs(accepted.start) ||
          !initial.end.isAtSameMomentAs(accepted.end)) {
        moved++;
      }
    }
    if (plan.outcome case final outcome?) {
      confirmedOutcomes++;
      if (outcome == InsightPlanOutcome.skipped) skipped++;
    }
    if (actual.isEmpty) continue;
    if (initial != null) {
      initialDelays.add(actual.first.start.difference(initial.start));
    }
    if (accepted != null) {
      comparableSlots++;
      acceptedDeltas.add(insightDuration(actual) - accepted.duration);
      acceptedTime += accepted.duration;
      insideTime += insightDuration([
        for (final window in actual)
          ?clipInsightWindow(window, accepted.start, accepted.end),
      ]);
    }
  }
  return InsightReport(
    range: range,
    category: category,
    days: days,
    byCategory: byCategory,
    completedTasks: completed.length,
    finishedOnTime: InsightRatio(onTime, comparableDeadlines),
    rescheduled: InsightRatio(moved, comparableMoves),
    skipped: InsightRatio(skipped, confirmedOutcomes),
    initialStartDelay: _measure(initialDelays),
    acceptedDurationDelta: _measure(acceptedDeltas),
    durationForecastError: _measure(errors),
    adherence: InsightAdherence(
      within: insideTime,
      accepted: acceptedTime,
      sampleSize: comparableSlots,
    ),
  );
}

List<InsightWindow> mergeInsightWindows(Iterable<InsightWindow> windows) {
  final ordered = windows.where((span) => span.isValid).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final result = <InsightWindow>[];
  for (final span in ordered) {
    if (result.isEmpty || span.start.isAfter(result.last.end)) {
      result.add(span);
    } else if (span.end.isAfter(result.last.end)) {
      result[result.length - 1] = InsightWindow(result.last.start, span.end);
    }
  }
  return result;
}

InsightWindow? clipInsightWindow(
  InsightWindow window,
  DateTime start,
  DateTime end,
) {
  final first = window.start.isAfter(start) ? window.start : start;
  final last = window.end.isBefore(end) ? window.end : end;
  return last.isAfter(first) ? InsightWindow(first, last) : null;
}

Duration insightDuration(Iterable<InsightWindow> ordered) =>
    ordered.fold(Duration.zero, (sum, window) => sum + window.duration);

InsightMeasure _measure(List<Duration> values) {
  if (values.isEmpty) return const InsightMeasure(null, 0);
  final sorted = values.map((duration) => duration.inMicroseconds).toList()
    ..sort();
  final middle = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[middle]
      : sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) ~/ 2;
  return InsightMeasure(Duration(microseconds: median), values.length);
}

/// Excludes ambiguous repeated identifiers from task and plan denominators.
Iterable<T> distinctInsightRecords<T>(
  Iterable<T> records,
  String Function(T) idOf,
) {
  final known = <String, T>{};
  final repeated = <String>{};
  for (final record in records) {
    final id = idOf(record);
    if (known.containsKey(id)) {
      repeated.add(id);
    } else {
      known[id] = record;
    }
  }
  return known.entries
      .where((entry) => !repeated.contains(entry.key))
      .map((entry) => entry.value);
}

Map<String, List<InsightWindow>> _actualByTask(
  Iterable<InsightActivity> activities,
  Set<String> taskIds,
) {
  final spans = <String, List<InsightWindow>>{};
  for (final activity in activities) {
    final id = activity.taskId;
    if (id == null || !taskIds.contains(id)) continue;
    for (final span in activity.spans) {
      if (span.isValid) (spans[id] ??= []).add(span);
    }
  }
  return spans.map((id, windows) => MapEntry(id, mergeInsightWindows(windows)));
}

class _DayEvidence {
  _DayEvidence(this.day);

  final DateTime day;
  final _activities = <String>{};
  final _spans = <InsightWindow>[];
  final _categories = <String, List<InsightWindow>>{};

  void add(String activity, String category, InsightWindow span) {
    _activities.add(activity);
    _spans.add(span);
    (_categories[category] ??= []).add(span);
  }

  InsightDay summarize() => InsightDay(
    day: day,
    actual: insightDuration(mergeInsightWindows(_spans)),
    byCategory: {
      for (final entry in _categories.entries)
        entry.key: insightDuration(mergeInsightWindows(entry.value)),
    },
    activityCount: _activities.length,
  );
}
