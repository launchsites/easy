import 'package:easy/activities/activities.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'recorded task history offers an explicit local median estimate',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

      final today = dateOnly(DateTime.now());
      final start = plusDays(today, -2).add(const Duration(hours: 10));
      final end = start.add(const Duration(minutes: 34));
      const title = 'Review today’s drawings';
      final workspace = WorkspaceData(
        events: [],
        notes: [],
        tasks: [
          TaskItem(
            id: 'old-review',
            title: 'Review the mockups',
            category: 'work',
            done: true,
            completedAt: end,
          ),
          TaskItem(
            id: 'new-review',
            title: title,
            category: 'work',
            date: today,
          ),
        ],
        sections: {
          'activities': ActivityData(
            records: [
              ActivityRecord(
                id: 'linked',
                title: 'Review the mockups',
                category: 'work',
                target: const ActivityTarget(
                  id: 'old-review',
                  title: 'Review the mockups',
                  category: 'work',
                  kind: ActivityTargetKind.task,
                ),
              spans: [ActivitySpan(start: start, end: end)],
                finishedAt: end,
              ),
            ],
          ).toJson(),
        },
      );
      late WorkspaceStore store;
      await tester.pumpWidget(
        EasyApp(
          openStore: ({required preferences, required readLegacy}) async {
            return store = await openPreferenceWorkspaceStore(
              preferences: preferences,
              readLegacy: () async => WorkspaceSnapshot(
                workspaceJson: workspace.encode(),
                gymSessionJson: const [],
                workoutPlanJson: const [],
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final original = await store.read();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timing history'));
      for (
        var attempt = 0;
        attempt < 100 && find.text('Use median estimate').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('Same category'), findsOneWidget);
      expect(find.text('34 min median · 1 observed'), findsOneWidget);
      expect((await store.read()).revision, original.revision);
      await tester.tap(find.text('Use median estimate'));
      await tester.pumpAndSettle();
      final changed = WorkspaceData.decode(
        (await store.read()).snapshot.workspaceJson,
      );
      expect(changed.tasks.last.estimatedMinutes, 34);
      expect(changed.tasks.last.done, isFalse);
    },
  );
}
