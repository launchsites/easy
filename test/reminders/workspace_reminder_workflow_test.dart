import 'package:easy/calendar_page.dart';
import 'package:easy/main.dart';
import 'package:easy/reminders/local_reminder_backend.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'local_reminder_test.dart' show MemoryReminderBackend;

void main() {
  testWidgets(
    'a relative event alert is saved before device opt-in and removed',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      FlutterSecureStorage.setMockInitialValues({});
      final now = DateTime.now();
      final start = dateOnly(plusDays(now, 1)).add(const Duration(hours: 14));
      const title = 'Private appointment';
      final stored = WorkspaceData(
        events: [
          CalendarEvent(
            id: 'appt',
            title: title,
            category: 'personal',
            start: start,
            end: start.add(const Duration(hours: 1)),
          ),
        ],
        tasks: [],
        notes: [],
      );
      final backend = MemoryReminderBackend()
        ..capabilities = const LocalReminderCapabilities(
          permission: LocalReminderPermission.notDetermined,
          exactScheduling: true,
        );
      await tester.pumpWidget(
        EasyApp(
          reminderBackend: backend,
          openStore: ({required preferences, required readLegacy}) =>
              openPreferenceWorkspaceStore(
                preferences: preferences,
                readLegacy: () async => WorkspaceSnapshot(
                  workspaceJson: stored.encode(),
                  gymSessionJson: const [],
                  workoutPlanJson: const [],
                ),
              ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search workspace'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), title);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Before the start'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '25');
      await tester.tap(find.text('Save reminder'));
      await tester.pumpAndSettle();
      expect(find.text('Edit reminder'), findsOneWidget);
      expect(backend.permissionPrompts, 0);
      expect(backend.requests, isEmpty);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reminders'));
      await tester.tap(find.text('Reminders'));
      await tester.pumpAndSettle();
      expect(backend.permissionPrompts, 0);
      await tester.tap(find.text('Allow notifications'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deliver reminders'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.requests.values.single.title, 'Easy');
      expect(
        backend.requests.values.single.at,
        start.subtract(const Duration(minutes: 25)).toUtc(),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove reminder'));
      await tester.pumpAndSettle();
      expect(backend.requests, isEmpty);
      expect(backend.permissionPrompts, 1);
    },
  );
}
