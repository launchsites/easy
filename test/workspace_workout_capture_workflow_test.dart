import 'package:easy/capture/capture_review_sheet.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/main.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workout_plan.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final (explicitCompletion, inWorkout) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'Capture reviews literal sets with explicit completion $explicitCompletion and live screen $inWorkout',
      (tester) async {
        final previous = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final started = DateTime.now().subtract(const Duration(minutes: 10));
        final plan = WorkoutPlan(
          id: 'session-fixture',
          name: 'Upper body',
          schedule: WorkoutSchedule(
            kind: WorkoutScheduleKind.once,
            startDate: started,
          ),
          exercises: [
            WorkoutExercise(
              id: 'treadmill',
              name: 'Treadmill',
              kind: WorkoutExerciseKind.cardio,
              minutes: 5,
            ),
            WorkoutExercise(
              id: 'bench',
              name: 'Bench press',
              kind: WorkoutExerciseKind.strength,
              sets: [
                for (final id in ['first', 'second', 'third'])
                  WorkoutSet(id: id, weightKg: 50),
              ],
            ),
          ],
        );
        final prefs = SharedPreferencesAsync();
        await prefs.setStringList('easy.gym-sessions.v1', [
          GymSession.start(plan: plan, now: started).encode(),
        ]);

        const app = EasyApp(openStore: openPreferenceWorkspaceStore);
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mode'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(MenuItemButton, inWorkout ? 'Gym' : 'Work'),
        );
        await tester.pumpAndSettle();
        if (inWorkout) {
          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
          expect(find.byType(GymSessionPage), findsOneWidget);
          await tester.tap(find.byTooltip('Capture workout or task'));
        } else {
          await tester.tap(find.byTooltip('Add item'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Open capture review'));
        }
        await tester.pumpAndSettle();
        final sheet = find.byType(CaptureReviewSheet);
        expect(
          find.byTooltip('Record voice'),
          inWorkout ? findsOneWidget : findsNothing,
        );

        final bench =
            '${explicitCompletion ? 'I did ' : ''}bench press 60kg x8,8,6';
        await tester.enterText(
          find.descendant(of: sheet, matching: find.byType(TextField)),
          'Work: task: Write session handoff; After treadmill, I stretched; $bench',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Review'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: sheet, matching: find.text('Bench press')),
          findsOneWidget,
        );
        expect(find.textContaining('60 kg × 8, 8, 6'), findsOneWidget);
        expect(find.textContaining('After Treadmill'), findsOneWidget);
        final mark = find.widgetWithText(
          CheckboxListTile,
          'Mark these sets done',
        );
        if (explicitCompletion) {
          expect(tester.widget<CheckboxListTile>(mark).value, isFalse);
          await tester.ensureVisible(mark);
          await tester.tap(mark);
          await tester.pumpAndSettle();
        } else {
          expect(mark, findsNothing);
        }
        final add = find.widgetWithText(FilledButton, 'Add 3 items');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        if (inWorkout) {
          expect(find.byType(GymSessionPage), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Stretched'),
            220,
            scrollable: find
                .descendant(
                  of: find.byType(GymSessionPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('Stretched'), findsOneWidget);
        } else {
          expect(
            tester.widget<MobileHome>(find.byType(MobileHome)).mode,
            'work',
          );
        }

        final store = await openPreferenceWorkspaceStore(
          preferences: prefs,
          readLegacy: () async =>
              throw StateError('Expected the existing workspace'),
        );
        final saved = await store.read();
        expect(saved.revision, 3);
        final data = WorkspaceData.decode(saved.snapshot.workspaceJson);
        final session = GymSession.decode(saved.snapshot.gymSessionJson.single);
        expect(
          data.tasks
              .where((task) => task.title == 'Write session handoff')
              .single
              .category,
          'work',
        );
        expect(data.captures.single.applied, isTrue);
        expect(session.entries.first.afterExerciseId, 'treadmill');
        expect(
          session.entries.first.captureText,
          'After treadmill, I stretched',
        );
        expect(session.entries.last.captureText, bench);
        expect(session.exercises.last.sets.map((set) => set.reps), [8, 8, 6]);
        expect(session.exercises.last.sets.map((set) => set.weightKg), [
          60,
          60,
          60,
        ]);
        expect(session.plannedExercise('bench')!.sets.last.reps, 8);
        expect(session.progressFor('treadmill'), GymProgress.pending);
        expect(
          session.progressFor('bench', setId: 'third'),
          explicitCompletion ? GymProgress.done : GymProgress.pending,
        );
        await store.close();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
