import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:easy/workout_plans_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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

  testWidgets('adds exercise and set metrics without rounding stored weight', (
    tester,
  ) async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    List<WorkoutPlan> saved = [];
    await _showPlans(tester, onChanged: (plans) => saved = plans);
    await _tap(tester, 'New workout');
    await _enter(tester, 'Workout name', 'Strength work');
    await _tap(tester, 'Add exercise');
    await _enter(tester, 'Exercise name', 'Deadlift');
    await _enter(tester, 'Weight (kg)', '62.5123456');
    await tester.tap(find.byTooltip('Weight unit'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Pounds (lb)');
    expect(find.widgetWithText(TextFormField, 'Weight (lb)'), findsOneWidget);

    await _tap(tester, 'Add set metric');
    await _enter(tester, 'Label', 'Tempo');
    await _enter(tester, 'Unit (optional)', 's');
    await _enter(tester, 'Value', '2,5');
    await _tap(tester, 'Save metric');
    expect(find.text('Tempo · 2.5 s'), findsOneWidget);

    await _tap(tester, 'Add exercise metric');
    await _enter(tester, 'Label', 'Range');
    await _enter(tester, 'Unit (optional)', 'cm');
    await _enter(tester, 'Value', '24');
    await _tap(tester, 'Save metric');
    await _tap(tester, 'Save exercise');
    await _tap(tester, 'Save workout');

    final lift = saved.single.exercises.single;
    expect(lift.metrics.single.toJson(), containsPair('unit', 'cm'));
    expect(lift.metrics.single.value, 24);
    expect(lift.sets.single.metrics.single.value, 2.5);
    expect(lift.sets.single.weightKg, 62.5123456);
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

  testWidgets('desktop edits exercises in the shell beside their workout', (
    tester,
  ) async {
    List<WorkoutPlan>? saved;
    var closed = false;
    final page = GlobalKey<WorkoutPlansPageState>();
    await _showDesktopPlans(
      tester,
      page: page,
      onChanged: (plans) => saved = plans,
      onClose: () => closed = true,
    );

    await _tap(tester, 'Upper body');
    expect(find.text('Workspace navigation'), findsOneWidget);
    expect(find.text('Edit workout'), findsOneWidget);
    final name = find.widgetWithText(TextFormField, 'Workout name');
    final otherPlan = find.widgetWithText(ListTile, 'Recovery');
    expect(
      tester.getCenter(otherPlan).dx,
      greaterThan(tester.getCenter(name).dx),
    );
    await _enter(tester, 'Workout name', 'Upper body and cardio');
    await _tap(tester, 'Bench press');

    final exerciseName = find.widgetWithText(TextFormField, 'Exercise name');
    final otherExercise = find.widgetWithText(ListTile, 'Treadmill');
    expect(find.text('Workspace navigation'), findsOneWidget);
    expect(find.text('Upper body and cardio'), findsOneWidget);
    expect(
      tester.getCenter(otherExercise).dx,
      greaterThan(tester.getCenter(exerciseName).dx),
    );
    expect(Navigator.of(page.currentContext!).canPop(), isFalse);
    await _enter(tester, 'Exercise name', 'Paused bench');

    await tester.tap(otherExercise);
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await _tap(tester, 'Cancel');
    expect(find.text('Paused bench'), findsOneWidget);

    final leave = page.currentState!.confirmLeaving();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await _tap(tester, 'Cancel');
    expect(await leave, isFalse);
    await _tap(tester, 'Save exercise');
    expect(saved, isNull);
    expect(find.text('Upper body and cardio'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Paused bench'), findsOneWidget);
    await _tap(tester, 'Save workout');
    expect(saved?.first.exercises.first.name, 'Paused bench');
    expect(saved?.last.name, 'Recovery');

    await tester.tap(find.byTooltip('Back to workout'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow desktop keeps a readable back path and draft at 200%', (
    tester,
  ) async {
    final page = GlobalKey<WorkoutPlansPageState>();
    await _showDesktopPlans(
      tester,
      page: page,
      size: const Size(720, 568),
      textScaler: TextScaler.linear(2),
      direction: TextDirection.rtl,
      onChanged: (_) => fail('Back should not save the draft'),
      onClose: () {},
    );
    await _tap(tester, 'Upper body');
    await _enter(tester, 'Workout name', 'Keep this plan draft');
    await _tap(tester, 'Treadmill');
    await _enter(tester, 'Exercise name', 'Discard this exercise change');
    await tester.tap(find.byTooltip('Back to workout editor'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Discard');
    expect(find.text('Keep this plan draft'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Treadmill'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to workout plans'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Discard');
    expect(find.text('Upper body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _showDesktopPlans(
  WidgetTester tester, {
  required GlobalKey<WorkoutPlansPageState> page,
  required ValueChanged<List<WorkoutPlan>> onChanged,
  required VoidCallback onClose,
  Size size = const Size(1280, 780),
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final schedule = WorkoutSchedule(
    kind: WorkoutScheduleKind.once,
    startDate: DateTime(2026, 12, 1),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: Directionality(
            textDirection: direction,
            child: Row(
              children: [
                const SizedBox(width: 190, child: Text('Workspace navigation')),
                Expanded(
                  child: WorkoutPlansPage(
                    key: page,
                    plans: [
                      WorkoutPlan(
                        id: 'upper',
                        name: 'Upper body',
                        schedule: schedule,
                        exercises: [
                          WorkoutExercise(
                            id: 'bench',
                            name: 'Bench press',
                            kind: WorkoutExerciseKind.strength,
                          ),
                          WorkoutExercise(
                            id: 'run',
                            name: 'Treadmill',
                            kind: WorkoutExerciseKind.cardio,
                          ),
                        ],
                      ),
                      WorkoutPlan(
                        id: 'recovery',
                        name: 'Recovery',
                        schedule: schedule,
                        exercises: const [],
                      ),
                    ],
                    onChanged: onChanged,
                    onClose: onClose,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
