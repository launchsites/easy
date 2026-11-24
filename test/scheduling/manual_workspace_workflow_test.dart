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
    'adding and moving a block keeps one calendar ID and its baseline',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

      const title = 'Prepare studio checklist';
      final day = dateOnly(plusDays(DateTime.now(), 1));
      final workspace = WorkspaceData(
        events: [],
        notes: [],
        tasks: [
          TaskItem(
            id: 'studio',
            title: title,
            category: 'work',
            date: day,
            estimatedMinutes: 30,
          ),
        ],
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
      final initial = await store.read();

      Future<void> reviewTime() async {
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Review time'),
        );
        await tester.runAsync(
          () async => (button.onPressed! as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
      }

      Future<WorkspaceRevision> accept(String button, int previous) async {
        await tester.tap(find.widgetWithText(FilledButton, button));
        var durable = await store.read();
        for (
          var attempt = 0;
          attempt < 100 && durable.revision <= previous;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          durable = await store.read();
        }
        await tester.pumpAndSettle();
        expect(durable.revision, previous + 1);
        return durable;
      }

      await tester.tap(find.text('Tasks').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      await reviewTime();
      expect((await store.read()).revision, initial.revision);
      final first = await accept('Schedule block', initial.revision);
      final added = WorkspaceData.decode(first.snapshot.workspaceJson)
          .events
          .single;
      expect(added.plannedTaskId, 'studio');
      expect(added.end.difference(added.start), const Duration(minutes: 30));

      await tester.tap(find.text('Search workspace'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'type:event studio checklist',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move block'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Duration in minutes'),
        '15',
      );
      await tester.pumpAndSettle();
      await reviewTime();
      final moved = await accept('Save time', first.revision);
      final revised = WorkspaceData.decode(moved.snapshot.workspaceJson)
          .events
          .single;
      expect(revised.id, added.id);
      expect(revised.start, added.start);
      expect(
        revised.end.difference(revised.start),
        const Duration(minutes: 15),
      );
      expect(revised.initialPlannedEnd, added.initialPlannedEnd);
    },
  );
}
