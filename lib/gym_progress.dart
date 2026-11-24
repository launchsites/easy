import 'dart:math' as math;

import 'gym_session.dart';
import 'health/health_models.dart';
import 'workout_plan.dart';

enum GymProgressMetric {
  heaviestSet('Heaviest set'),
  mostReps('Most reps in a set'),
  distance('Distance'),
  duration('Duration'),
  bodyWeight('Body weight');

  const GymProgressMetric(this.label);
  final String label;

  bool get isWeight => this == heaviestSet || this == bodyWeight;
}

typedef GymProgressKey = ({
  WorkoutExerciseKind? kind,
  String scope,
  String owner,
  String exercise,
});

class GymProgressRecord {
  GymProgressRecord._exercise(GymSession workout, WorkoutExercise exercise)
    : at = workout.startedAt,
      session = workout,
      measurement = null {
    if (exercise.kind == WorkoutExerciseKind.strength &&
        exercise.sets.isNotEmpty) {
      final completed = <WorkoutSet>[];
      for (final set in exercise.sets) {
        switch (workout.progressFor(exercise.id, setId: set.id)) {
          case GymProgress.done:
            completed.add(set);
            _confirmed++;
            _heaviest = math.max(_heaviest ?? set.weightKg, set.weightKg);
            _mostReps = math.max(_mostReps ?? set.reps, set.reps);
          case GymProgress.skipped:
            _skipped++;
          case GymProgress.pending:
            _unconfirmed++;
        }
      }
      confirmedSets = List.unmodifiable(completed);
      return;
    }
    confirmedSets = const [];
    switch (workout.progressFor(exercise.id)) {
      case GymProgress.done:
        _confirmed++;
        if (exercise.kind == WorkoutExerciseKind.cardio) _cardio = exercise;
      case GymProgress.skipped:
        _skipped++;
      case GymProgress.pending:
        _unconfirmed++;
    }
  }

  GymProgressRecord._weight(BodyMeasurement value)
    : at = value.recordedAt,
      measurement = value,
      session = null,
      _confirmed = 1 {
    confirmedSets = const [];
  }

  final DateTime at;
  final GymSession? session;
  final BodyMeasurement? measurement;
  WorkoutExercise? _cardio;
  double? _heaviest;
  int? _mostReps;
  int _confirmed = 0;
  int _skipped = 0;
  int _unconfirmed = 0;
  late final List<WorkoutSet> confirmedSets;

  WorkoutExercise? get confirmedCardio => _cardio;
  int get confirmed => _confirmed;
  int get skipped => _skipped;
  int get unconfirmed => _unconfirmed;

  num? valueFor(GymProgressMetric metric) => switch (metric) {
    GymProgressMetric.heaviestSet => _heaviest,
    GymProgressMetric.mostReps => _mostReps,
    GymProgressMetric.distance => _cardio?.distanceKm,
    GymProgressMetric.duration => _cardio?.minutes,
    GymProgressMetric.bodyWeight => measurement?.baseValue,
  };
}

typedef GymTrendPoint = ({DateTime at, num value, bool startsSegment});

class GymProgressTrend {
  GymProgressTrend._(
    List<GymProgressRecord> records,
    GymProgressMetric metric,
  ) {
    final newestFirst = <({DateTime at, num value, bool separatesOlder})>[];
    var separatesOlder = true;
    var count = 0;
    for (final record in records) {
      final value = record.valueFor(metric);
      if (value == null) {
        separatesOlder = true;
        continue;
      }
      count++;
      if (newestFirst.length < maxChartPoints) {
        newestFirst.add((at: record.at, value: value, separatesOlder: false));
        final newerIndex = newestFirst.length - 2;
        if (separatesOlder && newerIndex >= 0) {
          final newer = newestFirst[newerIndex];
          newestFirst[newerIndex] = (
            at: newer.at,
            value: newer.value,
            separatesOlder: true,
          );
        }
      }
      separatesOlder = false;
    }
    valueCount = count;
    points = List.unmodifiable([
      for (var i = newestFirst.length - 1; i >= 0; i--)
        (
          at: newestFirst[i].at,
          value: newestFirst[i].value,
          startsSegment:
              i == newestFirst.length - 1 || newestFirst[i].separatesOlder,
        ),
    ]);
  }

  static const maxChartPoints = 96;

  late final int valueCount;
  late final List<GymTrendPoint> points;

  bool get canChart =>
      points.length > 1 && !points.first.at.isAtSameMomentAs(points.last.at);
}

class GymProgressSeries {
  GymProgressSeries._(_SeriesBuilder builder)
    : key = builder.key,
      title = builder.title,
      context = builder.context,
      records = List.unmodifiable(builder.records) {
    for (final metric in switch (key.kind) {
      WorkoutExerciseKind.strength => const [
        GymProgressMetric.heaviestSet,
        GymProgressMetric.mostReps,
      ],
      WorkoutExerciseKind.cardio => const [
        GymProgressMetric.distance,
        GymProgressMetric.duration,
      ],
      null => const [GymProgressMetric.bodyWeight],
    }) {
      final trend = GymProgressTrend._(records, metric);
      if (trend.valueCount > 0) _trends[metric] = trend;
    }
  }

  final GymProgressKey key;
  final String title;
  final String? context;
  final List<GymProgressRecord> records;
  final _trends = <GymProgressMetric, GymProgressTrend>{};

  Iterable<GymProgressMetric> get metrics => _trends.keys;
  GymProgressTrend trendFor(GymProgressMetric metric) => _trends[metric]!;
}

class GymProgressHistory {
  GymProgressHistory({
    required List<GymSession> sessions,
    List<BodyMeasurement> bodyMeasurements = const [],
  }) : sessions = List.unmodifiable(
         sessions.where((session) => session.finished).toList()..sort(
           (first, second) => second.startedAt.compareTo(first.startedAt),
         ),
       ) {
    final builders = <GymProgressKey, _SeriesBuilder>{};
    for (final workout in this.sessions) {
      final nameCounts = <String, int>{};
      final planned = workout.planId != null || workout.planned;
      for (final exercise in workout.exercises) {
        final name = _normalize(exercise.name);
        nameCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
      }
      for (final (index, exercise) in workout.exercises.indexed) {
        final name = _normalize(exercise.name);
        final ambiguous = (nameCounts[name] ?? 0) > 1;
        final GymProgressKey key = (
          kind: exercise.kind,
          scope: planned ? 'plan' : (ambiguous ? 'individual' : 'freestyle'),
          owner: workout.planId ?? (planned ? workout.workoutTitle : ''),
          exercise: planned || ambiguous ? exercise.id : name,
        );
        final builder = builders.putIfAbsent(
          key,
          () => _SeriesBuilder(
            key: key,
            title: exercise.name,
            context: ambiguous
                ? '${workout.workoutTitle} · exercise ${index + 1}'
                : workout.workoutTitle,
          ),
        );
        builder.records.add(GymProgressRecord._exercise(workout, exercise));
      }
    }
    final weights =
        bodyMeasurements
            .where((value) => value.kind == MeasurementKind.bodyWeight)
            .toList()
          ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final exerciseSeries =
        builders.values
            .map(GymProgressSeries._)
            .where((series) => series.metrics.isNotEmpty)
            .toList()
          ..sort((a, b) {
            final latestA = a.trendFor(a.metrics.first).points.last.at;
            final latestB = b.trendFor(b.metrics.first).points.last.at;
            return latestB.compareTo(latestA);
          });
    series = List.unmodifiable([
      ...exerciseSeries,
      if (weights.isNotEmpty)
        GymProgressSeries._(
          _SeriesBuilder(
            key: (kind: null, scope: 'body', owner: '', exercise: ''),
            title: 'Body weight',
          )..records.addAll(weights.map(GymProgressRecord._weight)),
        ),
    ]);
  }

  final List<GymSession> sessions;
  late final List<GymProgressSeries> series;
}

class _SeriesBuilder {
  _SeriesBuilder({required this.key, required this.title, this.context});

  final GymProgressKey key;
  final String title;
  final String? context;
  final records = <GymProgressRecord>[];
}

final _whitespace = RegExp(r'\s+');
String _normalize(String name) =>
    name.trim().toLowerCase().replaceAll(_whitespace, ' ');
