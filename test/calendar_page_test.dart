import 'package:easy/calendar_page.dart';
import 'package:flutter/gestures.dart';
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

        expect(
          find.byTooltip(width < 720 ? 'Calendar date options' : 'Next week'),
          findsOneWidget,
        );
        if (width >= 720) await _chooseView(tester, CalendarView.day);
        await tester.tap(find.text('Planning meeting'));
        expect(opened, same(meeting));

        await _nextDay(tester);
        expect(view.value, DateTime(2020, 11, 24));

        await _chooseView(tester, CalendarView.week);
        expect(find.byTooltip('Next week'), findsOneWidget);
        await _chooseView(tester, CalendarView.month);
        await tester.ensureVisible(find.text('Open day'));
        await tester.tap(find.text('Open day'));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip(width < 720 ? 'Calendar date options' : 'Next day'),
          findsOneWidget,
        );
        expect(view.value, DateTime(2020, 11, 24));
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

  testWidgets('Mobile date menu opens the date picker', (tester) async {
    await _mountCalendar(
      tester,
      width: 390,
      date: DateTime(2024, 3, 8),
      events: [],
    );
    await tester.tap(find.byTooltip('Calendar date options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jump to date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
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

  testWidgets('Month preview handles dense dates and large text', (
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
    await _chooseView(tester, CalendarView.month);
    expect(
      find.bySemanticsLabel('Monday, November 23, 2020, 5 events'),
      findsOneWidget,
    );
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
    await _nextDay(tester);
    expect(find.text('Trip'), findsOneWidget);
    await _nextDay(tester);
    expect(find.text('Trip'), findsNothing);
  });
}

Future<void> _chooseView(WidgetTester tester, CalendarView view) async {
  final viewMenu = find.byTooltip('Calendar view');
  if (viewMenu.evaluate().isNotEmpty) {
    await tester.tap(viewMenu);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(view.label).last);
  await tester.pumpAndSettle();
}

Future<void> _nextDay(WidgetTester tester) async {
  final dateMenu = find.byTooltip('Calendar date options');
  if (dateMenu.evaluate().isNotEmpty) {
    await tester.tap(dateMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next day'));
  } else {
    await tester.tap(find.byTooltip('Next day'));
  }
  await tester.pumpAndSettle();
}

CalendarEvent _event(
  String title,
  DateTime day,
  int hour,
  int minute,
  int duration,
) {
  final start = DateTime(day.year, day.month, day.day, hour, minute);
  return CalendarEvent(
    id: title,
    title: title,
    start: start,
    end: start.add(Duration(minutes: duration)),
    category: 'work',
  );
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
