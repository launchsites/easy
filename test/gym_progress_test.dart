import 'dart:convert';

import 'package:easy/gym_history_page.dart';
import 'package:easy/gym_progress.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/health/health_models.dart';
import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'chart only uses confirmed actuals and splits explicitly missing work',
    () {
      final sessions = [
        _bench(24, 92, progress: GymProgress.done, finished: false),
        _bench(23, 80, progress: GymProgress.pending),
        _bench(22, 61, progress: GymProgress.done, reps: 6),
        _bench(21, 140, progress: GymProgress.skipped),
        _bench(18, 53, progress: GymProgress.done, reps: 9),
        _bench(15, 48, progress: GymProgress.done, reps: 7),
        _bench(12, 99, progress: GymProgress.pending),
      ];
      final history = GymProgressHistory(sessions: sessions);
      expect(history.sessions, hasLength(6));
      final bench = history.series.single;
      final trend = bench.trendFor(GymProgressMetric.heaviestSet);
      expect(trend.points.map((point) => point.at.day), [15, 18, 22]);
      expect(trend.points.map((point) => point.value), [48, 53, 61]);
      expect(trend.points.map((point) => point.startsSegment), [
        true,
        false,
        true,
      ]);
      expect(trend.canChart, isTrue);
      expect(
        bench
            .trendFor(GymProgressMetric.mostReps)
            .points
            .map((point) => point.value),
        [7, 9, 6],
      );
      expect(bench.records.map((row) => row.at.day), [23, 22, 21, 18, 15, 12]);
      expect(bench.records[0].unconfirmed, 1);
      expect(bench.records[2].skipped, 1);
      expect(bench.records[1].confirmedSets.single.reps, 6);
      expect(sessions[2].plannedExercises!.single.sets.single.weightKg, 180);
    },
  );

  test('stable plan IDs survive renames, and duplicate freestyle names stay separate', () {
    final history = GymProgressHistory(
      sessions: [
        _bench(23, 70, plan: 'alternate'),
        _bench(22, 55, name: 'Paused bench press'),
        _bench(21, 50),
        _bench(20, 30, plan: null, name: ' BENCH    press ', id: 'fresh-1'),
        _bench(19, 25, plan: null, id: 'fresh-2'),
        _finished(
          17,
          plan: null,
          exercises: [_strength('one', 40), _strength('two', 50)],
          progress: {
            jsonEncode(['one', 'one-set']): GymProgress.done,
            jsonEncode(['two', 'two-set']): GymProgress.done,
          },
        ),
      ],
    );
    expect(history.series, hasLength(5));
    expect(history.series[0].key.owner, 'alternate');
    expect(
      history.series[0].trendFor(GymProgressMetric.heaviestSet).canChart,
      isFalse,
    );
    expect(history.series[1].title, 'Paused bench press');
    expect(history.series[1].records, hasLength(2));
    expect(history.series[2].records, hasLength(2));
    expect(
      history.series
          .skip(3)
          .map((series) => series.records.single.confirmedSets.single.weightKg)
          .toSet(),
      {40, 50},
    );
  });

  test('body weight converts logged measurements and keeps same-day readings distinct', () {
    final poundReading = _measurement(20, 160, MeasurementUnit.pounds);
    final metricReading = _measurement(
      20,
      72,
      MeasurementUnit.kilograms,
      hour: 18,
    );
    final waist = BodyMeasurement(
      id: 'waist',
      kind: MeasurementKind.waist,
      unit: MeasurementUnit.inches,
      value: 30,
      recordedAt: DateTime.utc(2026, 11, 20),
    );
    final history = GymProgressHistory(
      sessions: [],
      bodyMeasurements: [metricReading, waist, poundReading],
    );
    final body = history.series.single;
    expect(body.records.map((record) => record.measurement), [
      metricReading,
      poundReading,
    ]);
    final trend = body.trendFor(GymProgressMetric.bodyWeight);
    expect(trend.canChart, isTrue);
    expect(trend.points.first.value, closeTo(72.5747792, 0.0000001));
    expect(trend.points.last.value, 72);
  });

  test(
    'cardio zeros remain explicit and unsaved data does not surface a series',
    () {
      final treadmill = WorkoutExercise(
        id: 'treadmill',
        name: 'Treadmill',
        kind: WorkoutExerciseKind.cardio,
        minutes: 5,
        inclinePercent: -1,
      );
      final workouts = [
        _finished(
          20,
          exercises: [treadmill],
          progress: {
            jsonEncode(['treadmill']): GymProgress.done,
          },
        ),
        _finished(
          21,
          exercises: [treadmill.copyWith(distanceKm: 1)],
          progress: {},
        ),
        _bench(22, 72, progress: GymProgress.pending),
      ];
      final series = GymProgressHistory(sessions: workouts).series.single;
      expect(series.records.first.confirmedCardio, isNull);
      expect(series.records.last.confirmedCardio!.inclinePercent, -1);
      expect(
        series.trendFor(GymProgressMetric.distance).points.single.value,
        0,
      );
      expect(
        series.trendFor(GymProgressMetric.duration).points.single.value,
        5,
      );
      expect(series.trendFor(GymProgressMetric.duration).canChart, isFalse);
    },
  );

  test(
    'chart work is bounded while older and missing records remain available',
    () {
      const count = 12000;
      final start = DateTime.utc(2000);
      final metrics = [
        for (var i = 0; i < count; i++)
          BodyMeasurement(
            id: 'logged-$i',
            kind: MeasurementKind.bodyWeight,
            unit: MeasurementUnit.kilograms,
            value: 70 + i % 10 * .05,
            recordedAt: start.add(Duration(days: i)),
          ),
      ];
      final series = GymProgressHistory(
        sessions: [],
        bodyMeasurements: metrics,
      ).series.single;
      final chart = series.trendFor(GymProgressMetric.bodyWeight);
      expect(series.records, hasLength(count));
      expect(chart.valueCount, count);
      expect(chart.points, hasLength(GymProgressTrend.maxChartPoints));
      expect(series.records.last.measurement!.id, 'logged-0');
      expect(chart.points.last.at, metrics.last.recordedAt);
    },
  );

  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('progress reads and navigates at $size, 200% text and RTL', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final opened = <GymSession>[];
      final older = _bench(10, 50, reps: 8);
      final latest = _bench(22, 60, reps: 6);
      await tester.pumpWidget(
        _history(
          [
            older,
            _bench(15, 89, progress: GymProgress.skipped),
            latest,
            _bench(12, 400, progress: GymProgress.pending),
          ],
          measurements: [_measurement(20, 159, MeasurementUnit.pounds)],
          onOpen: opened.add,
          large: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Progress'));
      await tester.pumpAndSettle();
      expect(find.text('Bench press'), findsOneWidget);
      final scroll = find.byType(Scrollable).first;
      final chart = find.byKey(const ValueKey('gym-trend-chart'));
      await tester.scrollUntilVisible(chart, 90, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp('Heaviest set chart')),
        findsOneWidget,
      );
      expect(find.text('Latest 60 kg'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('60 kg × 6'),
        110,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 kg × 6'));
      expect(opened, [latest]);
      await tester.scrollUntilVisible(
        find.text('Skipped'),
        100,
        scrollable: scroll,
      );
      await tester.scrollUntilVisible(
        find.text('Unconfirmed'),
        80,
        scrollable: scroll,
      );
      expect(find.textContaining('400'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Bench press'),
        -100,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bench press'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Body weight'));
      await tester.pumpAndSettle();
      expect(chart, findsNothing);
      expect(find.text('72.12 kg'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets(
    'empty or one-record histories skip redundant screens and charts',
    (tester) async {
      await tester.pumpWidget(
        _history([_bench(19, 30, progress: GymProgress.skipped)]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Progress'), findsNothing);
      expect(find.text('Upper body'), findsOneWidget);

      await tester.pumpWidget(
        _history(
          [],
          measurements: [_measurement(20, 80, MeasurementUnit.kilograms)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sessions'), findsNothing);
      expect(find.text('Body weight'), findsOneWidget);
      expect(find.text('80 kg'), findsOneWidget);
      expect(find.byKey(const ValueKey('gym-trend-chart')), findsNothing);
    },
  );

  testWidgets('large history projection returns results from the isolate', (
    tester,
  ) async {
    final samples = [
      for (var i = 0; i < 270; i++)
        BodyMeasurement(
          id: 'sample-$i',
          kind: MeasurementKind.bodyWeight,
          unit: MeasurementUnit.kilograms,
          value: 80 + i * .01,
          recordedAt: DateTime.utc(2026, 1, i + 1),
        ),
    ];
    await tester.runAsync(() async {
      await tester.pumpWidget(_history([_bench(1, 59)], measurements: samples));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('Progress').evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      expect(find.text('Progress'), findsOneWidget);
    });
    await tester.tap(find.text('Progress'));
    await tester.pumpAndSettle();
    expect(find.text('Bench press'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _history(
  List<GymSession> sessions, {
  List<BodyMeasurement> measurements = const [],
  ValueChanged<GymSession>? onOpen,
  bool large = false,
}) => MaterialApp(
  theme: easyTheme(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
      child: Directionality(
        textDirection: large ? TextDirection.rtl : TextDirection.ltr,
        child: GymHistoryPage(
          sessions: sessions,
          bodyMeasurements: measurements,
          onOpen: onOpen ?? (_) {},
        ),
      ),
    ),
  ),
);

GymSession _bench(
  int day,
  double kg, {
  int reps = 8,
  String id = 'bench',
  String? plan = 'upper',
  String name = 'Bench press',
  GymProgress progress = GymProgress.done,
  bool finished = true,
}) => _finished(
  day,
  plan: plan,
  exercises: [_strength(id, kg, reps: reps, name: name)],
  progress: {
    jsonEncode([id, '$id-set']): progress,
  },
  finished: finished,
);

WorkoutExercise _strength(
  String id,
  double kg, {
  String name = 'Bench press',
  int reps = 8,
}) => WorkoutExercise(
  id: id,
  name: name,
  kind: WorkoutExerciseKind.strength,
  sets: [WorkoutSet(id: '$id-set', weightKg: kg, reps: reps)],
);

GymSession _finished(
  int day, {
  required List<WorkoutExercise> exercises,
  required Map<String, GymProgress> progress,
  String? plan = 'upper',
  bool finished = true,
}) {
  final now = DateTime.utc(2026, 11, day, 10);
  final source =
      jsonDecode(GymSession.start(now: now).encode()) as Map<String, dynamic>;
  if (plan != null) {
    source['planned'] = true;
    source['planId'] = plan;
    source['planName'] = 'Upper body';
    source['plannedExercises'] = [_strength('bench', 180).toJson()];
  }
  source['exercises'] = exercises.map((exercise) => exercise.toJson()).toList();
  source['progress'] = progress.map((key, mark) => MapEntry(key, mark.name));
  if (finished) {
    source['finishedAt'] = now
        .add(const Duration(minutes: 30))
        .toIso8601String();
  }
  return GymSession.decode(jsonEncode(source));
}

BodyMeasurement _measurement(
  int day,
  double reading,
  MeasurementUnit unit, {
  int hour = 8,
}) => BodyMeasurement(
  id: '$day-$hour',
  kind: MeasurementKind.bodyWeight,
  unit: unit,
  value: reading,
  recordedAt: DateTime.utc(2026, 11, day, hour),
);
