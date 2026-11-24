import 'package:easy/gym_mode_ui.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _MeasuredExercise extends WorkoutExercise {
  _MeasuredExercise(int index, this._readNames)
    : super(
        id: 'station-$index',
        name: 'Station $index',
        kind: WorkoutExerciseKind.strength,
        sets: [
          for (var set = 0; set < 6; set++)
            WorkoutSet(id: 'set-$set', weightKg: 50),
        ],
      );

  final Set<String> _readNames;

  @override
  String get name {
    _readNames.add(id);
    return super.name;
  }
}

void main() {
  testWidgets(
    'dense workouts build nearby exercise cards and keep set identity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

      final readNames = <String>{};
      final plan = WorkoutPlan(
        id: 'dense-workout',
        name: 'Dense workout',
        schedule: WorkoutSchedule(
          kind: WorkoutScheduleKind.once,
          startDate: DateTime(2026, 11, 24),
        ),
        exercises: [
          for (var index = 0; index < 1200; index++)
            _MeasuredExercise(index, readNames),
        ],
      );
      var session = GymSession.start(plan: plan);
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
              session: session,
              onChanged: (next) => session = next!,
              buildCaptureControl: (_) => IconButton(
                tooltip: 'Capture workout entry',
                icon: const Icon(Icons.mic_none_rounded),
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Station 0'), findsOneWidget);
      expect(readNames, contains('station-0'));
      expect(readNames.length, lessThan(8));

      readNames.clear();
      await tester.tap(
        find.byTooltip('Mark Station 0 set 1 done').hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        session.progressFor('station-0', setId: 'set-0'),
        GymProgress.done,
      );
      expect(readNames.length, lessThan(8));

      await tester.tap(find.byTooltip('Options for Station 0').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move exercise down'));
      await tester.pumpAndSettle();
      expect(session.exercises.take(2).map((exercise) => exercise.id), [
        'station-1',
        'station-0',
      ]);
      expect(
        session.progressFor('station-1', setId: 'set-0'),
        GymProgress.pending,
      );
      expect(
        session.progressFor('station-0', setId: 'set-0'),
        GymProgress.done,
      );
      expect(session.plannedExercises!.first.id, 'station-0');

      tester.view.physicalSize = const Size(568, 320);
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Capture workout entry').hitTestable(),
        findsOneWidget,
      );
      final name = find.text('Station 0');
      await tester.scrollUntilVisible(
        name,
        400,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(name.hitTestable(), findsOneWidget);
      expect(readNames.length, lessThan(8));
      expect(readNames, isNot(contains('station-1199')));
      expect(tester.takeException(), isNull);
    },
  );
}
