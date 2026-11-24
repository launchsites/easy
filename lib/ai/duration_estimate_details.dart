/// An optional planning range supplied by the model alongside its estimate.
class AiEstimateRange {
  const AiEstimateRange._(this.lowerMinutes, this.upperMinutes);

  final int lowerMinutes;
  final int upperMinutes;

  Map<String, int> toJson() => {
    'lowerMinutes': lowerMinutes,
    'upperMinutes': upperMinutes,
  };

  static AiEstimateRange? tryParse(Object? value, int pointMinutes) {
    if (value is! Map || value.length != 2) return null;
    final lower = value['lowerMinutes'];
    final upper = value['upperMinutes'];
    if (lower is! int ||
        upper is! int ||
        lower < 1 ||
        upper > 1440 ||
        lower >= upper ||
        pointMinutes < lower ||
        pointMinutes > upper) {
      return null;
    }
    return AiEstimateRange._(lower, upper);
  }
}

/// The evidence count is derived from the request sent to the model.
class AiEstimateDetails {
  const AiEstimateDetails({required this.disclosedDurations, this.range});

  final int disclosedDurations;
  final AiEstimateRange? range;

  String get reviewDescription {
    final context = switch (disclosedDurations) {
      0 => 'Model received the task title only.',
      1 => 'Model received the task title and one recorded duration.',
      _ =>
        'Model received the task title and $disclosedDurations recorded durations.',
    };
    final bounds = range;
    if (bounds == null) return context;
    return 'Model range ${bounds.lowerMinutes}–${bounds.upperMinutes} min\n$context';
  }

  Map<String, Object> toJson() => {
    'disclosedDurations': disclosedDurations,
    if (range case final value?) 'range': value.toJson(),
  };

  static AiEstimateDetails? tryParse(Object? value, int pointMinutes) {
    if (value is! Map) return null;
    final count = value['disclosedDurations'];
    if (count is! int || count < 0 || count > 32) return null;
    final range = AiEstimateRange.tryParse(value['range'], pointMinutes);
    return AiEstimateDetails(disclosedDurations: count, range: range);
  }
}
