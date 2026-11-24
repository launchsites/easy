import 'dart:ui' show SemanticsAction;

import 'package:easy/calendar_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final width in [320.0, 390.0, 840.0, 1110.0]) {
    testWidgets(
      'Calendar navigation and event details at ${width.toInt()} px',
      (tester) async {
        final monday = DateTime(2020, 11, 23);
        final meeting = _event('Planning meeting', monday, 9, 0, 75);
        final focus = _event('Project focus', monday, 9, 30, 90);
        CalendarEvent? opened;
        final view = await _mountCalendar(
          tester,
          width: width,
          date: monday,
          events: [meeting, focus],
          onEventTap: (event) => opened = event,
        );

        expect(find.byKey(const ValueKey('calendar-date')), findsOneWidget);
        for (final control in [
          'Day',
          'Week',
          'Month',
          'Today',
          'Previous day',
          'Next day',
        ]) {
          expect(find.text(control), findsNothing);
        }
        await tester.tap(find.text('Planning meeting'));
        expect(opened, same(meeting));
        expect(view.value, monday);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Mobile day swipes keep the visible clock time', (tester) async {
    final date = DateTime(2024, 3, 8);
    final nextDay = DateTime(2024, 3, 9);
    final selected = await _mountCalendar(
      tester,
      width: 390,
      date: date,
      events: [
        _event('First morning', date, 9, 30, 45),
        _event('Second morning', nextDay, 9, 30, 45),
      ],
    );
    expect(find.byTooltip('Saturday, March 9, 2024'), findsNothing);
    final firstY = tester.getTopLeft(find.text('First morning')).dy;

    await tester.dragFrom(const Offset(318, 295), const Offset(-180, 0));
    await tester.pumpAndSettle();

    expect(selected.value, nextDay);
    final nextY = tester.getTopLeft(find.text('Second morning')).dy;
    expect(nextY, closeTo(firstY, 2));
  });

  testWidgets('Mobile day scrolls naturally through both midnight boundaries', (
    tester,
  ) async {
    final date = DateTime(2024, 3, 8);
    final nextDay = DateTime(2024, 3, 9);
    final selected = await _mountCalendar(
      tester,
      width: 390,
      date: date,
      events: [_event('After midnight', nextDay, 0, 15, 25)],
    );

    Future<void> wheel(double distance) async {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(192, 415),
          scrollDelta: Offset(0, distance),
        ),
      );
      await tester.pumpAndSettle();
    }

    await wheel(500);
    expect(selected.value, date);
    await wheel(385);
    expect(selected.value, nextDay);
    expect(find.text('After midnight').hitTestable(), findsOneWidget);
    await wheel(-650);
    expect(selected.value, date);

    await tester.dragFrom(const Offset(192, 810), const Offset(0, -695));
    await tester.pumpAndSettle();
    expect(selected.value, nextDay);

    await wheel(-1500);
    expect(selected.value, DateTime(2024, 3, 7));
  });

  testWidgets('Tapping the mobile date opens the picker directly', (
    tester,
  ) async {
    final selected = await _mountCalendar(
      tester,
      width: 390,
      date: DateTime(2024, 3, 8),
      events: [],
    );
    await tester.tap(find.byKey(const ValueKey('calendar-date')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('9'),
      ),
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(selected.value, DateTime(2024, 3, 9));
  });

  testWidgets('Date supports accessible navigation without visible controls', (
    tester,
  ) async {
    final monday = DateTime(2020, 11, 23);
    final selected = await _mountCalendar(
      tester,
      width: 390,
      date: monday,
      events: [],
    );
    final button = tester.getSemantics(
      find.bySemanticsLabel('Monday, November 23, 2020'),
    );
    expect(
      button.getSemanticsData().hasAction(SemanticsAction.customAction),
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(selected.value, DateTime(2020, 11, 24));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(selected.value, monday);
  });

  testWidgets('Wide schedule date headings select the displayed day', (
    tester,
  ) async {
    final selected = await _mountCalendar(
      tester,
      width: 1110,
      date: DateTime(2020, 11, 23),
      events: [],
    );
    final headings = find.text('Wed, Nov 25');
    expect(headings, findsOneWidget);
    await tester.tap(headings);
    await tester.pumpAndSettle();
    expect(selected.value, DateTime(2020, 11, 25));
    expect(find.text('Wednesday, November 25, 2020'), findsOneWidget);
  });

  testWidgets('Adjacent short events stay separate from overlapping events', (
    tester,
  ) async {
    final date = DateTime(2020, 11, 23);
    await _mountCalendar(
      tester,
      width: 390,
      date: date,
      events: [
        _event('Huddle', date, 9, 0, 5),
        _event('Review', date, 9, 5, 5),
        _event('Studio', date, 9, 8, 12),
      ],
    );

    Rect card(String title) => tester.getRect(
      find.ancestor(of: find.text(title), matching: find.byType(Tooltip)).first,
    );
    final huddle = card('Huddle');
    final review = card('Review');
    final studio = card('Studio');
    expect(huddle.height, greaterThanOrEqualTo(22));
    expect(huddle.bottom, lessThan(review.top));
    expect(review.right, lessThan(studio.left));
  });

  testWidgets('Mobile schedule handles busy days and large text', (
    tester,
  ) async {
    final date = DateTime(2020, 11, 23);
    await _mountCalendar(
      tester,
      width: 320,
      textScale: 2,
      date: date,
      events: [
        for (var index = 0; index < 5; index++)
          _event('Event $index', date, 9 + index, 0, 30),
      ],
    );
    expect(find.bySemanticsLabel('Monday, November 23, 2020'), findsOneWidget);
    expect(find.text('Event 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('All-day entries stop on their exclusive end date', (
    tester,
  ) async {
    final date = DateTime(2020, 11, 23);
    await _mountCalendar(
      tester,
      width: 390,
      date: date,
      events: [
        CalendarEvent(
          id: 'trip',
          title: 'Trip',
          start: date,
          end: DateTime(2020, 11, 25),
          category: 'personal',
          allDay: true,
        ),
      ],
    );
    expect(find.text('Trip'), findsOneWidget);
    await tester.dragFrom(const Offset(318, 295), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('Trip'), findsOneWidget);
    await tester.dragFrom(const Offset(318, 295), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(find.text('Trip'), findsNothing);
  });

  final eastern =
      DateTime.utc(2026, 3, 8, 6).toLocal().timeZoneOffset ==
          const Duration(hours: -5) &&
      DateTime.utc(2026, 3, 8, 7).toLocal().timeZoneOffset ==
          const Duration(hours: -4) &&
      DateTime.utc(2026, 11, 1, 5).toLocal().timeZoneOffset ==
          const Duration(hours: -4) &&
      DateTime.utc(2026, 11, 1, 6).toLocal().timeZoneOffset ==
          const Duration(hours: -5);
  for (final (date, nextDay, start, hours, expectedRange) in [
    (
      DateTime(2026, 3, 8),
      DateTime(2026, 3, 9),
      DateTime.utc(2026, 3, 8, 6, 55),
      23,
      '1:55 AM UTC−05:00 – 3:54 AM UTC−04:00',
    ),
    (
      DateTime(2026, 11, 1),
      DateTime(2026, 11, 2),
      DateTime.utc(2026, 11, 1, 5, 55),
      25,
      '1:55 AM UTC−04:00 – 1:54 AM UTC−05:00',
    ),
  ]) {
    testWidgets(
      '$hours-hour mobile day keeps elapsed geometry and civil swipe position',
      (tester) async {
        expect(nextDay.difference(date), Duration(hours: hours));
        final across = _eventAt('Across the change', start, 59);
        final guide = _event('Same duration', date, 4, 0, 59);
        final morning = _event('Transition morning', date, 9, 30, 59);
        final nextMorning = _event('Following morning', nextDay, 9, 30, 59);
        final endOfDay = _event('Before midnight', date, 23, 20, 35);
        final afterMidnight = _event('After midnight', nextDay, 0, 45, 35);
        final selected = await _mountCalendar(
          tester,
          width: 320,
          textScale: 2,
          date: date,
          events: [
            across,
            guide,
            morning,
            nextMorning,
            endOfDay,
            afterMidnight,
          ],
        );
        await tester.pumpAndSettle();

        final morningPosition = tester.getTopLeft(find.text(morning.title)).dy;
        await tester.dragFrom(const Offset(260, 300), const Offset(-175, 0));
        await tester.pumpAndSettle();
        expect(selected.value, nextDay);
        expect(
          tester.getTopLeft(find.text(nextMorning.title)).dy,
          closeTo(morningPosition, 2),
        );
        await tester.dragFrom(const Offset(60, 300), const Offset(175, 0));
        await tester.pumpAndSettle();
        expect(selected.value, date);
        expect(
          tester.getTopLeft(find.text(morning.title)).dy,
          closeTo(morningPosition, 2),
        );

        final scrollBack = hours == 23 ? 335.0 : 440.0;
        await _wheel(tester, -scrollBack);
        expect(selected.value, date);
        final span = find.byTooltip('${across.title}, $expectedRange');
        expect(span, findsOneWidget);
        final minuteHeight = (tester.getSize(span).height + 4) / 59;
        final daySurface = find
            .ancestor(of: span, matching: find.byType(Material))
            .first;
        expect(
          tester.getSize(daySurface).height,
          closeTo(hours * 60 * minuteHeight, .5),
        );
        expect(
          tester.getSize(span).height,
          closeTo(tester.getSize(_card(guide.title)).height, .5),
        );
        if (hours == 23) {
          expect(find.text('2:00 AM').hitTestable(), findsNothing);
        } else {
          expect(find.text('1:00 AM\nEDT').hitTestable(), findsOneWidget);
          expect(find.text('1:00 AM\nEST').hitTestable(), findsOneWidget);
        }
        for (final label in [
          'Day',
          'Week',
          'Month',
          'Today',
          'Previous day',
          'Next day',
          'M',
          'T',
          'W',
          'F',
          'S',
        ]) {
          expect(find.text(label), findsNothing);
        }

        await _wheel(tester, 760 + scrollBack);
        expect(selected.value, date);
        expect(find.text(endOfDay.title).hitTestable(), findsOneWidget);
        await tester.timedDragFrom(
          const Offset(170, 748),
          const Offset(0, -145),
          const Duration(milliseconds: 750),
        );
        await tester.pumpAndSettle();
        expect(selected.value, nextDay);
        expect(find.text(afterMidnight.title).hitTestable(), findsOneWidget);
        await _wheel(tester, -140);
        expect(selected.value, date);
        expect(tester.takeException(), isNull);
      },
      skip: !eastern,
    );
  }

  testWidgets('a mobile swipe lands on the matching repeated offset', (
    tester,
  ) async {
    final sunday = DateTime(2026, 11, 1);
    final monday = DateTime(2026, 11, 2);
    final first = _eventAt(
      'First occurrence',
      DateTime.utc(2026, 11, 1, 5, 30),
      35,
    );
    final second = _eventAt(
      'Second occurrence',
      DateTime.utc(2026, 11, 1, 6, 30),
      35,
    );
    final following = _event('Monday appointment', monday, 1, 30, 35);
    final selected = await _mountCalendar(
      tester,
      width: 390,
      date: monday,
      events: [first, second, following],
    );
    await tester.pumpAndSettle();
    await _wheel(tester, -350);
    final top = tester.getTopLeft(_card(following.title)).dy;

    await tester.dragFrom(const Offset(62, 295), const Offset(178, 0));
    await tester.pumpAndSettle();

    expect(selected.value, sunday);
    expect(find.text(first.title).hitTestable(), findsNothing);
    expect(find.text(second.title).hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(_card(second.title)).dy, closeTo(top, 2));
  }, skip: !eastern);

  testWidgets('wide week keeps local clock alignment across the fold', (
    tester,
  ) async {
    final foldDay = DateTime(2026, 11, 1);
    final weekDay = DateTime(2026, 10, 31);
    final repeated = _eventAt(
      'First 1:30',
      DateTime.utc(2026, 11, 1, 5, 30),
      45,
    );
    final second = _eventAt(
      'Second 1:30',
      DateTime.utc(2026, 11, 1, 6, 30),
      45,
    );
    final across = _eventAt(
      'Across the fold',
      DateTime.utc(2026, 11, 1, 5, 55),
      59,
    );
    final prior = _event('Saturday eight', weekDay, 8, 0, 45);
    final current = _event('Sunday eight', foldDay, 8, 0, 45);
    await _mountCalendar(
      tester,
      width: 1600,
      date: foldDay,
      events: [repeated, second, across, prior, current],
    );
    await tester.pumpAndSettle();
    expect(find.text('1:00 AM'), findsOneWidget);
    expect(
      find.byTooltip('Across the fold, 1:55 AM UTC−04:00 – 1:54 AM UTC−05:00'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(_card(prior.title)).dy,
      closeTo(tester.getTopLeft(_card(current.title)).dy, .5),
    );
    expect(
      tester
          .getRect(_card(repeated.title))
          .overlaps(tester.getRect(_card(second.title))),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  }, skip: !eastern);

  final halfHourDate = DateTime(2026, 4, 5);
  final halfHourEnd = DateTime(2026, 4, 6);
  testWidgets(
    'half-hour rollback uses its real change point on mobile',
    (tester) async {
      final cross = _eventAt(
        'Half-hour change',
        DateTime.utc(2026, 4, 4, 14, 55),
        59,
      );
      final guide = _event('Same duration', halfHourDate, 4, 0, 59);
      await _mountCalendar(
        tester,
        width: 390,
        date: halfHourDate,
        events: [cross, guide],
      );
      await tester.pumpAndSettle();
      await _wheel(tester, -400);
      expect(find.text('1:30 AM').hitTestable(), findsOneWidget);
      expect(find.text('2:00 AM').hitTestable(), findsOneWidget);
      final span = find.byTooltip(
        'Half-hour change, 1:55 AM UTC+11:00 – 2:24 AM UTC+10:30',
      );
      expect(span, findsOneWidget);
      expect(
        tester.getSize(span).height,
        closeTo(tester.getSize(_card(guide.title)).height, .5),
      );
    },
    skip:
        halfHourEnd.difference(halfHourDate) !=
        const Duration(hours: 24, minutes: 30),
  );
}

CalendarEvent _event(
  String title,
  DateTime day,
  int hour,
  int minute,
  int duration,
) {
  final start = DateTime(day.year, day.month, day.day, hour, minute);
  return _eventAt(title, start, duration);
}

CalendarEvent _eventAt(String title, DateTime start, int duration) =>
    CalendarEvent(
      id: title,
      title: title,
      start: start,
      end: start.add(Duration(minutes: duration)),
      category: 'work',
    );

Finder _card(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Tooltip)).first;

Future<void> _wheel(WidgetTester tester, double distance) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: const Offset(170, 410),
      scrollDelta: Offset(0, distance),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ValueNotifier<DateTime>> _mountCalendar(
  WidgetTester tester, {
  required double width,
  required DateTime date,
  required List<CalendarEvent> events,
  double textScale = 1,
  ValueChanged<CalendarEvent>? onEventTap,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final selectedDate = ValueNotifier(date);
  addTearDown(selectedDate.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: ValueListenableBuilder(
            valueListenable: selectedDate,
            builder: (context, date, child) => CalendarPage(
              date: date,
              onDateChanged: (date) => selectedDate.value = date,
              events: events,
              onEventTap: onEventTap ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  return selectedDate;
}
