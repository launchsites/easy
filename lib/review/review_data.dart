import 'dart:convert';

import '../workout_plan.dart';

DateTime reviewDay(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _civilDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

DateTime nextReviewDay(DateTime date, [int count = 1]) =>
    DateTime(date.year, date.month, date.day + count);

String reviewDayKey(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

DateTime _readDay(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Expected a calendar date.');
  }
  final parsed = DateTime.tryParse('${value}T00:00:00Z');
  if (parsed == null || parsed.year < 1 || reviewDayKey(parsed) != value) {
    throw const FormatException('Invalid calendar date.');
  }
  return parsed;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a review record.');
  }
  return value;
}

List<T> _items<T>(Object? value, T Function(Map<String, dynamic>) read) {
  if (value is! List<dynamic>) {
    throw const FormatException('Expected a list of review records.');
  }
  return [for (final item in value) read(_object(item))];
}

String _text(Object? value) {
  if (value is! String) throw const FormatException('Expected review text.');
  return value;
}

String _name(Object? value, String label) {
  final text = _text(value).trim();
  if (text.isEmpty || text.length > 160) {
    throw FormatException('Enter a $label of at most 160 characters.');
  }
  return text;
}

DateTime _timestamp(Object? value) {
  final instant = DateTime.tryParse(_text(value));
  if (instant == null || !instant.isUtc) {
    throw const FormatException('Expected a UTC review timestamp.');
  }
  return instant;
}

T _enum<T extends Enum>(List<T> values, Object? value) =>
    values.where((item) => item.name == value).firstOrNull ??
    (throw const FormatException('Unknown review outcome.'));

enum ReviewOutcome { completed, partial, skipped }

class ReviewReflection {
  ReviewReflection({
    required String id,
    required DateTime savedAt,
    this.achieved = '',
    this.obstacle = '',
    this.tomorrow = '',
  }) : id = _name(id, 'reflection ID'),
       savedAt = savedAt.toUtc() {
    if ([achieved, obstacle, tomorrow].every((text) => text.trim().isEmpty)) {
      throw const FormatException('Write a reflection before saving.');
    }
  }

  factory ReviewReflection.fromJson(Map<String, dynamic> json) =>
      ReviewReflection(
        id: _text(json['id']),
        savedAt: _timestamp(json['savedAt']),
        achieved: _text(json['achieved']),
        obstacle: _text(json['obstacle']),
        tomorrow: _text(json['tomorrow']),
      );

  final String id;
  final DateTime savedAt;
  final String achieved;
  final String obstacle;
  final String tomorrow;

  Map<String, Object?> toJson() => {
    'id': id,
    'savedAt': savedAt.toIso8601String(),
    'achieved': achieved,
    'obstacle': obstacle,
    'tomorrow': tomorrow,
  };
}

class DailyReview {
  DailyReview({
    required DateTime day,
    this.priorities = '',
    List<ReviewReflection> reflections = const [],
    Map<String, ReviewOutcome> outcomes = const {},
  }) : day = _civilDay(day),
       reflections = List.unmodifiable(reflections),
       outcomes = Map.unmodifiable(outcomes) {
    if (reflections.map((entry) => entry.id).toSet().length !=
        reflections.length) {
      throw const FormatException('Duplicate reflections in the same review.');
    }
  }

  factory DailyReview.fromJson(Map<String, dynamic> json) => DailyReview(
    day: _readDay(json['day']),
    priorities: _text(json['priorities']),
    reflections: _items(json['reflections'], ReviewReflection.fromJson),
    outcomes: {
      for (final entry in _object(json['outcomes']).entries)
        entry.key: _enum(ReviewOutcome.values, entry.value),
    },
  );

  final DateTime day;
  final String priorities;
  final List<ReviewReflection> reflections;
  final Map<String, ReviewOutcome> outcomes;

  bool get hasEntries =>
      priorities.trim().isNotEmpty ||
      reflections.isNotEmpty ||
      outcomes.isNotEmpty;

  DailyReview withPriorities(String value) => DailyReview(
    day: day,
    priorities: value,
    reflections: reflections,
    outcomes: outcomes,
  );

  DailyReview withReflection(ReviewReflection entry) {
    final existing = reflections
        .where((reflection) => reflection.id == entry.id)
        .firstOrNull;
    if (existing != null) {
      if (existing.savedAt == entry.savedAt &&
          existing.achieved == entry.achieved &&
          existing.obstacle == entry.obstacle &&
          existing.tomorrow == entry.tomorrow) {
        return this;
      }
      throw const FormatException('This reflection ID already exists.');
    }
    return DailyReview(
      day: day,
      priorities: priorities,
      reflections: [...reflections, entry],
      outcomes: outcomes,
    );
  }

  DailyReview withOutcome(String eventId, ReviewOutcome? outcome) {
    final next = {...outcomes};
    if (outcome == null) {
      next.remove(eventId);
    } else {
      next[_name(eventId, 'event ID')] = outcome;
    }
    return DailyReview(
      day: day,
      priorities: priorities,
      reflections: reflections,
      outcomes: next,
    );
  }

  Map<String, Object?> toJson() => {
    'day': reviewDayKey(day),
    'priorities': priorities,
    'reflections': [for (final reflection in reflections) reflection.toJson()],
    'outcomes': {
      for (final entry in outcomes.entries) entry.key: entry.value.name,
    },
  };
}

class HabitRevision {
  HabitRevision({
    required DateTime effectiveOn,
    required String name,
    required this.schedule,
  }) : effectiveOn = _civilDay(effectiveOn),
       name = _name(name, 'habit name') {
    if (schedule.nextOnOrAfter(reviewDay(this.effectiveOn)) == null) {
      throw const FormatException(
        'Choose at least one occurrence on or after the start date.',
      );
    }
  }

  factory HabitRevision.fromJson(Map<String, dynamic> json) => HabitRevision(
    effectiveOn: _readDay(json['effectiveOn']),
    name: _text(json['name']),
    schedule: WorkoutSchedule.fromJson(_object(json['schedule'])),
  );

  final DateTime effectiveOn;
  final String name;
  final WorkoutSchedule schedule;

  Map<String, Object?> toJson() => {
    'effectiveOn': reviewDayKey(effectiveOn),
    'name': name,
    'schedule': schedule.toJson(),
  };
}

class HabitPause {
  HabitPause({required DateTime start, required DateTime end, this.reason = ''})
    : start = _civilDay(start),
      end = _civilDay(end) {
    if (this.end.isBefore(this.start)) {
      throw const FormatException('The pause ends before it starts.');
    }
  }

  factory HabitPause.fromJson(Map<String, dynamic> json) => HabitPause(
    start: _readDay(json['start']),
    end: _readDay(json['end']),
    reason: _text(json['reason']),
  );

  final DateTime start;
  final DateTime end;
  final String reason;

  bool covers(DateTime day) {
    final date = _civilDay(day);
    return !date.isBefore(start) && !date.isAfter(end);
  }

  Map<String, Object?> toJson() => {
    'start': reviewDayKey(start),
    'end': reviewDayKey(end),
    'reason': reason,
  };
}

class Habit {
  Habit({
    required String id,
    required List<HabitRevision> revisions,
    List<HabitPause> pauses = const [],
    DateTime? archivedOn,
  }) : id = _name(id, 'habit ID'),
       revisions = List.unmodifiable(
         revisions.toList()
           ..sort((a, b) => a.effectiveOn.compareTo(b.effectiveOn)),
       ),
       pauses = List.unmodifiable(pauses),
       archivedOn = archivedOn == null ? null : _civilDay(archivedOn) {
    if (revisions.isEmpty ||
        revisions
                .map((revision) => reviewDayKey(revision.effectiveOn))
                .toSet()
                .length !=
            revisions.length) {
      throw const FormatException('A habit needs distinct schedule versions.');
    }
  }

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
    id: _text(json['id']),
    revisions: _items(json['revisions'], HabitRevision.fromJson),
    pauses: _items(json['pauses'], HabitPause.fromJson),
    archivedOn: json['archivedOn'] == null
        ? null
        : _readDay(json['archivedOn']),
  );

  final String id;
  final List<HabitRevision> revisions;
  final List<HabitPause> pauses;
  final DateTime? archivedOn;

  HabitRevision? revisionFor(DateTime day) {
    final date = _civilDay(day);
    return revisions.reversed
        .where((revision) => !revision.effectiveOn.isAfter(date))
        .firstOrNull;
  }

  bool isArchivedOn(DateTime day) {
    final archived = archivedOn;
    return archived != null && !_civilDay(day).isBefore(archived);
  }

  bool isScheduledOn(DateTime day) {
    final date = _civilDay(day);
    final revision = revisionFor(date);
    return revision != null &&
        !isArchivedOn(date) &&
        revision.schedule.occursOn(reviewDay(date)) &&
        !pauses.any((pause) => pause.covers(date));
  }

  bool isPausedOn(DateTime day) => pauses.any((pause) => pause.covers(day));

  Habit withRevision(HabitRevision revision) => Habit(
    id: id,
    revisions: [
      for (final item in revisions)
        if (item.effectiveOn != revision.effectiveOn) item,
      revision,
    ],
    pauses: pauses,
    archivedOn: archivedOn,
  );

  Habit withPause(HabitPause pause) => Habit(
    id: id,
    revisions: revisions,
    pauses: [...pauses, pause],
    archivedOn: archivedOn,
  );

  Habit archivedFrom(DateTime? day) =>
      Habit(id: id, revisions: revisions, pauses: pauses, archivedOn: day);

  Map<String, Object?> toJson() => {
    'id': id,
    'revisions': [for (final item in revisions) item.toJson()],
    'pauses': [for (final item in pauses) item.toJson()],
    'archivedOn': archivedOn == null ? null : reviewDayKey(archivedOn!),
  };
}

enum HabitOutcome { done, skipped }

class HabitCheckin {
  HabitCheckin({
    required String habitId,
    required DateTime day,
    required this.outcome,
  }) : habitId = _name(habitId, 'habit ID'),
       day = _civilDay(day);

  factory HabitCheckin.fromJson(Map<String, dynamic> json) => HabitCheckin(
    habitId: _text(json['habitId']),
    day: _readDay(json['day']),
    outcome: _enum(HabitOutcome.values, json['outcome']),
  );

  final String habitId;
  final DateTime day;
  final HabitOutcome outcome;
  (String, String) get _key => (habitId, reviewDayKey(day));

  Map<String, Object?> toJson() => {
    'habitId': habitId,
    'day': reviewDayKey(day),
    'outcome': outcome.name,
  };
}

class ReviewData {
  ReviewData({
    List<DailyReview> days = const [],
    List<Habit> habits = const [],
    List<HabitCheckin> checkins = const [],
  }) : _days = Map.unmodifiable({
         for (final day in days) reviewDayKey(day.day): day,
       }),
       _habits = Map.unmodifiable({
         for (final habit in habits) habit.id: habit,
       }),
       _checkins = Map.unmodifiable({
         for (final entry in checkins) entry._key: entry,
       }) {
    if (_days.length != days.length ||
        _habits.length != habits.length ||
        _checkins.length != checkins.length ||
        checkins.any((entry) => !_habits.containsKey(entry.habitId))) {
      throw const FormatException(
        'Review history contains inconsistent records.',
      );
    }
  }

  factory ReviewData.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported review version.');
    }
    return ReviewData(
      days: _items(json['days'], DailyReview.fromJson),
      habits: _items(json['habits'], Habit.fromJson),
      checkins: _items(json['checkins'], HabitCheckin.fromJson),
    );
  }

  factory ReviewData.decode(String value) =>
      ReviewData.fromJson(_object(jsonDecode(value)));

  final Map<String, DailyReview> _days;
  final Map<String, Habit> _habits;
  final Map<(String, String), HabitCheckin> _checkins;

  Iterable<Habit> get habits => _habits.values;
  Iterable<ReviewReflection> get reflections =>
      _days.values.expand((day) => day.reflections);

  DailyReview dayFor(DateTime day) =>
      _days[reviewDayKey(day)] ?? DailyReview(day: day);

  HabitCheckin? habitCheckin(String id, DateTime day) =>
      _checkins[(id, reviewDayKey(day))];

  Iterable<Habit> habitsOn(DateTime day) => habits.where(
    (habit) => habit.isScheduledOn(day) || habitCheckin(habit.id, day) != null,
  );

  ReviewData withDay(DailyReview day) {
    final days = {..._days};
    final key = reviewDayKey(day.day);
    if (day.hasEntries) {
      days[key] = day;
    } else {
      days.remove(key);
    }
    return ReviewData(
      days: days.values.toList(),
      habits: habits.toList(),
      checkins: _checkins.values.toList(),
    );
  }

  ReviewData withHabit(Habit habit) => ReviewData(
    days: _days.values.toList(),
    habits: {..._habits, habit.id: habit}.values.toList(),
    checkins: _checkins.values.toList(),
  );

  ReviewData checkIn({
    required String id,
    required DateTime day,
    required HabitOutcome? outcome,
  }) {
    final habit = _habits[id];
    final key = (id, reviewDayKey(day));
    final checkins = {..._checkins};
    if (outcome == null) {
      checkins.remove(key);
    } else {
      if (habit == null ||
          (!habit.isScheduledOn(day) && !_checkins.containsKey(key))) {
        throw const FormatException(
          'There is no habit occurrence on this day.',
        );
      }
      checkins[key] = HabitCheckin(habitId: id, day: day, outcome: outcome);
    }
    return ReviewData(
      days: _days.values.toList(),
      habits: habits.toList(),
      checkins: checkins.values.toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'days': [for (final item in _days.values) item.toJson()],
    'habits': [for (final item in habits) item.toJson()],
    'checkins': [for (final item in _checkins.values) item.toJson()],
  };

  String encode() => jsonEncode(toJson());
}
