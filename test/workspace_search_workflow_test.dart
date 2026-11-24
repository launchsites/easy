import 'package:easy/activities/activities.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/preferences/feature_preferences.dart';
import 'package:easy/search/search.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'search uses full notes across focus and excludes disabled activity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);
      final now = DateTime(2026, 11, 24, 10);
      final notes = [
        NoteItem(
          id: 'lapidary',
          title: 'Workshop materials',
          body: 'Order the quartz sample.',
          updated: now,
          category: 'personal',
        ),
      ];
      final fixture = WorkspaceData(
        events: [],
        tasks: [],
        notes: notes,
        sections: {
          'features': FeaturePreferences.preset(EasyPreset.minimal).toJson(),
          'activities': ActivityData(
            records: [
              ActivityRecord(
                id: 'hidden',
                title: 'Private shift',
                category: 'work',
                plan: ActivityWindow(now, now.add(const Duration(hours: 1))),
              ),
            ],
          ).toJson(),
        },
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

      Future<void> open() async {
        await tester.tap(find.text('Search workspace').first);
        await tester.pumpAndSettle();
      }

      Future<void> query(String needle) async {
        await tester.enterText(find.byType(TextField), needle);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      await open();
      await query('Private shift');
      expect(find.text('No matching records.'), findsOneWidget);
      await query('body:quartz');
      expect(find.text('Workshop materials'), findsOneWidget);
      await tester.tap(find.byTooltip('Add to favourites'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workshop materials'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceSearchDialog), findsNothing);
      expect(find.text('Workshop materials'), findsOneWidget);
      await open();
      expect(find.text('Workshop materials'), findsWidgets);
      expect(find.byTooltip('Remove from favourites'), findsWidgets);
    },
  );
}
