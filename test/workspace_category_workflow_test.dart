import 'package:easy/categories/workspace_categories.dart';
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
    'category aliases and descendants retain focus and rename in place',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1360, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

      final today = dateOnly(DateTime.now());
      final categories = WorkspaceCategories.defaults().withCategory(
        WorkspaceCategory(
          id: 'team-writing',
          label: 'Writing',
          parentId: 'work',
          aliases: const ['old-writing'],
          colorArgb: 0xff44734f,
        ),
      );
      final fixture = WorkspaceData(
        events: [],
        tasks: [
          TaskItem(
            id: 'report',
            title: 'Review paper',
            category: 'old-writing',
            date: today,
          ),
          TaskItem(
            id: 'other',
            title: 'Call family',
            category: 'personal',
            date: today,
          ),
        ],
        notes: [],
        sections: {'categories': categories.toJson()},
      );
      final app = EasyApp(
        openStore: ({required preferences, required readLegacy}) =>
            openPreferenceWorkspaceStore(
              preferences: preferences,
              readLegacy: () async => WorkspaceSnapshot(
                workspaceJson: fixture.encode(),
                gymSessionJson: const [],
                workoutPlanJson: const [],
              ),
            ),
      );
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work').first);
      await tester.pumpAndSettle();
      expect(find.text('Review paper'), findsOneWidget);
      expect(find.text('Call family'), findsNothing);
      expect(find.text('Writing'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Categories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Writing'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Writing studio',
      );
      await tester.tap(find.text('Save category'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Review paper'), findsOneWidget);
      expect(find.text('Writing studio'), findsOneWidget);
    },
  );
}
