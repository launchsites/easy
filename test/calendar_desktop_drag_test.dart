import 'package:easy/calendar_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final monday = DateTime(2024, 1, 8);

  testWidgets('week drag previews a rounded range and stays on its first day', (
    tester,
  ) async {
    final wednesday = DateTime(2024, 1, 10);
    final thursday = DateTime(2024, 1, 11);
    final ranges = <DateTimeRange>[];
    final selected = await _mount(tester, monday, ranges.add);
    final startColumn = tester.getRect(_column(wednesday));
    final otherColumn = tester.getRect(_column(thursday));
    final start = Offset(startColumn.center.dx, startColumn.top + 68 * .95);
    final end = Offset(otherColumn.center.dx, startColumn.top + 157 * .95);

    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 30));
    await drag.moveTo(end);
    await tester.pump();

    expect(ranges, isEmpty);
    expect(find.text('9:15 AM–10:30 AM'), findsOneWidget);
    expect(
      find.descendant(of: _column(wednesday), matching: _preview),
      findsOneWidget,
    );
    await drag.up();
    await tester.pumpAndSettle();

    expect(_preview, findsNothing);
    expect(selected.value, monday);
    expect(ranges, [
      DateTimeRange(
        start: DateTime(2024, 1, 10, 9, 15),
        end: DateTime(2024, 1, 10, 10, 30),
      ),
    ]);
  });

  testWidgets('single-day desktop drags up and preserves existing event taps', (
    tester,
  ) async {
    final event = _event('Existing event', monday, 9);
    final ranges = <DateTimeRange>[];
    CalendarEvent? opened;
    await _mount(
      tester,
      monday,
      ranges.add,
      width: 740,
      events: [event],
      onEventTap: (event) => opened = event,
    );

    final card = find.text(event.title);
    await tester.drag(
      card,
      const Offset(0, 110),
      kind: PointerDeviceKind.mouse,
    );
    expect(ranges, isEmpty);
    await tester.tap(card, kind: PointerDeviceKind.mouse);
    expect(opened, same(event));

    final column = tester.getRect(_column(monday));
    Offset at(int minute) =>
        Offset(column.center.dx, column.top + minute * 53 / 60);
    final start = at(10 * 60 + 49);
    final end = at(10 * 60 + 17);
    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(end);
    await drag.up();
    await tester.pumpAndSettle();

    expect(ranges, [
      DateTimeRange(
        start: DateTime(2024, 1, 8, 10, 15),
        end: DateTime(2024, 1, 8, 10, 45),
      ),
    ]);
  });

  testWidgets('canceled, secondary and same-slot drags leave no draft', (
    tester,
  ) async {
    final ranges = <DateTimeRange>[];
    await _mount(tester, monday, ranges.add);
    final column = tester.getRect(_column(monday));
    final origin = Offset(column.center.dx, column.top + 57);

    final canceled = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
    );
    await canceled.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(_preview, findsOneWidget);
    await canceled.cancel();
    await tester.pump();
    expect(_preview, findsNothing);

    final rightButton = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await rightButton.moveBy(const Offset(0, 70));
    await rightButton.up();
    await tester.dragFrom(
      origin,
      const Offset(0, 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(ranges, isEmpty);
    expect(_preview, findsNothing);
  });

  testWidgets('mobile touch swipes never invoke the desktop callback', (
    tester,
  ) async {
    final ranges = <DateTimeRange>[];
    final selected = await _mount(tester, monday, ranges.add, width: 390);

    expect(_column(monday), findsNothing);
    await tester.dragFrom(const Offset(315, 290), const Offset(-180, 0));
    await tester.pumpAndSettle();

    expect(selected.value, DateTime(2024, 1, 9));
    expect(ranges, isEmpty);
  });

  final first = DateTime.utc(2026, 11, 1, 5, 30).toLocal();
  final second = DateTime.utc(2026, 11, 1, 6, 30).toLocal();
  final easternFold =
      first.hour == 1 &&
      second.hour == 1 &&
      first.timeZoneOffset != second.timeZoneOffset;
  testWidgets('a civil week refuses an ambiguous wall time during fallback', (
    tester,
  ) async {
    final sunday = DateTime(2026, 11, 1);
    final saturday = DateTime(2026, 10, 31);
    final ranges = <DateTimeRange>[];
    await _mount(
      tester,
      sunday,
      ranges.add,
      events: [_event('Early booking', saturday, 0)],
    );
    final column = tester.getRect(_column(sunday));
    Offset at(int minute) =>
        Offset(column.center.dx, column.top + minute * .95);

    final drag = await tester.startGesture(
      at(75),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(at(135));
    await tester.pump();
    expect(find.text('Choose another time'), findsOneWidget);
    await drag.up();
    expect(ranges, isEmpty);

    final exact = await tester.startGesture(
      at(30),
      kind: PointerDeviceKind.mouse,
    );
    await exact.moveTo(at(135));
    await exact.up();
    await tester.pumpAndSettle();
    expect(ranges.single.start.toUtc(), DateTime.utc(2026, 11, 1, 4, 30));
    expect(ranges.single.end.toUtc(), DateTime.utc(2026, 11, 1, 7, 15));
  }, skip: !easternFold);
}

Finder _column(DateTime date) =>
    find.byKey(ValueKey(('calendar-selection', date)));

final _preview = find.byKey(const ValueKey('calendar-selection-preview'));

CalendarEvent _event(String title, DateTime date, int hour) {
  final start = DateTime(date.year, date.month, date.day, hour);
  return CalendarEvent(
    id: title,
    title: title,
    start: start,
    end: start.add(const Duration(hours: 1)),
    category: 'work',
  );
}

Future<ValueNotifier<DateTime>> _mount(
  WidgetTester tester,
  DateTime date,
  ValueChanged<DateTimeRange> onCreate, {
  double width = 1110,
  List<CalendarEvent> events = const [],
  ValueChanged<CalendarEvent>? onEventTap,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final selected = ValueNotifier(date);
  addTearDown(selected.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: selected,
          builder: (_, date, _) => CalendarPage(
            date: date,
            onDateChanged: (date) => selected.value = date,
            events: events,
            onEventTap: onEventTap ?? (_) {},
            onCreateTimedEvent: onCreate,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return selected;
}
