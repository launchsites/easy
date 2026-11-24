import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:easy/workout_plans_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('schedules a one-off workout with two editable strength sets', (
    tester,
  ) async {
    List<WorkoutPlan> saved = [];
    await _showPlans(tester, onChanged: (plans) => saved = plans);
    await _tap(tester, 'New workout');
    await _enter(tester, 'Workout name', 'Upper body');
    await _tap(tester, 'Date');
    final now = DateTime.now();
    final day = now.day == 1 ? 2 : 1;
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('$day'),
      ),
    );
    await _tap(tester, 'OK');

    await _tap(tester, 'Add exercise');
    await _enter(tester, 'Exercise name', 'Bench press');
    await _enter(tester, 'Weight (kg)', '60');
    await _enter(tester, 'Reps', '6');
    await _tap(tester, 'Add set');
    await _enter(tester, 'Weight (kg)', '62.5', index: 1);
    await _enter(tester, 'Reps', '5', index: 1);
    await _tap(tester, 'Add set');
    await tester.ensureVisible(find.byTooltip('Remove set 3'));
    await tester.tap(find.byTooltip('Remove set 3'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Save exercise');
    await _tap(tester, 'Save workout');

    final plan = saved.single;
    expect(plan.name, 'Upper body');
    expect(plan.schedule.kind, WorkoutScheduleKind.once);
    expect(plan.schedule.startDate, DateTime(now.year, now.month, day));
    final sets = plan.exercises.single.sets;
    expect(sets.map((set) => set.weightKg), [60, 62.5]);
    expect(sets.map((set) => set.reps), [6, 5]);
    expect(tester.takeException(), isNull);

    await _tap(tester, 'Upper body');
    await _tap(tester, 'Bench press');
    await _tap(tester, 'Remove exercise');
    await _tap(tester, 'Save workout');
    expect(saved.single.exercises, isEmpty);
  });

  testWidgets('keeps selected weekdays and parses cardio values', (
    tester,
  ) async {
    List<WorkoutPlan> saved = [];
    await _showPlans(tester, onChanged: (plans) => saved = plans);
    await _tap(tester, 'New workout');
    await _enter(tester, 'Workout name', 'Morning cardio');
    await _tap(tester, 'Weekdays');
    final chipDay = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final today = DateTime.now().weekday;
    await _tap(tester, chipDay[today - 1]);
    await _tap(tester, 'Save workout');
    expect(find.text('Choose one or more weekdays.'), findsOneWidget);
    await _tap(tester, 'Mon');
    await _tap(tester, 'Thu');
    await _tap(tester, 'Add exercise');
    await _enter(tester, 'Exercise name', 'Treadmill');
    await _tap(tester, 'Cardio');
    await _enter(tester, 'Distance (km)', '2,5');
    await _enter(tester, 'Incline (%)', '4');
    await _enter(tester, 'Minutes', '20');
    await _tap(tester, 'Save exercise');
    await _tap(tester, 'Save workout');

    final plan = saved.single;
    expect(plan.schedule.kind, WorkoutScheduleKind.weekdays);
    expect(plan.schedule.weekdays, [DateTime.monday, DateTime.thursday]);
    final cardio = plan.exercises.single;
    expect(cardio.kind, WorkoutExerciseKind.cardio);
    expect(cardio.distanceKm, 2.5);
    expect(cardio.inclinePercent, 4);
    expect(cardio.minutes, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('validates the repeat interval and deletes a saved plan', (
    tester,
  ) async {
    List<WorkoutPlan> saved = [];
    await _showPlans(tester, onChanged: (plans) => saved = plans);
    await _tap(tester, 'New workout');
    await _enter(tester, 'Workout name', 'Intervals');
    await _tap(tester, 'Every N days');
    await _enter(tester, 'Repeat every (days)', '0');
    await _tap(tester, 'Save workout');
    expect(find.text('Use 1 or more.'), findsOneWidget);
    await _enter(tester, 'Repeat every (days)', '3');
    await _tap(tester, 'Save workout');

    expect(saved.single.schedule.kind, WorkoutScheduleKind.interval);
    expect(saved.single.schedule.intervalDays, 3);
    await _tap(tester, 'Intervals');
    await _tap(tester, 'Delete workout plan');
    await _tap(tester, 'Delete');
    expect(saved, isEmpty);
    expect(find.text('No workout plans yet.'), findsOneWidget);
  });

  testWidgets('direct editing preserves the draft until confirmed or saved', (
    tester,
  ) async {
    final plan = WorkoutPlan(
      id: 'plan',
      name: 'Original workout',
      schedule: WorkoutSchedule(
        kind: WorkoutScheduleKind.once,
        startDate: DateTime(2026, 12, 1),
      ),
      exercises: const [],
    );
    List<WorkoutPlan>? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open workout'),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => WorkoutPlansPage(
                    plans: [plan],
                    initialPlan: plan,
                    onChanged: (plans) => saved = plans,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, 'Open workout');
    await _enter(tester, 'Workout name', 'Updated workout');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await _tap(tester, 'Cancel');
    expect(saved, isNull);
    await _tap(tester, 'Save workout');
    expect(saved?.single.name, 'Updated workout');
    expect(saved?.single.id, 'plan');
    expect(find.text('Open workout'), findsOneWidget);
  });
}

Future<void> _showPlans(
  WidgetTester tester, {
  required ValueChanged<List<WorkoutPlan>> onChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: WorkoutPlansPage(plans: const [], onChanged: onChanged),
    ),
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _enter(
  WidgetTester tester,
  String label,
  String value, {
  int index = 0,
}) async {
  final field = find.widgetWithText(TextFormField, label).at(index);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}
