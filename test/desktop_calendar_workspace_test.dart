import 'package:easy/calendar_page.dart';
import 'package:easy/main.dart';
import 'package:easy/quick_capture.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final (name, modifier) in [
    ('Control', LogicalKeyboardKey.controlLeft),
    ('Meta', LogicalKeyboardKey.metaLeft),
  ]) {
    testWidgets('$name+N opens event capture for the selected Calendar date', (
      tester,
    ) async {
      final (store, selectedDay) = await _openCalendar(tester);
      final before = await store.read();
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();

      final capture = find.byType(QuickCapture);
      expect(capture, findsOneWidget);
      final widget = tester.widget<QuickCapture>(capture);
      expect(widget.kind, RecordKind.event);
      expect(widget.date, selectedDay);
      final input = find.descendant(
        of: capture,
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
      expect((await store.read()).revision, before.revision);

      await tester.tap(
        find.descendant(of: capture, matching: find.byTooltip('Close')),
      );
      await tester.pumpAndSettle();
      expect(capture, findsNothing);
      expect((await store.read()).revision, before.revision);
    });
  }

  testWidgets('desktop Calendar drag opens a draft and saves only on review', (
    tester,
  ) async {
    final (store, selectedDay) = await _openCalendar(tester);
    final before = await store.read();
    final range = DateTimeRange(
      start: DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day,
        9,
        15,
      ),
      end: DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day,
        10,
        30,
      ),
    );
    final editor = find.byType(RecordEditor);

    Future<void> selectTime() async {
      final column = tester.getRect(
        find.byKey(ValueKey(('calendar-selection', selectedDay))),
      );
      final start = Offset(column.center.dx, column.top + 57 * 1.25);
      final end = Offset(column.center.dx, column.top + 57 * 2.5);
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(end);
      await tester.pump();
      expect(editor, findsNothing);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(tester.widget<RecordEditor>(editor).initialEventRange, range);
      expect((await store.read()).revision, before.revision);
    }

    await selectTime();
    await tester.tap(
      find.descendant(of: editor, matching: find.byTooltip('Close')),
    );
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect((await store.read()).revision, before.revision);

    await selectTime();
    await tester.enterText(
      find.descendant(of: editor, matching: find.byType(TextFormField)).first,
      'Draft from the week grid',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add event'));
    await tester.pumpAndSettle();

    expect(editor, findsNothing);
    final after = await store.read();
    expect(after.revision, before.revision + 1);
    final event = WorkspaceData.decode(after.snapshot.workspaceJson)
        .events
        .single;
    expect(event.title, 'Draft from the week grid');
    expect(event.start, range.start);
    expect(event.end, range.end);
    expect(event.allDay, isFalse);
    expect(
      tester.widget<CalendarPage>(find.byType(CalendarPage)).date,
      selectedDay,
    );
  });
}

Future<(WorkspaceStore, DateTime)> _openCalendar(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final platform = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);
  final fixture = WorkspaceData(events: [], tasks: [], notes: []);
  late WorkspaceStore store;
  await tester.pumpWidget(
    EasyApp(
      openStore: ({required preferences, required readLegacy}) async {
        store = await openPreferenceWorkspaceStore(
          preferences: preferences,
          readLegacy: () async => WorkspaceSnapshot(
            workspaceJson: fixture.encode(),
            gymSessionJson: const [],
            workoutPlanJson: const [],
          ),
        );
        return store;
      },
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Calendar').first);
  await tester.pumpAndSettle();

  final calendar = find.byType(CalendarPage);
  final initialDay = tester.widget<CalendarPage>(calendar).date;
  final selectedDay = DateUtils.addDaysToDate(
    initialDay,
    initialDay.weekday == DateTime.monday ? 1 : 1 - initialDay.weekday,
  );
  final localizations = MaterialLocalizations.of(tester.element(calendar));
  await tester.tap(
    find.descendant(
      of: calendar,
      matching: find.text(localizations.formatMediumDate(selectedDay)),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.widget<CalendarPage>(calendar).date, selectedDay);
  return (store, selectedDay);
}
