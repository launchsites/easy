import 'ai_runtime_settings.dart';
import 'inference_jobs.dart';

class AiEnrichmentCandidate {
  AiEnrichmentCandidate({
    required this.taskId,
    required this.title,
    required this.sourceRevision,
    required this.contextRevision,
    List<int> sampleDurationsMinutes = const [],
  }) : sampleDurationsMinutes = List.unmodifiable(sampleDurationsMinutes);

  final String taskId;
  final String title;
  final int sourceRevision;
  final int contextRevision;
  final List<int> sampleDurationsMinutes;

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
  });

  final String taskId;
  final int sourceRevision;
  final int contextRevision;
  final int durationMinutes;
  final AiRoute route;
  final DateTime createdAt;
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
  };

  factory AiPendingEstimate.fromJson(Map<String, dynamic> data) {
    final estimate = AiPendingEstimate(
      taskId: data['taskId'] as String,
      sourceRevision: data['sourceRevision'] as int,
      contextRevision: data['contextRevision'] as int,
      durationMinutes: data['durationMinutes'] as int,
      route: AiRoute.values.byName(data['route'] as String),
      createdAt: DateTime.parse(data['createdAt'] as String),
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

/// Durable scheduling stamps and proposals. They contain no title or samples.
class AiEnrichmentState {
  AiEnrichmentState({
    this.lastHour,
    Map<String, AiCaptureRevision> attempted = const {},
    List<AiPendingEstimate> pending = const [],
  }) : attempted = Map.unmodifiable(attempted),
       pending = List.unmodifiable(pending);

  final int? lastHour;
  final Map<String, AiCaptureRevision> attempted;
  final List<AiPendingEstimate> pending;

  static int hourOf(DateTime time) =>
      time.millisecondsSinceEpoch ~/ Duration.millisecondsPerHour;

  bool permits(AiEnrichmentCandidate candidate, int hour) =>
      (lastHour == null || hour > lastHour!) &&
      attempted[candidate.taskId] != candidate.revision;

  AiEnrichmentState withAttempt(AiEnrichmentCandidate candidate, int hour) =>
      AiEnrichmentState(
        lastHour: hour,
        attempted: {
          for (final entry in attempted.entries)
            if (entry.key != candidate.taskId) entry.key: entry.value,
          candidate.taskId: candidate.revision,
        },
        pending: pending,
      );

  AiEnrichmentState withEstimate(AiPendingEstimate estimate) =>
      AiEnrichmentState(
        lastHour: lastHour,
        attempted: attempted,
        pending: [
          estimate,
          for (final other in pending)
            if (other.taskId != estimate.taskId) other,
        ],
      );

  AiEnrichmentState withoutEstimate(AiPendingEstimate estimate) =>
      AiEnrichmentState(
        lastHour: lastHour,
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

  Map<String, Object?> toJson() => {
    'lastHour': lastHour,
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
    final hour = data['lastHour'] as int?;
    if ((hour == null && (attempted.isNotEmpty || pending.isNotEmpty)) ||
        pending.map((item) => item.taskId).toSet().length != pending.length) {
      throw const FormatException('Invalid enrichment history.');
    }
    return AiEnrichmentState(
      lastHour: hour,
      attempted: attempted,
      pending: pending,
    );
  }
}
