import 'dart:math' as math;

import '../task_context/task_context_models.dart';
import 'ai_budget.dart';
import 'ai_runtime_settings.dart';
import 'duration_estimate_details.dart';
import 'inference_jobs.dart';

class AiEnrichmentCandidate {
  AiEnrichmentCandidate({
    required this.taskId,
    required this.title,
    required this.sourceRevision,
    required this.contextRevision,
    List<int> sampleDurationsMinutes = const [],
    this.durationHistory,
  }) : sampleDurationsMinutes = List.unmodifiable(sampleDurationsMinutes);

  final String taskId;
  final String title;
  final int sourceRevision;
  final int contextRevision;
  final List<int> sampleDurationsMinutes;
  final TaskDurationEvidence? durationHistory;

  AiCaptureRevision get revision =>
      (sourceRevision: sourceRevision, contextRevision: contextRevision);

  bool get valid =>
      taskId.trim().isNotEmpty &&
      title.trim().isNotEmpty &&
      sourceRevision >= 0 &&
      contextRevision >= 0;
}

class AiPendingEstimate {
  const AiPendingEstimate({
    required this.taskId,
    required this.sourceRevision,
    required this.contextRevision,
    required this.durationMinutes,
    required this.route,
    required this.createdAt,
    this.details,
  });

  final String taskId;
  final int sourceRevision;
  final int contextRevision;
  final int durationMinutes;
  final AiRoute route;
  final DateTime createdAt;
  final AiEstimateDetails? details;
  Duration get duration => Duration(minutes: durationMinutes);
  bool get requiresReview => true;

  bool isCurrent(AiRevisionLookup lookup) =>
      lookup(taskId) ==
      (sourceRevision: sourceRevision, contextRevision: contextRevision);

  Map<String, Object> toJson() => {
    'taskId': taskId,
    'sourceRevision': sourceRevision,
    'contextRevision': contextRevision,
    'durationMinutes': durationMinutes,
    'route': route.name,
    'createdAt': createdAt.toIso8601String(),
    if (details case final value?) 'details': value.toJson(),
  };

  factory AiPendingEstimate.fromJson(Map<String, dynamic> data) {
    final minutes = data['durationMinutes'] as int;
    final estimate = AiPendingEstimate(
      taskId: data['taskId'] as String,
      sourceRevision: data['sourceRevision'] as int,
      contextRevision: data['contextRevision'] as int,
      durationMinutes: minutes,
      route: AiRoute.values.byName(data['route'] as String),
      createdAt: DateTime.parse(data['createdAt'] as String),
      details: AiEstimateDetails.tryParse(data['details'], minutes),
    );
    if (estimate.taskId.trim().isEmpty ||
        estimate.sourceRevision < 0 ||
        estimate.contextRevision < 0 ||
        estimate.durationMinutes < 1 ||
        estimate.durationMinutes > 1440 ||
        estimate.route == AiRoute.offline) {
      throw const FormatException('Invalid duration suggestion.');
    }
    return estimate;
  }
}

/// Durable scheduling stamps and proposals store numeric review details only.
class AiEnrichmentState {
  AiEnrichmentState({
    this.lastMinute,
    this.attemptsOnLastDay = 0,
    Map<String, AiCaptureRevision> attempted = const {},
    List<AiPendingEstimate> pending = const [],
  }) : attempted = Map.unmodifiable(attempted),
       pending = List.unmodifiable(pending);

  final int? lastMinute;
  final int attemptsOnLastDay;
  final Map<String, AiCaptureRevision> attempted;
  final List<AiPendingEstimate> pending;

  static int minuteOf(DateTime time) =>
      time.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;

  bool permits(
    AiEnrichmentCandidate candidate,
    DateTime at,
    AiAutomaticPace pace,
  ) =>
      permitsTime(at, pace) &&
      attempted[candidate.taskId] != candidate.revision;

  bool permitsTime(DateTime at, AiAutomaticPace pace) {
    final latest = lastMinute;
    if (latest == null) return true;
    final current = minuteOf(at);
    if (!pace.adaptive) return current ~/ 60 > latest ~/ 60;
    return current - latest >= pace.minimumMinutes &&
        (_dayOf(current) != _dayOf(latest) ||
            attemptsOnLastDay < pace.dailyAttempts);
  }

  AiEnrichmentState withAttempt(AiEnrichmentCandidate candidate, DateTime at) =>
      AiEnrichmentState(
        lastMinute: minuteOf(at),
        attemptsOnLastDay:
            lastMinute != null && _dayOf(lastMinute!) == _dayOf(minuteOf(at))
            ? attemptsOnLastDay + 1
            : 1,
        attempted: {
          for (final entry in attempted.entries)
            if (entry.key != candidate.taskId) entry.key: entry.value,
          candidate.taskId: candidate.revision,
        },
        pending: pending,
      );

  AiEnrichmentState withEstimate(AiPendingEstimate estimate) =>
      AiEnrichmentState(
        lastMinute: lastMinute,
        attemptsOnLastDay: attemptsOnLastDay,
        attempted: attempted,
        pending: [
          estimate,
          for (final other in pending)
            if (other.taskId != estimate.taskId) other,
        ],
      );

  AiEnrichmentState withoutEstimate(AiPendingEstimate estimate) =>
      AiEnrichmentState(
        lastMinute: lastMinute,
        attemptsOnLastDay: attemptsOnLastDay,
        attempted: attempted,
        pending: [
          for (final other in pending)
            if (other.taskId != estimate.taskId ||
                other.contextRevision != estimate.contextRevision ||
                other.sourceRevision != estimate.sourceRevision ||
                other.createdAt != estimate.createdAt)
              other,
        ],
      );

  AiEnrichmentState withoutObsoleteEstimates(AiRevisionLookup current) {
    final kept = pending
        .where((estimate) => estimate.isCurrent(current))
        .toList();
    if (kept.length == pending.length) return this;
    return AiEnrichmentState(
      lastMinute: lastMinute,
      attemptsOnLastDay: attemptsOnLastDay,
      attempted: attempted,
      pending: kept,
    );
  }

  Map<String, Object?> toJson() => {
    'lastHour': lastMinute == null ? null : lastMinute! ~/ 60,
    if (lastMinute != null) 'lastMinute': lastMinute,
    if (attemptsOnLastDay != 0) 'attemptsOnLastDay': attemptsOnLastDay,
    'attempted': {
      for (final entry in attempted.entries)
        entry.key: [entry.value.sourceRevision, entry.value.contextRevision],
    },
    'pending': pending.map((entry) => entry.toJson()).toList(),
  };

  factory AiEnrichmentState.fromJson(Map<String, dynamic> data) {
    final attempted = <String, AiCaptureRevision>{};
    for (final entry in (data['attempted'] as Map<String, dynamic>).entries) {
      final parts = entry.value as List;
      if (entry.key.trim().isEmpty ||
          parts.length != 2 ||
          parts[0] is! int ||
          parts[1] is! int ||
          (parts[0] as int) < 0 ||
          (parts[1] as int) < 0) {
        throw const FormatException('Invalid enrichment history.');
      }
      attempted[entry.key] = (
        sourceRevision: parts[0] as int,
        contextRevision: parts[1] as int,
      );
    }
    final pending = (data['pending'] as List)
        .map(
          (entry) => AiPendingEstimate.fromJson(entry as Map<String, dynamic>),
        )
        .toList();
    final legacyHour = data['lastHour'] as int?;
    final minute =
        data['lastMinute'] as int? ??
        (legacyHour == null ? null : legacyHour * 60 + 59);
    final today = data['attemptsOnLastDay'] as int? ?? (minute == null ? 0 : 1);
    if ((minute == null &&
            (today != 0 || attempted.isNotEmpty || pending.isNotEmpty)) ||
        (minute != null && (today < 1 || today > 128)) ||
        (legacyHour != null && minute! ~/ 60 != legacyHour) ||
        pending.map((item) => item.taskId).toSet().length != pending.length) {
      throw const FormatException('Invalid enrichment history.');
    }
    return AiEnrichmentState(
      lastMinute: minute,
      attemptsOnLastDay: today,
      attempted: attempted,
      pending: pending,
    );
  }
}

int _dayOf(int minute) => minute ~/ Duration.minutesPerDay;

class AiAutomaticPace {
  const AiAutomaticPace._(
    this.minimumMinutes,
    this.dailyAttempts, {
    this.adaptive = true,
  });

  const AiAutomaticPace.hourly() : this._(60, 24, adaptive: false);

  final int minimumMinutes;
  final int dailyAttempts;
  final bool adaptive;

  static AiAutomaticPace forLocal({required bool adaptive}) => adaptive
      ? const AiAutomaticPace._(20, 6)
      : const AiAutomaticPace.hourly();

  static AiAutomaticPace? forApi({
    required AiBudgetReport budget,
    required int? requestMicros,
    required bool adaptive,
  }) {
    if (requestMicros == null ||
        requestMicros < 0 ||
        requestMicros > budget.discretionaryMicros ||
        (requestMicros > 0 &&
            budget.projectedMicros >= budget.monthlyCapMicros)) {
      return null;
    }
    if (!adaptive) return const AiAutomaticPace.hourly();
    final remainingDays = math.max(1, budget.month.days - budget.asOf.day + 1);
    final perDay = requestMicros == 0
        ? 12
        : math.min(
            12,
            budget.discretionaryMicros ~/ remainingDays ~/ requestMicros,
          );
    if (perDay == 0) return null;
    final minutes = switch (perDay) {
      >= 12 => 15,
      >= 6 => 30,
      >= 3 => 60,
      _ => 120,
    };
    return AiAutomaticPace._(minutes, perDay);
  }
}
