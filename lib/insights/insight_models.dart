class InsightWindow {
  const InsightWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;

  bool get isValid => end.isAfter(start);
  Duration get duration => end.difference(start);
}

class InsightActivity {
  const InsightActivity({
    required this.id,
    required this.category,
    required this.spans,
    this.taskId,
  });

  final String id;
  final String category;

  /// The caller includes confirmed elapsed spans only.
  final List<InsightWindow> spans;
  final String? taskId;
}

class InsightTask {
  const InsightTask({
    required this.id,
    required this.title,
    required this.category,
    this.projectId,
    this.taskType,
    this.dueAt,
    this.completedAt,
    this.forecastMinutes,
  });

  final String id;
  final String title;
  final String category;
  final String? projectId;
  final String? taskType;

  /// A confirmed deadline. A date-only suggestion is not a deadline.
  final DateTime? dueAt;

  /// The recorded completion instant. Legacy completed state is not evidence.
  final DateTime? completedAt;
  final int? forecastMinutes;
}

enum InsightPlanOutcome { completed, partial, skipped }

class InsightPlan {
  const InsightPlan({
    required this.id,
    required this.category,
    this.initial,
    this.accepted,
    this.actual = const [],
    this.outcome,
  });

  final String id;
  final String category;
  final InsightWindow? initial;
  final InsightWindow? accepted;
  final List<InsightWindow> actual;
  final InsightPlanOutcome? outcome;
}

DateTime insightDay(DateTime day) => DateTime(day.year, day.month, day.day);

DateTime shiftInsightDay(DateTime day, int offset) =>
    DateTime(day.year, day.month, day.day + offset);

String insightDayKey(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

class InsightRange {
  InsightRange(DateTime start, DateTime end)
    : start = insightDay(start),
      end = insightDay(end) {
    if (!this.end.isAfter(this.start)) {
      throw ArgumentError('Choose an end date after the start date.');
    }
  }

  final DateTime start;

  /// The first local calendar day outside the range.
  final DateTime end;

  bool contains(DateTime instant) =>
      !instant.isBefore(start) && instant.isBefore(end);

  int get days => DateTime.utc(
    end.year,
    end.month,
    end.day,
  ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
}

class InsightDay {
  InsightDay({
    required this.day,
    required this.actual,
    required Map<String, Duration> byCategory,
    required this.activityCount,
  }) : byCategory = Map.unmodifiable(byCategory);

  final DateTime day;

  /// Total actual elapsed time, counting overlapping activity once.
  final Duration actual;

  /// Each category is unioned independently. Category totals can overlap.
  final Map<String, Duration> byCategory;
  final int activityCount;

  Map<String, Object?> toJson() => {
    'day': insightDayKey(day),
    'confirmedActualSeconds': actual.inSeconds,
    'confirmedActivityCount': activityCount,
    'confirmedCategorySeconds': {
      for (final key in byCategory.keys.toList()..sort())
        key: byCategory[key]!.inSeconds,
    },
  };
}

class InsightRatio {
  const InsightRatio(this.count, this.comparable);

  final int count;
  final int comparable;

  double? get value => comparable > 0 ? count / comparable : null;

  Map<String, int> toJson() => {'count': count, 'comparable': comparable};
}

class InsightMeasure {
  const InsightMeasure(this.median, this.sampleSize);

  final Duration? median;
  final int sampleSize;

  Map<String, Object?> toJson() => {
    'medianSeconds': median?.inSeconds,
    'sampleSize': sampleSize,
  };
}

class InsightAdherence {
  const InsightAdherence({
    required this.within,
    required this.accepted,
    required this.sampleSize,
  });

  final Duration within;
  final Duration accepted;
  final int sampleSize;

  double? get value => accepted > Duration.zero
      ? within.inMicroseconds / accepted.inMicroseconds
      : null;

  Map<String, int> toJson() => {
    'withinSeconds': within.inSeconds,
    'acceptedSeconds': accepted.inSeconds,
    'sampleSize': sampleSize,
  };
}

class InsightReport {
  InsightReport({
    required this.range,
    required this.category,
    required Map<String, InsightDay> days,
    required Map<String, Duration> byCategory,
    required this.completedTasks,
    required this.finishedOnTime,
    required this.rescheduled,
    required this.skipped,
    required this.initialStartDelay,
    required this.acceptedDurationDelta,
    required this.durationForecastError,
    required this.adherence,
  }) : days = Map.unmodifiable(days),
       byCategory = Map.unmodifiable(byCategory);

  final InsightRange range;
  final String? category;
  final Map<String, InsightDay> days;
  final Map<String, Duration> byCategory;
  final int completedTasks;
  final InsightRatio finishedOnTime;
  final InsightRatio rescheduled;
  final InsightRatio skipped;
  final InsightMeasure initialStartDelay;
  final InsightMeasure acceptedDurationDelta;
  final InsightMeasure durationForecastError;
  final InsightAdherence adherence;

  Duration? get actual {
    if (days.isEmpty) return null;
    return days.values.fold<Duration>(
      Duration.zero,
      (total, day) => total + day.actual,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'startDay': insightDayKey(range.start),
    'endDayExclusive': insightDayKey(range.end),
    'category': category,
    'confirmedActualSeconds': actual?.inSeconds,
    'recordedDays': days.length,
    'confirmedCompletedTasks': completedTasks,
    'finishedOnTime': finishedOnTime.toJson(),
    'rescheduledPlans': rescheduled.toJson(),
    'skippedPlans': skipped.toJson(),
    'actualStartMinusInitialStart': initialStartDelay.toJson(),
    'actualDurationMinusAcceptedDuration': acceptedDurationDelta.toJson(),
    'absoluteDurationForecastError': durationForecastError.toJson(),
    'acceptedSlotAdherence': adherence.toJson(),
    'days': [for (final key in days.keys.toList()..sort()) days[key]!.toJson()],
  };
}
