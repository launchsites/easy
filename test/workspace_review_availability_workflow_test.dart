import 'package:easy/calendar_page.dart';
import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/calendar_settings_page.dart';
import 'package:easy/main.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final incompleteCalendar in [false, true]) {
    testWidgets(
      'Daily review only counts verified unbooked time ($incompleteCalendar)',
      (tester) async {
        final previous = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final day = dateOnly(DateTime.now());
        DateTime at(int hour) => DateTime(day.year, day.month, day.day, hour);
        final data = WorkspaceData(
          tasks: [],
          notes: [],
          events: [
            CalendarEvent(
              id: 'accepted',
              title: 'Studio appointment',
              start: at(10),
              end: at(11),
              category: 'work',
            ),
          ],
          sections: {
            'schedulingSettings': SchedulingSettings(
              availability: [
                WeeklyAvailability(
                  id: 'work-time',
                  weekdays: [day.weekday],
                  startMinute: 9 * 60,
                  endMinute: 12 * 60,
                  categories: ['work'],
                ),
              ],
              beforeMinutes: 10,
              afterMinutes: 15,
            ).toJson(),
            if (incompleteCalendar)
              'calendarPreferences': CalendarSourcePreferences(
                allCalendars: const [
                  CalendarIdentity(
                    accountId: 'apple-fixture',
                    calendarId: 'unavailable-fixture',
                  ),
                ],
              ).toJson(),
          },
        );
        await SharedPreferencesAsync().setString(
          'easy.workspace.v1',
          data.encode(),
        );
        await tester.pumpWidget(
          const EasyApp(openStore: openPreferenceWorkspaceStore),
        );
        await tester.pumpAndSettle();
        Future<void> tap(Finder finder) async {
          await tester.tap(finder.hitTestable());
          await tester.pumpAndSettle();
        }

        await tap(find.text('Mode'));
        await tap(find.widgetWithText(MenuItemButton, 'Settings'));
        final review = find.text('Daily review');
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        await tap(review);
        expect(find.text('Studio appointment'), findsOneWidget);
        expect(
          find.text('1 h 35 min free'),
          incompleteCalendar ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
