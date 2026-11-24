import 'dart:convert';
import 'dart:math' as math;

enum WorkoutScheduleKind { once, weekdays, interval }

enum WorkoutExerciseKind { cardio, strength }

class WorkoutSchedule {
  WorkoutSchedule({
    required this.kind,
    required DateTime startDate,
    List<int> weekdays = const [],
    this.intervalDays = 1,
  }) : startDate = _dateOnly(startDate),
       weekdays = List.unmodifiable(weekdays.toSet().toList()..sort()) {
    if (intervalDays < 1) {
      throw ArgumentError.value(
        intervalDays,
        'intervalDays',
        'Must be positive.',
      );
    }
    if (this.weekdays.any(
      (day) => day < DateTime.monday || day > DateTime.sunday,
    )) {
      throw ArgumentError.value(
        weekdays,
        'weekdays',
        'Use ISO weekdays 1 through 7.',
      );
    }
  }

  factory WorkoutSchedule.fromJson(Map<String, dynamic> json) =>
      WorkoutSchedule(
        kind: _readEnum(WorkoutScheduleKind.values, json, 'kind'),
        startDate: _readDate(json, 'startDate'),
        weekdays: _readList(
          json,
          'weekdays',
        ).map((value) => _readInt(value, 'weekdays')).toList(),
        intervalDays: _readInt(json['intervalDays'] ?? 1, 'intervalDays'),
      );

  final WorkoutScheduleKind kind;
  final DateTime startDate;
  final List<int> weekdays;
  final int intervalDays;

  DateTime? nextOnOrAfter(DateTime day) {
    final query = _dateOnly(day);
    final candidate = query.isBefore(startDate) ? startDate : query;
    switch (kind) {
      case WorkoutScheduleKind.once:
        return candidate == startDate ? startDate : null;
      case WorkoutScheduleKind.weekdays:
        if (weekdays.isEmpty) return null;
        final offset = weekdays
            .map((weekday) => (weekday - candidate.weekday) % 7)
            .reduce(math.min);
        return _plusDays(candidate, offset);
      case WorkoutScheduleKind.interval:
        final elapsed = _civilDaysBetween(startDate, candidate);
        final offset = -elapsed % intervalDays;
        final epochDay = _civilDaysBetween(DateTime.utc(1970), candidate);
        // Dart dates span 100 million days in either direction from the epoch.
        if (offset >= 100000000 - epochDay && offset > 0) return null;
        return _plusDays(candidate, offset);
    }
  }

  bool occursOn(DateTime day) => nextOnOrAfter(day) == _dateOnly(day);

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'startDate': startDate.toIso8601String().split('T').first,
    'weekdays': weekdays,
    'intervalDays': intervalDays,
  };
}

class WorkoutSet {
  WorkoutSet({required this.id, this.weightKg = 0, this.reps = 8}) {
    _requireNonnegative(weightKg, 'weightKg');
    _requireNonnegative(reps, 'reps');
  }

  factory WorkoutSet.fromJson(Map<String, dynamic> json) => WorkoutSet(
    id: _readString(json, 'id'),
    weightKg: _readNumber(json['weightKg'] ?? 0, 'weightKg').toDouble(),
    reps: _readInt(json['reps'] ?? 8, 'reps'),
  );

  final String id;
  final double weightKg;
  final int reps;

  WorkoutSet copyWith({String? id, double? weightKg, int? reps}) => WorkoutSet(
    id: id ?? this.id,
    weightKg: weightKg ?? this.weightKg,
    reps: reps ?? this.reps,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'weightKg': weightKg,
    'reps': reps,
  };
}

class WorkoutExercise {
  WorkoutExercise({
    required this.id,
    required this.name,
    required this.kind,
    this.distanceKm = 0,
    this.inclinePercent = 0,
    this.minutes = 0,
    List<WorkoutSet> sets = const [],
  }) : sets = List.unmodifiable(sets) {
    _requireNonnegative(distanceKm, 'distanceKm');
    _requireNonnegative(minutes, 'minutes');
    if (!inclinePercent.isFinite) {
      throw ArgumentError.value(
        inclinePercent,
        'inclinePercent',
        'Must be finite.',
      );
    }
  }

  factory WorkoutExercise.fromJson(Map<String, dynamic> json) =>
      WorkoutExercise(
        id: _readString(json, 'id'),
        name: _readString(json, 'name'),
        kind: _readEnum(WorkoutExerciseKind.values, json, 'kind'),
        distanceKm: _readNumber(
          json['distanceKm'] ?? 0,
          'distanceKm',
        ).toDouble(),
        inclinePercent: _readNumber(
          json['inclinePercent'] ?? 0,
          'inclinePercent',
        ).toDouble(),
        minutes: _readInt(json['minutes'] ?? 0, 'minutes'),
        sets: _readList(json, 'sets')
            .map((value) => WorkoutSet.fromJson(_readObject(value, 'sets')))
            .toList(),
      );

  final String id;
  final String name;
  final WorkoutExerciseKind kind;
  final double distanceKm;
  final double inclinePercent;
  final int minutes;
  final List<WorkoutSet> sets;

  WorkoutExercise copyWith({
    String? id,
    String? name,
    WorkoutExerciseKind? kind,
    double? distanceKm,
    double? inclinePercent,
    int? minutes,
    List<WorkoutSet>? sets,
  }) => WorkoutExercise(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    distanceKm: distanceKm ?? this.distanceKm,
    inclinePercent: inclinePercent ?? this.inclinePercent,
    minutes: minutes ?? this.minutes,
    sets: sets ?? this.sets,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'distanceKm': distanceKm,
    'inclinePercent': inclinePercent,
    'minutes': minutes,
    'sets': sets.map((set) => set.toJson()).toList(),
  };
}

class WorkoutPlan {
  WorkoutPlan({
    required this.id,
    required this.name,
    required this.schedule,
    required List<WorkoutExercise> exercises,
  }) : exercises = List.unmodifiable(exercises);

  factory WorkoutPlan.fromJson(Map<String, dynamic> json) => WorkoutPlan(
    id: _readString(json, 'id'),
    name: _readString(json, 'name'),
    schedule: WorkoutSchedule.fromJson(
      _readObject(json['schedule'], 'schedule'),
    ),
    exercises: _readList(json, 'exercises')
        .map(
          (value) => WorkoutExercise.fromJson(_readObject(value, 'exercises')),
        )
        .toList(),
  );

  factory WorkoutPlan.decode(String source) {
    try {
      return WorkoutPlan.fromJson(
        _readObject(jsonDecode(source), 'workout plan'),
      );
    } on ArgumentError catch (error) {
      throw FormatException(error.message.toString());
    }
  }

  final String id;
  final String name;
  final WorkoutSchedule schedule;
  final List<WorkoutExercise> exercises;

  WorkoutPlan copyWith({
    String? id,
    String? name,
    WorkoutSchedule? schedule,
    List<WorkoutExercise>? exercises,
  }) => WorkoutPlan(
    id: id ?? this.id,
    name: name ?? this.name,
    schedule: schedule ?? this.schedule,
    exercises: exercises ?? this.exercises,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'schedule': schedule.toJson(),
    'exercises': exercises.map((exercise) => exercise.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());
}

int _workoutIdSequence = 0;

String newWorkoutId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final sequence = (_workoutIdSequence++).toRadixString(36);
  return 'workout-$timestamp-$sequence';
}

DateTime _dateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

DateTime _plusDays(DateTime value, int days) =>
    DateTime(value.year, value.month, value.day + days);

int _civilDaysBetween(DateTime first, DateTime second) => DateTime.utc(
  second.year,
  second.month,
  second.day,
).difference(DateTime.utc(first.year, first.month, first.day)).inDays;

void _requireNonnegative(num value, String field) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, field, 'Must be finite and nonnegative.');
  }
}

Map<String, dynamic> _readObject(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Expected an object for $field.');
}

List<dynamic> _readList(Map<String, dynamic> data, String field) {
  final value = data[field];
  if (value == null) return const [];
  if (value is List) return value;
  throw FormatException('Expected a list for $field.');
}

String _readString(Map<String, dynamic> data, String field) {
  final value = data[field];
  if (value is String) return value;
  throw FormatException('Expected text for $field.');
}

num _readNumber(Object? value, String field) {
  if (value is num && value.isFinite) return value;
  throw FormatException('Expected a number for $field.');
}

int _readInt(Object? value, String field) {
  final number = _readNumber(value, field);
  if (number == number.toInt()) return number.toInt();
  throw FormatException('Expected a whole number for $field.');
}

T _readEnum<T extends Enum>(
  List<T> values,
  Map<String, dynamic> data,
  String field,
) {
  final name = _readString(data, field);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown value for $field.');
}

final _datePattern = RegExp(r'^([+-]?\d{4,6})-(\d{2})-(\d{2})$');

DateTime _readDate(Map<String, dynamic> data, String field) {
  final match = _datePattern.firstMatch(_readString(data, field));
  if (match == null) {
    throw FormatException('Expected a calendar date for $field.');
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    throw FormatException('Invalid calendar date for $field.');
  }
  return date;
}
