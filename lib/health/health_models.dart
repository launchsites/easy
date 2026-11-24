import 'dart:convert';

enum MeasurementKind {
  bodyWeight('Weight'),
  waist('Waist'),
  hips('Hips'),
  chest('Chest'),
  upperArm('Upper arm'),
  thigh('Thigh');

  const MeasurementKind(this.label);
  final String label;

  List<MeasurementUnit> get units => this == MeasurementKind.bodyWeight
      ? const [MeasurementUnit.kilograms, MeasurementUnit.pounds]
      : const [MeasurementUnit.centimeters, MeasurementUnit.inches];
}

enum MeasurementUnit {
  kilograms('kg', 1),
  pounds('lb', 0.45359237),
  centimeters('cm', 1),
  inches('in', 2.54);

  const MeasurementUnit(this.label, this._scale);
  final String label;
  final double _scale;

  double toBase(double value) => value * _scale;
  double fromBase(double value) => value / _scale;
}

double _validateValue(
  MeasurementKind kind,
  MeasurementUnit unit,
  double value,
) {
  final canonical = unit.toBase(value);
  if (!kind.units.contains(unit) ||
      !canonical.isFinite ||
      canonical <= 0 ||
      kind.units.any((display) => !display.fromBase(canonical).isFinite)) {
    throw const FormatException(
      'Enter a positive measurement in the selected unit.',
    );
  }
  return canonical;
}

class BodyMeasurement {
  BodyMeasurement({
    required String id,
    required this.kind,
    required this.unit,
    required this.value,
    required DateTime recordedAt,
  }) : id = _required(id, 'measurement ID'),
       recordedAt = recordedAt.toUtc(),
       baseValue = _validateValue(kind, unit, value);

  factory BodyMeasurement.fromJson(Map<String, dynamic> json) =>
      BodyMeasurement(
        id: _readString(json['id']),
        kind: _readEnum(MeasurementKind.values, json['kind']),
        unit: _readEnum(MeasurementUnit.values, json['unit']),
        value: _readNumber(json['value']),
        recordedAt: _readInstant(json['recordedAt']),
      );

  final String id;
  final MeasurementKind kind;
  final MeasurementUnit unit;
  final double value;
  final DateTime recordedAt;

  /// Kilograms for weight and centimeters for length.
  final double baseValue;

  double inUnit(MeasurementUnit target) {
    if (!kind.units.contains(target)) {
      throw ArgumentError('Incompatible measurement unit.');
    }
    return target == unit ? value : target.fromBase(baseValue);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'unit': unit.name,
    'value': value,
    'recordedAt': recordedAt.toIso8601String(),
  };
}

class MeasurementGoal {
  MeasurementGoal({required this.kind, required this.unit, required this.value})
    : baseValue = _validateValue(kind, unit, value);

  factory MeasurementGoal.fromJson(Map<String, dynamic> json) =>
      MeasurementGoal(
        kind: _readEnum(MeasurementKind.values, json['kind']),
        unit: _readEnum(MeasurementUnit.values, json['unit']),
        value: _readNumber(json['value']),
      );

  final MeasurementKind kind;
  final MeasurementUnit unit;
  final double value;
  final double baseValue;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'unit': unit.name,
    'value': value,
  };
}

class HealthExerciseTarget {
  const HealthExerciseTarget({
    required this.planId,
    required this.exerciseId,
    required this.name,
    required this.planName,
  });

  factory HealthExerciseTarget.fromJson(Map<String, dynamic> json) =>
      HealthExerciseTarget(
        planId: _required(_readString(json['planId']), 'workout plan ID'),
        exerciseId: _required(_readString(json['exerciseId']), 'exercise ID'),
        name: _required(_readString(json['name']), 'exercise name'),
        planName: _required(_readString(json['planName']), 'workout name'),
      );

  final String planId;
  final String exerciseId;
  final String name;
  final String planName;

  (String, String) get key => (planId, exerciseId);

  Map<String, Object?> toJson() => {
    'planId': planId,
    'exerciseId': exerciseId,
    'name': name,
    'planName': planName,
  };
}

enum HealthReviewOutcome { remainsOpen, resolved }

class HealthLimitationReview {
  HealthLimitationReview({
    required DateTime reviewedAt,
    required this.outcome,
    DateTime? reviewedOn,
    DateTime? nextReviewOn,
    this.note = '',
  }) : reviewedAt = reviewedAt.toUtc(),
       reviewedOn = _day(reviewedOn ?? reviewedAt.toLocal()),
       nextReviewOn = nextReviewOn == null ? null : _day(nextReviewOn) {
    if (outcome == HealthReviewOutcome.resolved && nextReviewOn != null) {
      throw const FormatException('Resolve or set another review date.');
    }
  }

  factory HealthLimitationReview.fromJson(Map<String, dynamic> json) =>
      HealthLimitationReview(
        reviewedAt: _readInstant(json['reviewedAt']),
        reviewedOn: _readDay(json['reviewedOn']),
        outcome: _readEnum(HealthReviewOutcome.values, json['outcome']),
        nextReviewOn: json['nextReviewOn'] == null
            ? null
            : _readDay(json['nextReviewOn']),
        note: _readString(json['note']),
      );

  final DateTime reviewedAt;
  final DateTime reviewedOn;
  final HealthReviewOutcome outcome;
  final DateTime? nextReviewOn;
  final String note;

  Map<String, Object?> toJson() => {
    'reviewedAt': reviewedAt.toIso8601String(),
    'reviewedOn': _dayKey(reviewedOn),
    'outcome': outcome.name,
    'nextReviewOn': nextReviewOn == null ? null : _dayKey(nextReviewOn!),
    'note': note,
  };
}

class HealthLimitation {
  HealthLimitation({
    required String id,
    required String title,
    required DateTime reportedOn,
    this.note = '',
    DateTime? reviewOn,
    this.allWorkouts = false,
    List<HealthExerciseTarget> exercises = const [],
    List<HealthLimitationReview> reviews = const [],
  }) : id = _required(id, 'note ID'),
       title = _required(title, 'note title'),
       reportedOn = _day(reportedOn),
       reviewOn = reviewOn == null ? null : _day(reviewOn),
       exercises = List.unmodifiable(exercises),
       reviews = List.unmodifiable(reviews) {
    if (this.reviewOn?.isBefore(this.reportedOn) ?? false) {
      throw const FormatException(
        'The review date is earlier than the report date.',
      );
    }
    if (exercises.map((exercise) => exercise.key).toSet().length !=
        exercises.length) {
      throw const FormatException('An exercise was selected more than once.');
    }
    DateTime? last;
    var resolved = false;
    for (final review in reviews) {
      final reviewDay = review.reviewedOn;
      if (resolved ||
          reviewDay.isBefore(this.reportedOn) ||
          (last != null && review.reviewedAt.isBefore(last)) ||
          (review.nextReviewOn?.isBefore(reviewDay) ?? false)) {
        throw const FormatException('Invalid limitation review history.');
      }
      last = review.reviewedAt;
      resolved = review.outcome == HealthReviewOutcome.resolved;
    }
  }

  factory HealthLimitation.fromJson(Map<String, dynamic> json) =>
      HealthLimitation(
        id: _readString(json['id']),
        title: _readString(json['title']),
        reportedOn: _readDay(json['reportedOn']),
        reviewOn: json['reviewOn'] == null ? null : _readDay(json['reviewOn']),
        note: _readString(json['note']),
        allWorkouts: _readBool(json['allWorkouts']),
        exercises: _readList(json['exercises'], HealthExerciseTarget.fromJson),
        reviews: _readList(json['reviews'], HealthLimitationReview.fromJson),
      );

  final String id;
  final String title;
  final DateTime reportedOn;
  final String note;
  final DateTime? reviewOn;
  final bool allWorkouts;
  final List<HealthExerciseTarget> exercises;
  final List<HealthLimitationReview> reviews;

  bool get open => reviews.lastOrNull?.outcome != HealthReviewOutcome.resolved;

  DateTime? get nextReviewOn =>
      reviews.isEmpty ? reviewOn : reviews.last.nextReviewOn;

  bool reviewIsDue(DateTime now) {
    final date = nextReviewOn;
    return open && date != null && !_day(now.toLocal()).isBefore(date);
  }

  /// Scope comes from user-selected exercise identities or an explicit
  /// workout-wide flag. Review dates do not deactivate a recorded limitation.
  bool applies({
    required String? planId,
    required Set<String> exerciseIds,
    required DateTime workoutAt,
  }) {
    final date = _day(workoutAt.toLocal());
    if (date.isBefore(reportedOn)) return false;
    final last = reviews.lastOrNull;
    if (last?.outcome == HealthReviewOutcome.resolved &&
        !workoutAt.isBefore(last!.reviewedAt)) {
      return false;
    }
    return allWorkouts ||
        exercises.any(
          (reference) =>
              reference.planId == planId &&
              exerciseIds.contains(reference.exerciseId),
        );
  }

  HealthLimitation withReview(HealthLimitationReview entry) => HealthLimitation(
    id: id,
    title: title,
    reportedOn: reportedOn,
    note: note,
    reviewOn: reviewOn,
    allWorkouts: allWorkouts,
    exercises: exercises,
    reviews: [...reviews, entry],
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'reportedOn': _dayKey(reportedOn),
    'note': note,
    'reviewOn': reviewOn == null ? null : _dayKey(reviewOn!),
    'allWorkouts': allWorkouts,
    'exercises': [for (final target in exercises) target.toJson()],
    'reviews': [for (final item in reviews) item.toJson()],
  };
}

class WorkoutHealthDecision {
  WorkoutHealthDecision({
    required this.planId,
    required DateTime workoutAt,
    required DateTime reviewedAt,
    required Iterable<String> reviewedNoteIds,
    Iterable<String> skippedExerciseIds = const [],
  }) : workoutAt = workoutAt.toUtc(),
       reviewedAt = reviewedAt.toUtc(),
       reviewedNoteIds = Set.unmodifiable(reviewedNoteIds),
       skippedExerciseIds = Set.unmodifiable(skippedExerciseIds);

  factory WorkoutHealthDecision.fromJson(Map<String, dynamic> json) =>
      WorkoutHealthDecision(
        planId: json['planId'] == null ? null : _readString(json['planId']),
        workoutAt: _readInstant(json['workoutAt']),
        reviewedAt: _readInstant(json['reviewedAt']),
        reviewedNoteIds: _readStrings(json['reviewedNoteIds']),
        skippedExerciseIds: _readStrings(json['skippedExerciseIds']),
      );

  final String? planId;
  final DateTime workoutAt;
  final DateTime reviewedAt;
  final Set<String> reviewedNoteIds;
  final Set<String> skippedExerciseIds;

  Map<String, Object?> toJson() => {
    'planId': planId,
    'workoutAt': workoutAt.toIso8601String(),
    'reviewedAt': reviewedAt.toIso8601String(),
    'reviewedNoteIds': reviewedNoteIds.toList()..sort(),
    'skippedExerciseIds': skippedExerciseIds.toList()..sort(),
  };
}

class HealthData {
  HealthData({
    List<BodyMeasurement> measurements = const [],
    List<MeasurementGoal> goals = const [],
    List<HealthLimitation> limitations = const [],
    List<WorkoutHealthDecision> decisions = const [],
  }) : measurements = List.unmodifiable(measurements),
       goals = List.unmodifiable(goals),
       limitations = List.unmodifiable(limitations),
       decisions = List.unmodifiable(decisions) {
    if (measurements.map((item) => item.id).toSet().length !=
            measurements.length ||
        goals.map((item) => item.kind).toSet().length != goals.length ||
        limitations.map((item) => item.id).toSet().length !=
            limitations.length ||
        decisions.map((item) => (item.planId, item.workoutAt)).toSet().length !=
            decisions.length) {
      throw const FormatException(
        'Health records contain repeated identifiers.',
      );
    }
  }

  factory HealthData.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported health version.');
    }
    return HealthData(
      measurements: _readList(json['measurements'], BodyMeasurement.fromJson),
      goals: _readList(json['goals'], MeasurementGoal.fromJson),
      limitations: _readList(json['limitations'], HealthLimitation.fromJson),
      decisions: _readList(json['decisions'], WorkoutHealthDecision.fromJson),
    );
  }

  factory HealthData.decode(String value) =>
      HealthData.fromJson(_readObject(jsonDecode(value)));

  final List<BodyMeasurement> measurements;
  final List<MeasurementGoal> goals;
  final List<HealthLimitation> limitations;
  final List<WorkoutHealthDecision> decisions;

  List<HealthLimitation> forWorkout({
    required String? planId,
    required Iterable<String> exerciseIds,
    required DateTime workoutAt,
  }) {
    final ids = exerciseIds.toSet();
    return [
      for (final item in limitations)
        if (item.applies(
          planId: planId,
          exerciseIds: ids,
          workoutAt: workoutAt,
        ))
          item,
    ];
  }

  HealthData withMeasurement(BodyMeasurement value) => HealthData(
    measurements: [
      for (final item in measurements)
        if (item.id != value.id) item,
      value,
    ],
    goals: goals,
    limitations: limitations,
    decisions: decisions,
  );

  HealthData withoutMeasurement(String id) => HealthData(
    measurements: measurements.where((item) => item.id != id).toList(),
    goals: goals,
    limitations: limitations,
    decisions: decisions,
  );

  HealthData withGoal(MeasurementKind kind, MeasurementGoal? goal) {
    if (goal != null && goal.kind != kind) {
      throw ArgumentError('Different goal measurement.');
    }
    return HealthData(
      measurements: measurements,
      goals: [
        for (final item in goals)
          if (item.kind != kind) item,
        ?goal,
      ],
      limitations: limitations,
      decisions: decisions,
    );
  }

  HealthData withLimitation(HealthLimitation value) => HealthData(
    measurements: measurements,
    goals: goals,
    limitations: [
      for (final item in limitations)
        if (item.id != value.id) item,
      value,
    ],
    decisions: decisions,
  );

  HealthData withWorkoutDecision(WorkoutHealthDecision value) {
    if (decisions.any(
      (item) =>
          item.planId == value.planId && item.workoutAt == value.workoutAt,
    )) {
      throw const FormatException(
        'This session already has a recorded review.',
      );
    }
    return HealthData(
      measurements: measurements,
      goals: goals,
      limitations: limitations,
      decisions: [...decisions, value],
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'measurements': [for (final item in measurements) item.toJson()],
    'goals': [for (final item in goals) item.toJson()],
    'limitations': [for (final item in limitations) item.toJson()],
    'decisions': [for (final item in decisions) item.toJson()],
  };

  String encode() => jsonEncode(toJson());
}

DateTime _day(DateTime date) => DateTime.utc(date.year, date.month, date.day);
String _dayKey(DateTime value) =>
    value.toUtc().toIso8601String().split('T').first;

DateTime _readDay(Object? value) {
  final key = _readString(value);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key)) {
    throw const FormatException('Expected a health record date.');
  }
  final date = DateTime.tryParse('${key}T00:00:00Z');
  if (date == null || date.year < 1 || _dayKey(date) != key) {
    throw const FormatException('Invalid health record date.');
  }
  return date;
}

DateTime _readInstant(Object? value) {
  final instant = DateTime.tryParse(_readString(value));
  if (instant == null || !instant.isUtc) {
    throw const FormatException('Expected a UTC health record timestamp.');
  }
  return instant;
}

String _readString(Object? value) => value is String
    ? value
    : throw const FormatException('Expected health record text.');

String _required(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('Enter a $label.');
  return value;
}

double _readNumber(Object? value) => value is num && value.isFinite
    ? value.toDouble()
    : throw const FormatException('Invalid measurement number.');

bool _readBool(Object? value) => value is bool
    ? value
    : throw const FormatException('Expected a health scope.');

T _readEnum<T extends Enum>(List<T> values, Object? name) =>
    values.where((item) => item.name == name).firstOrNull ??
    (throw const FormatException('Unknown health record value.'));

Map<String, dynamic> _readObject(Object? value) => value is Map<String, dynamic>
    ? value
    : throw const FormatException('Invalid health record.');

List<T> _readList<T>(Object? value, T Function(Map<String, dynamic>) decode) =>
    value is List<dynamic>
    ? [for (final item in value) decode(_readObject(item))]
    : throw const FormatException('Expected health records.');

List<String> _readStrings(Object? value) => value is List<dynamic>
    ? [for (final item in value) _readString(item)]
    : throw const FormatException('Expected health record IDs.');
