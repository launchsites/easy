import 'dart:convert';

import 'package:easy/gym_mode_ui.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('Planned work, adjusted actuals, and extras stay chronological', (
    tester,
  ) async {
    _phoneViewport(tester);
    GymSession? snapshot;
    await tester.pumpWidget(
      MaterialApp(
        home: GymSessionPage(
          session: null,
          onChanged: (session) => snapshot = session,
        ),
      ),
    );
    await tester.tap(find.text('Planned session'));
    await tester.pumpAndSettle();
    expect(find.text('0.5 km · 5 min · 2% incline'), findsOneWidget);
    expect(find.text('50 kg × 8, 8, 8'), findsOneWidget);

    await tester.tap(find.text('Log as planned').first);
    await tester.pumpAndSettle();
    expect(snapshot!.entries.single.actual, '0.5 km · 5 min · 2% incline');
    expect(find.byTooltip('Enter actual for Treadmill'), findsNothing);

    await _typeAndLog(tester, 'Stretch');
    final bench = find.byTooltip('Enter actual for Bench press');
    await tester.ensureVisible(bench);
    await tester.tap(bench);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 245);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _typeAndLog(tester, '55 kg × 8, 8, 6');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();

    expect(snapshot!.entries.map((entry) => entry.title), [
      'Treadmill',
      'Stretch',
      'Bench press',
    ]);
    expect(find.text('Plan'), findsNothing);
    expect(snapshot!.entries.last.actual, '55 kg × 8, 8, 6');
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(snapshot!.finished, true);
    final restored = GymSession.decode(snapshot!.encode());
    expect(restored.finished, true);
    expect(restored.startedAt, snapshot!.startedAt);
    expect(restored.entries.last.actual, '55 kg × 8, 8, 6');
    expect(find.text('Session complete'), findsOneWidget);
  });

  testWidgets('A saved freestyle session resumes with its existing results', (
    tester,
  ) async {
    _phoneViewport(tester);
    GymSession? snapshot;
    Widget workspace(GymSession? session) => MaterialApp(
      home: GymSessionPage(
        session: session,
        onChanged: (updated) => snapshot = updated,
      ),
    );
    await tester.pumpWidget(workspace(null));
    await tester.tap(find.text('Freestyle'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsNothing);
    await _typeAndLog(tester, 'Stretch');
    final restored = GymSession.decode(snapshot!.encode());

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(workspace(restored));
    await tester.pumpAndSettle();
    expect(find.text('Stretch'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    await _typeAndLog(tester, 'Walk 10 minutes');
    expect(snapshot!.startedAt, restored.startedAt);
    expect(snapshot!.entries.map((entry) => entry.title), [
      'Stretch',
      'Walk 10 minutes',
    ]);
  });

  testWidgets(
    'Structured actuals and completion persist separately from the plan',
    (tester) async {
      _phoneViewport(tester);
      final plan = _plan();
      var snapshot = GymSession.start(plan: plan);
      await tester.pumpWidget(
        MaterialApp(
          home: GymSessionPage(
            session: snapshot,
            onChanged: (updated) => snapshot = updated!,
          ),
        ),
      );
      expect(snapshot.planId, 'early');
      expect(snapshot.workoutTitle, 'Early workout');
      expect(snapshot.upcomingExercises, ['Treadmill', 'Bench press']);

      await _tapTooltip(tester, 'Edit distance for Treadmill');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Save value'), findsOneWidget);
      await _typeAndLog(tester, '0.6');
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _tapTooltip(tester, 'Mark Treadmill done');
      expect(snapshot.upcomingExercises, ['Bench press']);
      expect(snapshot.exercises.first.distanceKm, .6);
      expect(plan.exercises.first.distanceKm, .5);
      expect(find.text('Planned · 0.5 km'), findsOneWidget);

      await _tapTooltip(tester, 'Edit reps for Bench press, set 1');
      await _typeAndLog(tester, '6');
      await _tapTooltip(tester, 'Mark Bench press set 1 done');
      final skipped = snapshot.withSkippedExercises(['bench', 'missing']);
      expect(skipped.progressFor('bench', setId: 'first'), GymProgress.done);
      expect(
        skipped.progressFor('bench', setId: 'second'),
        GymProgress.skipped,
      );
      expect(skipped.progressFor('cardio'), GymProgress.done);
      expect(
        snapshot.progressFor('bench', setId: 'second'),
        GymProgress.pending,
      );
      await _tapTooltip(tester, 'Skip Bench press set 2');
      expect(snapshot.upcomingExercises, isEmpty);
      expect(plan.exercises.last.sets.first.reps, 8);
      expect(snapshot.exercises.last.sets.first.reps, 6);

      final addSet = find.text('Add set');
      await tester.ensureVisible(addSet);
      await tester.tap(addSet);
      await tester.pumpAndSettle();
      expect(snapshot.exercises.last.sets, hasLength(3));
      expect(snapshot.upcomingExercises, ['Bench press']);
      await _tapTooltip(tester, 'Set 3 options for Bench press');
      await tester.tap(find.text('Remove set'));
      await tester.pumpAndSettle();
      expect(snapshot.exercises.last.sets, hasLength(2));
      expect(snapshot.upcomingExercises, isEmpty);

      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      final restored = GymSession.decode(snapshot.encode());
      expect(restored.finished, true);
      expect(restored.exercises.last.sets.first.reps, 6);
      expect(restored.plannedExercise('cardio')?.distanceKm, .5);
      expect(restored.plannedExercise('bench')?.sets.first.reps, 8);
      expect(restored.progressFor('cardio'), GymProgress.done);
      expect(restored.progressFor('bench', setId: 'first'), GymProgress.done);
      expect(
        restored.progressFor('bench', setId: 'second'),
        GymProgress.skipped,
      );
    },
  );

  test('original plan is explicit and old sessions keep it unknown', () {
    final planned = GymSession.start(plan: _plan());
    final source = jsonDecode(planned.encode()) as Map<String, dynamic>;
    expect(source['plannedExercises'], isA<List<dynamic>>());
    expect(planned.plannedExercises, hasLength(2));
    expect(() => planned.plannedExercises!.clear(), throwsUnsupportedError);
    source.remove('plannedExercises');
    final older = GymSession.decode(jsonEncode(source));
    expect(older.planned, isTrue);
    expect(older.plannedExercise('bench'), isNull);
    expect(older.exercises.last.name, 'Bench press');
    expect(GymSession.start().plannedExercises, isNull);
  });

  testWidgets('large text steps edit without opening a keyboard in RTL', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final plan = _plan();
    var snapshot = GymSession.start(plan: plan);
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: child!,
          ),
        ),
        home: MobileModeFrame(
          mode: 'gym',
          child: GymSessionPage(
            session: snapshot,
            onChanged: (updated) => snapshot = updated!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final edit = find.byTooltip('Edit reps for Bench press, set 1');
    await tester.drag(find.byType(ListView), const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    final decrease = find.byTooltip('Decrease reps');
    expect(tester.getSize(decrease).width, greaterThanOrEqualTo(44));
    await tester.tap(decrease);
    await tester.tap(decrease);
    await tester.tap(find.byTooltip('Save value'));
    await tester.pumpAndSettle();
    expect(snapshot.exercises.last.sets.first.reps, 6);

    await _tapTooltip(tester, 'Mark Bench press set 1 done');
    await _tapTooltip(tester, 'Set 1 options for Bench press');
    await tester.tap(find.text('Move set down'));
    await tester.pumpAndSettle();
    expect(snapshot.exercises.last.sets.map((set) => set.id), [
      'second',
      'first',
    ]);
    expect(snapshot.progressFor('bench', setId: 'first'), GymProgress.done);
    expect(snapshot.plannedExercise('bench')?.sets.map((set) => set.id), [
      'first',
      'second',
    ]);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(568, 320);
    await tester.pumpAndSettle();
    await _tapTooltip(tester, 'Edit weight for Bench press, set 1');
    expect(find.byTooltip('Save value').hitTestable(), findsOneWidget);
    await _tapTooltip(tester, 'Cancel edit');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Escape closes a desktop metric editor and restores the note draft',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(920, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var snapshot = GymSession.start(plan: _plan());
      await tester.pumpWidget(
        MaterialApp(
          home: GymSessionPage(
            session: snapshot,
            onChanged: (updated) => snapshot = updated!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Light warm-up');
      await _tapTooltip(tester, 'Edit distance for Treadmill');
      await tester.enterText(find.byType(TextField), '0.7');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Light warm-up'), findsOneWidget);
      expect(find.byTooltip('Save value'), findsNothing);
      expect(snapshot.exercises.first.distanceKm, .5);
      await _tapTooltip(tester, 'Log entry');
      expect(snapshot.entries.single.title, 'Light warm-up');
    },
  );

  testWidgets(
    'live metrics use the bottom input and pounds preserve canonical kg',
    (tester) async {
      _phoneViewport(tester);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      final base = _plan();
      final bench = base.exercises.last;
      final plan = base.copyWith(
        exercises: [
          bench.copyWith(
            sets: [
              bench.sets.first.copyWith(
                metrics: [
                  WorkoutMetric(
                    id: 'tempo',
                    label: 'Tempo',
                    unit: 's',
                    value: 2,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      var snapshot = GymSession.start(plan: plan);
      Widget screen() => MaterialApp(
        home: GymSessionPage(
          session: snapshot,
          onChanged: (updated) => snapshot = updated!,
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await _tapTooltip(tester, 'Weight unit');
      await tester.tap(find.text('Pounds (lb)'));
      await tester.pumpAndSettle();
      expect(find.text('110.23 lb'), findsOneWidget);
      await _tapTooltip(tester, 'Edit weight for Bench press, set 1');
      await _tapTooltip(tester, 'Save value');
      expect(snapshot.exercises.single.sets.single.weightKg, 50);
      await _tapTooltip(tester, 'Edit weight for Bench press, set 1');
      await _typeAndLog(tester, '135');
      expect(
        snapshot.exercises.single.sets.single.weightKg,
        closeTo(61.23497, .00001),
      );

      await _tapTooltip(tester, 'Edit Tempo for Bench press, set 1');
      await _typeAndLog(tester, '1000001');
      expect(
        find.text('Enter a number from −1,000,000 to 1,000,000.'),
        findsOneWidget,
      );
      await _typeAndLog(tester, '3.5');
      expect(find.text('Tempo · 3.5 s'), findsOneWidget);

      await _tapTooltip(tester, 'Set 1 options for Bench press');
      await tester.tap(find.text('Add metric'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final fields = find.descendant(
        of: dialog,
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'RPE');
      await tester.enterText(fields.at(2), '8');
      await tester.tap(find.text('Save metric'));
      await tester.pumpAndSettle();
      final set = snapshot.exercises.single.sets.single;
      expect(set.metrics.map((item) => item.value), [3.5, 8]);
      expect(plan.exercises.single.sets.single.metrics.single.value, 2);
      expect(plan.exercises.single.sets.single.weightKg, 50);

      snapshot = GymSession.decode(snapshot.encode());
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('135 lb'), findsOneWidget);
      expect(find.text('RPE · 8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A freestyle exercise can be added and removed during a session',
    (tester) async {
      _phoneViewport(tester);
      var snapshot = GymSession.start();
      await tester.pumpWidget(
        MaterialApp(
          home: GymSessionPage(
            session: snapshot,
            onChanged: (updated) => snapshot = updated!,
          ),
        ),
      );
      await tester.tap(find.text('Add exercise'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Cardio'));
      await tester.enterText(find.byType(TextFormField), 'Cycle');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(snapshot.exercises.single.name, 'Cycle');
      expect(snapshot.exercises.single.kind, WorkoutExerciseKind.cardio);

      await _tapTooltip(tester, 'Mark Cycle done');
      await _tapTooltip(tester, 'Options for Cycle');
      await tester.tap(find.text('Remove exercise'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Cycle?'), findsOneWidget);
      expect(snapshot.exercises, hasLength(1));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(snapshot.exercises, isEmpty);
    },
  );
}

WorkoutPlan _plan() => WorkoutPlan(
  id: 'early',
  name: 'Early workout',
  schedule: WorkoutSchedule(
    kind: WorkoutScheduleKind.once,
    startDate: DateTime(2026, 11, 24),
  ),
  exercises: [
    WorkoutExercise(
      id: 'cardio',
      name: 'Treadmill',
      kind: WorkoutExerciseKind.cardio,
      distanceKm: .5,
      inclinePercent: 2,
      minutes: 5,
    ),
    WorkoutExercise(
      id: 'bench',
      name: 'Bench press',
      kind: WorkoutExerciseKind.strength,
      sets: [
        WorkoutSet(id: 'first', weightKg: 50),
        WorkoutSet(id: 'second', weightKg: 50),
      ],
    ),
  ],
);

Future<void> _tapTooltip(WidgetTester tester, String message) async {
  final button = find.byTooltip(message);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button.hitTestable());
  await tester.pumpAndSettle();
}

void _phoneViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _typeAndLog(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}
