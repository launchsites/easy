import '../task_model.dart';

class TaskContextTarget {
  const TaskContextTarget({
    required this.id,
    required this.title,
    required this.category,
    this.seriesId,
    this.completedAt,
  });

  factory TaskContextTarget.fromTask(TaskItem task, {String? seriesId}) =>
      TaskContextTarget(
        id: task.id,
        title: task.title,
        category: task.category,
        seriesId: seriesId,
        completedAt: task.done ? task.completedAt : null,
      );

  final String id;
  final String title;
  final String category;

  /// An explicit canonical series identity, when present.
  final String? seriesId;

  /// An observed completion instant. A legacy checked state has no instant.
  final DateTime? completedAt;
}

enum TaskEvidenceCohort {
  series('Same repeating task'),
  titleAndCategory('Same task title and category'),
  category('Same category');

  const TaskEvidenceCohort(this.label);
  final String label;
}

/// Heuristics for describing the evidence. These are not probabilities.
enum TaskEvidenceStrength { limited, indicative, consistent }

class TaskElapsedEvidence {
  const TaskElapsedEvidence({
    required this.elapsed,
    required this.activityCount,
    required this.segments,
    required this.firstStartedAt,
    required this.lastEndedAt,
  });

  final Duration elapsed;
  final int activityCount;
  final int segments;
  final DateTime firstStartedAt;
  final DateTime lastEndedAt;
}

class TaskDurationEvidence {
  TaskDurationEvidence({
    required this.cohort,
    required this.strength,
    required this.median,
    required this.lower,
    required this.upper,
    required this.minimum,
    required this.maximum,
    required this.sampleCount,
    required this.matchingSamples,
    required this.last90DaysCount,
    required this.outlierCount,
    required this.earliestCompletion,
    required this.latestCompletion,
    required this.asOf,
    required Iterable<int> compatibleMinutes,
  }) : compatibleMinutes = List.unmodifiable(compatibleMinutes);

  final TaskEvidenceCohort cohort;
  final TaskEvidenceStrength strength;
  final Duration median;

  /// Middle half for five or more observations, observed range otherwise.
  final Duration lower;
  final Duration upper;
  final Duration minimum;
  final Duration maximum;
  final int sampleCount;
  final int matchingSamples;
  final int last90DaysCount;

  /// Observations beyond 1.5 times the middle-half range stay in the sample.
  /// Null indicates too few observations for this comparison.
  final int? outlierCount;
  final DateTime earliestCompletion;
  final DateTime latestCompletion;
  final DateTime asOf;

  /// Newest first. Only samples within an estimator's allowed minute range.
  final List<int> compatibleMinutes;

  int get unsampledCount => matchingSamples - sampleCount;
  Duration get oldestAge => asOf.difference(earliestCompletion);
  Duration get newestAge => asOf.difference(latestCompletion);

  /// Optional aggregate context without titles, target IDs or timestamps.
  Map<String, Object?> optionalMetadata() => {
    'cohort': cohort.name,
    'strength': strength.name,
    'sampleCount': sampleCount,
    'matchingSamples': matchingSamples,
    'last90DaysCount': last90DaysCount,
    'newestAgeDays': newestAge.inDays,
    'oldestAgeDays': oldestAge.inDays,
    'medianSeconds': median.inSeconds,
    'lowerSeconds': lower.inSeconds,
    'upperSeconds': upper.inSeconds,
    'rangeKind': sampleCount < 5 ? 'observedRange' : 'middleHalf',
    'minimumSeconds': minimum.inSeconds,
    'maximumSeconds': maximum.inSeconds,
    'outlierCount': outlierCount,
  };
}

class TaskCadenceEvidence {
  const TaskCadenceEvidence({
    required this.observedGaps,
    required this.minimumDays,
    required this.medianDays,
    required this.maximumDays,
  });

  final int observedGaps;
  final int minimumDays;
  final double medianDays;
  final int maximumDays;
}

class TaskRecurrenceEvidence {
  TaskRecurrenceEvidence({
    required this.cohort,
    required this.observations,
    required this.distinctStartDays,
    required this.splitObservations,
    required Map<int, int> weekdayCounts,
    required Map<int, int> startHourCounts,
    required this.firstStartDay,
    required this.lastStartDay,
    this.commonWeekday,
    this.commonStartHour,
    this.cadence,
  }) : weekdayCounts = Map.unmodifiable(weekdayCounts),
       startHourCounts = Map.unmodifiable(startHourCounts);

  final TaskEvidenceCohort cohort;
  final int observations;
  final int distinctStartDays;
  final int splitObservations;

  /// Weekday counts are per civil day and hour counts are per observation.
  final Map<int, int> weekdayCounts;
  final Map<int, int> startHourCounts;

  /// Civil dates represented by UTC fields, using the supplied workspace clock.
  final DateTime firstStartDay;
  final DateTime lastStartDay;
  final int? commonWeekday;
  final int? commonStartHour;
  final TaskCadenceEvidence? cadence;
}

class TaskContextEvidence {
  const TaskContextEvidence({
    this.exactElapsed,
    this.duration,
    this.recurrence,
  });

  final TaskElapsedEvidence? exactElapsed;
  final TaskDurationEvidence? duration;
  final TaskRecurrenceEvidence? recurrence;
}
