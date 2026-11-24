import 'package:easy/calendar_page.dart';
import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:easy/main.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final busy in [true, false]) {
    testWidgets(
      'Today evaluates a saved repeat while browsing another month ($busy)',
      (tester) async {
        final previous = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final now = DateTime.now();
        final day = dateOnly(now);
        final far = DateTime(day.year, day.month + 3, 4);
        final anchor = now.toUtc().subtract(
          const Duration(days: 1, minutes: 10),
        );
        const eventTitle = 'Daily physical therapy';
        const taskTitle = 'Send updated studio hours';
        final series = InternalRecurringEvent(
          id: 'daily-physical-therapy',
          event: InternalEventDraft.fromDates(
            title: eventTitle,
            start: anchor,
            end: anchor.add(Duration(minutes: busy ? 25 : 5)),
            category: 'personal',
          ),
          rule: InternalRecurrenceRule(
            frequency: InternalRecurrenceFrequency.daily,
            count: 2,
          ),
        );
        final data = WorkspaceData(
          tasks: [
            TaskItem(
              id: 'studio-hours',
              title: taskTitle,
              category: 'work',
              date: day,
              estimatedMinutes: 1,
            ),
          ],
          events: [],
          notes: [],
          sections: {
            'recurringEvents': [series.toJson()],
            'schedulingSettings': SchedulingSettings(
              availability: [
                WeeklyAvailability(
                  id: 'work-hours',
                  weekdays: [day.weekday],
                  startMinute: 0,
                  endMinute: 1440,
                  categories: ['work'],
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
          await tester.tap(finder.hitTestable().first);
          await tester.pumpAndSettle();
        }

        await tap(find.text('Calendar'));
        final calendar = find.byType(CalendarPage);
        CalendarPage page() => tester.widget<CalendarPage>(calendar);
        bool includesSeries() =>
            page().events.any((event) => event.recurringSeriesId == series.id);
        await _pumpUntil(tester, includesSeries);
        expect(includesSeries(), isTrue);

        final labels = MaterialLocalizations.of(tester.element(calendar));
        await tap(find.byKey(const ValueKey('calendar-date')));
        final datePicker = find.byType(DatePickerDialog);
        await tap(
          find.descendant(
            of: datePicker,
            matching: find.byTooltip(labels.inputDateModeButtonLabel),
          ),
        );
        await tester.enterText(
          find.descendant(of: datePicker, matching: find.byType(TextFormField)),
          labels.formatCompactDate(far),
        );
        await tap(
          find.descendant(
            of: datePicker,
            matching: find.text(labels.okButtonLabel),
          ),
        );
        expect(page().date, far);
        await _pumpUntil(tester, () => !includesSeries());
        expect(includesSeries(), isFalse);

        await tap(find.text('Work'));
        await tap(find.text('Today'));
        expect(find.text(taskTitle), findsOneWidget);
        final label = find.text('Fits now');
        final hasRoom =
            !busy &&
            plusDays(day, 1).difference(now) >
                const Duration(minutes: 1, seconds: 5);
        await _pumpUntil(tester, () => label.evaluate().isNotEmpty);
        if (hasRoom) {
          expect(label, findsOneWidget);
        } else if (busy) {
          expect(label, findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}
