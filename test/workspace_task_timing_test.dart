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
  const title = 'Review today’s drawings';
  for (final (description, priorTitle, daysAgo, canUse) in [
    ('recent exact work', title, [2, 3, 4], true),
    ('category-only work', 'Review the mockups', [2, 3, 4], false),
    ('an isolated exact observation', title, [2], false),
    ('older exact work', title, [93, 94, 95], false),
  ]) {
    testWidgets('timing history shows $description with a grounded action', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

      final today = dateOnly(DateTime.now());
      final history = <TaskItem>[];
      final records = <ActivityRecord>[];
      for (final (index, days) in daysAgo.indexed) {
        final start = plusDays(today, -days).add(const Duration(hours: 10));
        final end = start.add(Duration(minutes: 30 + 4 * index));
        final prior = TaskItem(
          id: 'old-review-$index',
          title: priorTitle,
          category: 'work',
          done: true,
          completedAt: end,
        );
        history.add(prior);
        records.add(
          ActivityRecord(
            id: 'linked-$index',
            title: prior.title,
            category: prior.category,
            target: ActivityTarget(
              id: prior.id,
              title: prior.title,
              category: prior.category,
              kind: ActivityTargetKind.task,
            ),
            spans: [ActivitySpan(start: start, end: end)],
            finishedAt: end,
          ),
        );
      }
      final workspace = WorkspaceData(
        events: [],
        notes: [],
        tasks: [
          ...history,
          TaskItem(
            id: 'new-review',
            title: title,
            category: 'work',
            date: today,
          ),
        ],
        sections: {'activities': ActivityData(records: records).toJson()},
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
      final expectedMedian = daysAgo.length == 1 ? 30 : 34;
      final observation = find.text(
        '$expectedMedian min median · ${daysAgo.length} observed',
      );
      for (
        var attempt = 0;
        attempt < 100 && observation.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(observation, findsOneWidget);
      expect(
        find.text(
          priorTitle == title
              ? 'Same task title and category'
              : 'Same category',
        ),
        findsOneWidget,
      );
      expect((await store.read()).revision, original.revision);
      final useEstimate = find.text('Use median estimate');
      if (canUse) {
        await tester.tap(useEstimate);
      } else {
        expect(useEstimate, findsNothing);
        await tester.tap(find.text('Close'));
      }
      await tester.pumpAndSettle();
      final saved = await store.read();
      final changed = WorkspaceData.decode(saved.snapshot.workspaceJson);
      expect(saved.revision, original.revision + (canUse ? 1 : 0));
      expect(
        changed.tasks.last.estimatedMinutes,
        canUse ? expectedMedian : null,
      );
      expect(changed.tasks.last.done, isFalse);
    });
  }
}
