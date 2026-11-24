import 'package:easy/calendar_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Mobile Calendar keeps its clock and taps after a long scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final first = DateTime(2032, 1, 20);
    final next = DateTime(2032, 1, 21);
    final selected = ValueNotifier(first);
    addTearDown(selected.dispose);
    CalendarEvent appointment(String title, DateTime date) {
      final start = DateTime(date.year, date.month, date.day, 9, 30);
      return CalendarEvent(
        id: title,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        category: 'work',
      );
    }

    final originalEvent = appointment('Studio review', first);
    final nextEvent = appointment('Send studio notes', next);
    final events = [originalEvent, nextEvent];
    CalendarEvent? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: selected,
            builder: (context, date, child) => CalendarPage(
              date: date,
              onDateChanged: (value) => selected.value = value,
              events: events,
              onEventTap: (event) => opened = event,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final originalTile = find.text(originalEvent.title).hitTestable();
    final originalY = tester.getTopLeft(originalTile).dy;
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    final position = scroll.position;
    final startingOffset = position.pixels;

    const steps = 320;
    const distance = 1300.0;
    Future<void> move(double offset) async {
      position.jumpTo(offset);
      await tester.pump();
    }

    final heading = find.byKey(const ValueKey('calendar-date'));
    String dateLabel(DateTime day) =>
        MaterialLocalizations.of(tester.element(heading)).formatMediumDate(day);
    Finder headingWith(DateTime day) =>
        find.descendant(of: heading, matching: find.text(dateLabel(day)));
    final timeline = find.byType(CustomScrollView);
    GlobalKey sectionKey(DateTime day) {
      final section = find.ancestor(
        of: find.descendant(of: timeline, matching: find.text(dateLabel(day))),
        matching: find.descendant(
          of: timeline,
          matching: find.byWidgetPredicate(
            (widget) => widget is KeyedSubtree && widget.key is GlobalKey,
          ),
        ),
      );
      return tester.widget<KeyedSubtree>(section).key! as GlobalKey;
    }

    final initialKey = sectionKey(first);
    for (var index = 1; index <= steps; index++) {
      await move(startingOffset + index * distance);
    }
    await tester.pumpAndSettle();
    expect(selected.value.difference(first).inDays, greaterThan(300));
    expect(headingWith(selected.value), findsOneWidget);
    expect(originalTile, findsNothing);
    expect(initialKey.currentContext, isNull);

    for (var index = steps - 1; index >= -2; index--) {
      await move(startingOffset + index * distance);
    }
    await tester.pumpAndSettle();
    expect(selected.value.isBefore(first), isTrue);
    expect(headingWith(selected.value), findsOneWidget);

    await move(startingOffset);
    await tester.pumpAndSettle();
    expect(selected.value, first);
    expect(headingWith(first), findsOneWidget);
    expect(sectionKey(first), isNot(same(initialKey)));
    expect(tester.getTopLeft(originalTile).dy, closeTo(originalY, 2));
    await tester.tap(originalTile);
    expect(opened, same(originalEvent));

    await tester.dragFrom(const Offset(318, 295), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(selected.value, next);
    final nextTile = find.text(nextEvent.title).hitTestable();
    expect(tester.getTopLeft(nextTile).dy, closeTo(originalY, 2));
    await tester.tap(nextTile);
    expect(opened, same(nextEvent));
    expect(tester.takeException(), isNull);
  });
}
