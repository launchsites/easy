import '../task_context/task_context_models.dart';

/// A review-only proposal based on confirmed elapsed time for comparable work.
class DurationEvidenceEstimate {
  const DurationEvidenceEstimate._({
    required this.duration,
    required this.lower,
    required this.upper,
    required this.sampleCount,
    required this.cohort,
    required this.strength,
  });

  final Duration duration;
  final Duration lower;
  final Duration upper;
  final int sampleCount;
  final TaskEvidenceCohort cohort;
  final TaskEvidenceStrength strength;

  bool get requiresReview => true;
}

/// Uses the precise cohort median and its observed range when comparable work
/// has enough recent, reasonably consistent durations. A missing proposal
/// leaves the estimate open for manual entry or a separate provider review.
DurationEvidenceEstimate? estimateFromConfirmedHistory(
  TaskDurationEvidence? evidence,
) {
  if (evidence == null ||
      evidence.cohort == TaskEvidenceCohort.category ||
      evidence.strength == TaskEvidenceStrength.limited ||
      evidence.sampleCount < 3 ||
      evidence.sampleCount > evidence.matchingSamples ||
      evidence.last90DaysCount != evidence.sampleCount ||
      evidence.newestAge.isNegative ||
      evidence.oldestAge < evidence.newestAge ||
      evidence.oldestAge > const Duration(days: 90)) {
    return null;
  }

  final lower = evidence.lower;
  final upper = evidence.upper;
  final median = evidence.median;
  if (lower < const Duration(minutes: 1) ||
      lower > median ||
      upper < median ||
      upper > const Duration(hours: 24) ||
      upper - lower > median) {
    return null;
  }

  return DurationEvidenceEstimate._(
    duration: median,
    lower: lower,
    upper: upper,
    sampleCount: evidence.sampleCount,
    cohort: evidence.cohort,
    strength: evidence.strength,
  );
}
