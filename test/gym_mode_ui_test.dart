import 'package:easy/gym_mode_ui.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('mode frame follows the view and lets taps reach the page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late StateSetter update;
    String? mode;
    var taps = 0;
    const pageKey = ValueKey('page');
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MobileModeFrame(
              mode: mode,
              child: GestureDetector(
                key: pageKey,
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );

    final page = find.byKey(pageKey);
    final pageElement = tester.element(page);
    final frameStroke = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      return decoration is BoxDecoration &&
          decoration.border ==
              Border.all(color: const Color(0xffb24f43), width: 2);
    });
    expect(frameStroke, findsNothing);

    update(() => mode = 'gym');
    await tester.pump();
    expect(tester.element(page), same(pageElement));
    expect(tester.getRect(frameStroke), const Rect.fromLTWH(4, 4, 382, 836));
    await tester.tapAt(const Offset(5, 220));
    expect(taps, 1);

    tester.view.physicalSize = const Size(640, 360);
    await tester.pump();
    expect(tester.getRect(frameStroke), const Rect.fromLTWH(4, 4, 632, 352));

    tester.view.physicalSize = const Size(720, 360);
    await tester.pump();
    expect(frameStroke, findsNothing);
  });

  testWidgets('workout overview shows the plan and five exercises', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Scaffold(
          body: GymWorkoutOverview(
            workoutName: 'Strength A',
            scheduleLabel: 'Wed, Nov 25 · 5:30 PM',
            exercises: [
              for (var i = 1; i <= 6; i++)
                (name: 'Exercise $i', detail: '3 × 8'),
            ],
            active: false,
            canStart: true,
            onWorkout: () => actions.add('workout'),
            onPlans: () => actions.add('plans'),
            onFreestyle: () => actions.add('freestyle'),
          ),
        ),
      ),
    );

    expect(find.text('Strength A'), findsOneWidget);
    expect(find.text('Wed, Nov 25 · 5:30 PM'), findsOneWidget);
    expect(find.text('Exercise 5'), findsOneWidget);
    expect(find.text('Exercise 6'), findsNothing);

    await tester.tap(find.text('Start'));
    await tester.tap(find.text('Plans'));
    await tester.tap(find.text('Freestyle'));
    expect(actions, ['workout', 'plans', 'freestyle']);
  });

  testWidgets('empty plans and an active session offer different actions', (
    tester,
  ) async {
    var resumes = 0;
    Widget home(bool active) => MaterialApp(
      theme: easyTheme(),
      home: Scaffold(
        body: GymWorkoutOverview(
          workoutName: null,
          scheduleLabel: null,
          exercises: const [],
          active: active,
          canStart: false,
          onWorkout: () => resumes++,
          onPlans: () {},
          onFreestyle: () {},
        ),
      ),
    );

    await tester.pumpWidget(home(false));
    expect(find.text('No workouts planned.'), findsOneWidget);
    expect(find.text('Start'), findsNothing);
    expect(find.text('Plans'), findsOneWidget);
    expect(find.text('Freestyle'), findsOneWidget);

    await tester.pumpWidget(home(true));
    expect(find.text('Workout in progress'), findsOneWidget);
    expect(find.text('Freestyle'), findsNothing);
    await tester.tap(find.text('Resume'));
    expect(resumes, 1);
  });

  testWidgets('gym plan and actions remain reachable with narrow large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(1.8),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              GymWorkoutOverview(
                workoutName: 'Upper-body strength and conditioning',
                scheduleLabel: 'Thursday, November 26 · 5:30 PM',
                exercises: const [
                  (
                    name: 'Incline dumbbell bench press',
                    detail: '4 sets × 10 reps',
                  ),
                  (name: 'Cardiovascular cooldown', detail: '0.75 km · 6 min'),
                ],
                active: false,
                canStart: true,
                onWorkout: () => started = true,
                onPlans: () {},
                onFreestyle: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(start);
    expect(started, isTrue);
  });
}
