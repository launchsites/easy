import 'package:easy/gym_session.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

      await _tapTooltip(tester, 'Edit reps for Bench press, set 1');
      await _typeAndLog(tester, '6');
      await _tapTooltip(tester, 'Mark Bench press set 1 done');
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
      expect(restored.progressFor('cardio'), GymProgress.done);
      expect(restored.progressFor('bench', setId: 'first'), GymProgress.done);
      expect(
        restored.progressFor('bench', setId: 'second'),
        GymProgress.skipped,
      );
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
  await tester.tap(button);
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
