import 'dart:math';

import 'package:easy/calendar_event_index.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/ui_theme.dart' as palette;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

CalendarEvent _event(
  String id,
  DateTime start,
  DateTime end, {
  bool allDay = false,
}) => CalendarEvent(
  id: id,
  title: id,
  start: start,
  end: end,
  category: 'work',
  allDay: allDay,
);

CalendarEventIndex<CalendarEvent> _index(List<CalendarEvent> events) =>
    CalendarEventIndex(
      events,
      startOf: (event) => event.start,
      endOf: (event) => event.end,
    );

void main() {
  test('keeps overnight and all-day events until their exclusive end', () {
    final monday = DateTime(2026, 11, 23);
    final tuesday = DateTime(2026, 11, 24);
    final wednesday = DateTime(2026, 11, 25);
    final trip = _event('Trip', monday, wednesday, allDay: true);
    final overnight = _event(
      'Overnight',
      DateTime(2026, 11, 23, 23),
      DateTime(2026, 11, 24, 1),
    );
    final untilMidnight = _event(
      'Ends at midnight',
      DateTime(2026, 11, 23, 20),
      tuesday,
    );
    final startsAtMidnight = _event(
      'Starts at midnight',
      tuesday,
      DateTime(2026, 11, 24, 1),
    );
    final index = _index([startsAtMidnight, overnight, untilMidnight, trip]);

    expect(index.onDay(monday), [trip, untilMidnight, overnight]);
    expect(index.onDay(tuesday), [trip, overnight, startsAtMidnight]);
    expect(index.onDay(wednesday), isEmpty);
  });

  test('zero and reversed spans remain on the local start day', () {
    final midnight = DateTime(1965, 7, 3);
    final utc = midnight.toUtc();
    final zero = _event('Zero', utc, utc);
    final reversed = _event(
      'Reversed',
      utc,
      utc.subtract(const Duration(hours: 2)),
    );
    final index = _index([zero, reversed]);

    expect(index.onDay(DateTime(1965, 7, 2)), isEmpty);
    expect(index.onDay(midnight), [zero, reversed]);
    expect(index.onDay(DateTime(1965, 7, 4)), isEmpty);
    expect(
      index.overlapping(
        midnight,
        midnight.add(const Duration(microseconds: 1)),
      ),
      [zero, reversed],
    );
    expect(index.overlapping(midnight, midnight), isEmpty);
  });

  test('uses calendar midnight boundaries on a daylight change weekend', () {
    final day = DateTime(2026, 3, 8);
    final nextDay = DateTime(2026, 3, 9);
    final atEnd = _event(
      'Ends at midnight',
      DateTime(2026, 3, 8, 23, 30),
      nextDay,
    );
    final after = _event(
      'After midnight',
      DateTime(2026, 3, 9, 0, 15),
      DateTime(2026, 3, 9, 0, 45),
    );
    final index = _index([after, atEnd]);

    expect(index.onDay(day), [atEnd]);
    expect(index.onDay(nextDay), [after]);
  });

  test('seeded day and week queries agree with the full history predicate', () {
    final random = Random(20261124);
    final history = <CalendarEvent>[
      _event('Very long', DateTime(1900), DateTime(2200), allDay: true),
    ];
    for (var index = 0; index < 1800; index++) {
      final start = DateTime(
        1969,
        11,
        random.nextInt(180),
        random.nextInt(24),
        index % 60,
        0,
        0,
        index % 999,
      );
      final end = start.add(Duration(minutes: random.nextInt(5000) - 120));
      history.add(_event('Event $index', start, end, allDay: index % 7 == 0));
    }
    final index = _index(history);
    List<CalendarEvent> baseline(DateTime begin, DateTime end) =>
        history.where((event) {
            if (!event.end.isAfter(event.start)) {
              return !event.start.isBefore(begin) && event.start.isBefore(end);
            }
            return event.start.isBefore(end) && event.end.isAfter(begin);
          }).toList()
          ..sort((first, second) => first.start.compareTo(second.start));

    for (var offset = 0; offset < 180; offset++) {
      final start = DateTime(1969, 11, offset);
      expect(
        index.onDay(start),
        baseline(start, DateTime(1969, 11, offset + 1)),
      );
      if (offset % 7 == 0) {
        final end = DateTime(1969, 11, offset + 7);
        expect(index.overlapping(start, end), baseline(start, end));
      }
    }
    expect(index.onDay(DateTime(2190)).single.id, 'Very long');
  });

  test('returns reusable day snapshots and bounds the cache', () {
    final date = DateTime(2026, 11, 24);
    final event = _event('Event', date, DateTime(2026, 11, 25));
    final index = _index([event]);
    final first = index.onDay(date);
    expect(index.onDay(DateTime(2026, 11, 24, 12)), same(first));
    expect(() => first.add(event), throwsUnsupportedError);

    for (var offset = 1; offset <= 64; offset++) {
      index.onDay(DateTime(2026, 11, 24 + offset));
    }

    final renewed = index.onDay(date);
    expect(renewed, [event]);
    expect(identical(renewed, first), isFalse);
  });

  testWidgets('changing the event revision refreshes rendered day records', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final date = DateTime(2020, 11, 24);
    final start = DateTime(2020, 11, 24, 9, 30);
    final end = DateTime(2020, 11, 24, 10, 15);
    final events = [_event('Original appointment', start, end)];

    Widget app(int revision) => MaterialApp(
      home: Scaffold(
        body: CalendarPage(
          date: date,
          events: events,
          eventsRevision: revision,
          onDateChanged: (_) {},
          onEventTap: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();
    expect(find.text('Original appointment'), findsOneWidget);
    events[0] = _event('Updated appointment', start, end);
    await tester.pumpWidget(app(2));
    await tester.pumpAndSettle();
    expect(find.text('Original appointment'), findsNothing);
    expect(find.text('Updated appointment'), findsOneWidget);
  });

  testWidgets(
    'source colors tint timed and all-day entries with readable ink',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final date = DateTime(2020, 11, 24);
      const color = Color(0xffffe713);
      final events = [
        CalendarEvent(
          id: 'timed',
          title: 'Imported meeting',
          start: DateTime(2020, 11, 24, 9, 30),
          end: DateTime(2020, 11, 24, 10, 30),
          category: 'work',
          sourceLabel: 'Imported',
          color: color,
        ),
        CalendarEvent(
          id: 'all-day',
          title: 'Imported holiday',
          start: date,
          end: DateTime(2020, 11, 25),
          category: 'work',
          sourceLabel: 'Imported',
          color: color,
          allDay: true,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: palette.easyTheme(),
          home: Scaffold(
            body: CalendarPage(
              date: date,
              events: events,
              onDateChanged: (_) {},
              onEventTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tint = Color.alphaBlend(
        color.withValues(alpha: .09),
        palette.paper,
      );
      for (final event in events) {
        final text = find.text(event.title);
        final ink = tester.widget<Text>(text).style!.color!.computeLuminance();
        final fill = tint.computeLuminance();
        expect(
          (max(ink, fill) + .05) / (min(ink, fill) + .05),
          greaterThanOrEqualTo(4.5),
        );
        final surfaces = find.ancestor(
          of: text,
          matching: find.byType(Material),
        );
        expect(
          tester.widgetList<Material>(surfaces).map((item) => item.color),
          contains(tint),
        );
      }
    },
  );
}
