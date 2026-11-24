import 'package:easy/calendar_page.dart';
import 'package:easy/main.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'Calendar offers a Focus only after opt-in and an explicit switch',
    (tester) async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final now = DateTime.now();
      final event = CalendarEvent(
        id: 'active-work',
        title: 'Review the test brief',
        start: now.subtract(const Duration(minutes: 10)),
        end: now.add(const Duration(hours: 1)),
        category: 'work',
      );
      await SharedPreferencesAsync().setString(
        'easy.workspace.v1',
        WorkspaceData(events: [event], tasks: [], notes: []).encode(),
      );
      const app = EasyApp(openStore: openPreferenceWorkspaceStore);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(find.text('Switch to Work'), findsNothing);

      await tester.tap(find.text('Mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Calendar focus suggestions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      final home = find.byType(MobileHome);
      expect(tester.widget<MobileHome>(home).mode, isNull);
      await tester.tap(find.text('Switch to Work'));
      await tester.pumpAndSettle();
      expect(tester.widget<MobileHome>(home).mode, 'work');
      expect(find.text('Switch to Work'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(tester.widget<MobileHome>(home).mode, isNull);
      expect(find.text('Switch to Work'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
