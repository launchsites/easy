import 'package:easy/calendar_page.dart';
import 'package:easy/categories/workspace_categories.dart';
import 'package:easy/main.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'weekly acceptance writes an eligible reviewed block with its baseline',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

      final monday = weeklyPlanEnd(weeklyPlanStart(DateTime.now()));
      final busyStart = DateTime(monday.year, monday.month, monday.day, 9);
      final busyEnd = busyStart.add(const Duration(minutes: 30));
      final settings = SchedulingSettings(
        availability: [
          WeeklyAvailability(
            id: 'work',
            weekdays: [1],
            startMinute: 540,
            endMinute: 660,
            categories: ['work'],
          ),
        ],
      );
      final categories = WorkspaceCategories.defaults().withCategory(
        WorkspaceCategory(
          id: 'writing',
          label: 'Writing',
          parentId: 'work',
          aliases: ['legacy-writing'],
          colorArgb: 0xff44734f,
        ),
      );
      const title = 'Draft the client brief';
      final workspace = WorkspaceData(
        events: [
          CalendarEvent(
            id: 'busy',
            title: 'Fixed call',
            start: busyStart,
            end: busyEnd,
            category: 'work',
          ),
        ],
        tasks: [
          TaskItem(
            id: 'brief',
            title: title,
            category: 'legacy-writing',
            estimatedMinutes: 30,
          ),
        ],
        notes: [],
        sections: {
          'schedulingSettings': settings.toJson(),
          'categories': categories.toJson(),
        },
      );
      late WorkspaceStore store;
      await tester.pumpWidget(
        EasyApp(
          openStore: ({required preferences, required readLegacy}) async {
            store = await openPreferenceWorkspaceStore(
              preferences: preferences,
              readLegacy: () async => WorkspaceSnapshot(
                workspaceJson: workspace.encode(),
                gymSessionJson: const [],
                workoutPlanJson: const [],
              ),
            );
            return store;
          },
        ),
      );
      await tester.pumpAndSettle();
      final original = await store.read();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Plan week'));
      await tester.tap(find.text('Plan week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next week'));
      await tester.pumpAndSettle();
      final preview = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Preview week'),
      );
      await tester.runAsync(
        () async => (preview.onPressed! as Future<void> Function())(),
      );
      await tester.pumpAndSettle();
      expect((await store.read()).revision, original.revision);
      expect(find.widgetWithText(CheckboxListTile, title), findsOneWidget);

      final apply = find.widgetWithText(FilledButton, 'Add selected tasks');
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.tap(apply);
      var updated = original;
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        updated = await store.read();
        if (updated.revision > original.revision) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      final durable = WorkspaceData.decode(updated.snapshot.workspaceJson);
      final block = durable.events
          .where((event) => event.plannedTaskId == 'brief')
          .single;
      expect(block.start.toLocal(), busyEnd);
      expect(block.end.difference(block.start), const Duration(minutes: 30));
      expect(block.initialPlannedStart?.toLocal(), block.start.toLocal());
      expect(block.initialPlannedEnd?.toLocal(), block.end.toLocal());
      expect(durable.tasks.single.done, isFalse);
      expect(updated.revision, original.revision + 1);
    },
  );
}
