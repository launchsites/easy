import 'dart:convert';

import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter_test/flutter_test.dart';

String _calendar(List<String> contents) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'PRODID:-//Example//Fixtures//EN',
  ...contents,
  'END:VCALENDAR',
  '',
].join('\r\n');

List<String> _event(List<String> properties) => [
  'BEGIN:VEVENT',
  ...properties,
  'END:VEVENT',
];

void main() {
  test('preserves all-day bounds, timed instants, floating clocks and text escapes', () {
    final calendar = IcsCalendar.parse(
      _calendar([
        r'X-WR-CALNAME:My, calendar',
        ..._event([
          'UID:holiday',
          'DTSTART;VALUE=DATE:20261128',
          'DTEND;VALUE=DATE:20261130',
          r'SUMMARY:Holiday, with family;',
          r'DESCRIPTION:First line\nSecond line with \\.',
        ]),
        ..._event([
          'UID:call',
          'DTSTAMP:20261110T123000Z',
          'DTSTART:20261124T090000Z',
          'DTEND:20261124T100000Z',
          'SUMMARY:Call',
        ]),
        ..._event([
          'UID:focus',
          'DTSTART:20261124T150000',
          'DURATION:PT45M',
          r'LOCATION:Room, 2',
        ]),
      ]),
    );
    expect(calendar.name, 'My, calendar');
    final holiday = calendar.events.first;
    expect(holiday.start.kind, IcsDateTimeKind.date);
    expect(holiday.start.utcInstant, isNull);
    expect(holiday.end, IcsDateTime.date(DateTime(2026, 11, 30)));
    expect(holiday.summary, 'Holiday, with family;');
    expect(holiday.description, 'First line\nSecond line with \\.');
    expect(calendar.events[1].start.utcInstant, DateTime.utc(2026, 11, 24, 9));
    expect(
      calendar.events[1].stamp?.utcInstant,
      DateTime.utc(2026, 11, 10, 12, 30),
    );
    final focus = calendar.events.last;
    expect(focus.start.kind, IcsDateTimeKind.floating);
    expect(focus.start.components, DateTime.utc(2026, 11, 24, 15));
    expect(focus.start.utcInstant, isNull);
    expect(focus.duration, 'PT45M');
    expect(focus.location, 'Room, 2');
  });

  test('round-trips series rules, exceptions, detached occurrences and zone definitions', () {
    final calendar = IcsCalendar.parse(
      _calendar([
        'BEGIN:VTIMEZONE',
        'TZID:Europe/London',
        'BEGIN:STANDARD',
        'DTSTART:20261025T020000',
        'TZOFFSETFROM:+0100',
        'TZOFFSETTO:+0000',
        'END:STANDARD',
        'END:VTIMEZONE',
        ..._event([
          'UID:team-series',
          'DTSTART;TZID="Europe/London":20261124T093000',
          'DTEND;TZID=Europe/London:20261124T103000',
          'RRULE:FREQ=WEEKLY;COUNT=5;BYDAY=TU',
          'RDATE;TZID=Europe/London:20261127T093000,20261204T093000',
          'RDATE;VALUE=PERIOD;TZID=Europe/London:20261211T093000/PT30M',
          'EXDATE;TZID=Europe/London:20261201T093000',
          'SUMMARY:Team review',
          'SEQUENCE:3',
          'BEGIN:VALARM',
          'TRIGGER:-PT5M',
          'ACTION:DISPLAY',
          'END:VALARM',
        ]),
        ..._event([
          'UID:team-series',
          'RECURRENCE-ID;TZID=Europe/London;RANGE=THISANDFUTURE:20261208T093000',
          'DTSTART;TZID=Europe/London:20261208T140000',
          'SUMMARY:Moved meeting',
        ]),
      ]),
    );
    final series = calendar.events.first;
    expect(series.start.kind, IcsDateTimeKind.zoned);
    expect(series.start.timeZoneId, 'Europe/London');
    expect(series.start.utcInstant, isNull);
    expect(series.recurrenceRule, 'FREQ=WEEKLY;COUNT=5;BYDAY=TU');
    expect(series.recurrenceDates, hasLength(2));
    expect(
      series.exceptionDates.single.components,
      DateTime.utc(2026, 12, 1, 9, 30),
    );
    expect(
      calendar.events.last.recurrenceId?.components,
      DateTime.utc(2026, 12, 8, 9, 30),
    );
    expect(calendar.events.last.recurrenceRange, 'THISANDFUTURE');

    final encoded = calendar.encode(timestamp: DateTime.utc(2026, 11, 20));
    expect(encoded, contains('BEGIN:VTIMEZONE\r\n'));
    expect(encoded, contains('SEQUENCE:3\r\n'));
    expect(encoded, contains('BEGIN:VALARM\r\n'));
    expect(
      encoded,
      contains(
        'RDATE;VALUE=PERIOD;TZID=Europe/London:20261211T093000/PT30M\r\n',
      ),
    );
    final restored = IcsCalendar.parse(encoded);
    expect(restored.events.first.start, series.start);
    expect(restored.events.first.recurrenceDates, series.recurrenceDates);
    expect(restored.events.first.exceptionDates, series.exceptionDates);
    expect(
      restored.events.last.recurrenceId,
      calendar.events.last.recurrenceId,
    );
    expect(
      restored.events.last.recurrenceRange,
      calendar.events.last.recurrenceRange,
    );
  });

  test(
    'folds Unicode at 75 octets and round-trips line breaks and punctuation',
    () {
      final summary = List.filled(35, 'é🌲,;').join();
      final calendar = IcsCalendar(
        events: [
          IcsEvent(
            uid: 'special,uid',
            summary: summary,
            start: IcsDateTime.utc(DateTime.utc(2026, 11, 24, 9)),
            description: 'Notes with \\ and \r\nline breaks',
          ),
        ],
      );
      final encoded = calendar.encode(timestamp: DateTime.utc(2026, 11, 23));
      final lines = encoded.split('\r\n');
      expect(lines.any((line) => line.startsWith(' ')), isTrue);
      expect(
        lines.map((line) => utf8.encode(line).length),
        everyElement(lessThanOrEqualTo(75)),
      );
      final event = IcsCalendar.parseBytes(utf8.encode(encoded)).events.single;
      expect(event.summary, summary);
      expect(event.uid, 'special,uid');
      expect(event.description, 'Notes with \\ and \nline breaks');
      expect(event.stamp?.utcInstant, DateTime.utc(2026, 11, 23));
    },
  );

  test(
    'byte import unfolds a broken producer fold inside a multibyte scalar',
    () {
      final input = utf8.encode(
        _calendar(
          _event(['UID:unicode', 'DTSTART:20261124T090000Z', 'SUMMARY:🌲']),
        ),
      );
      final scalar = input.indexOf(0xf0);
      final folded = [
        ...input.take(scalar + 1),
        13,
        10,
        32,
        ...input.skip(scalar + 1),
      ];
      expect(IcsCalendar.parseBytes(folded).events.single.summary, '🌲');
    },
  );

  test(
    'rejects invalid calendar dates and contradictory schedule definitions',
    () {
      for (final properties in [
        ['DTSTART;VALUE=DATE:20260229'],
        ['DTSTART:20261124T246000Z'],
        ['DTSTART;TZID=Europe/London:20261124T090000Z'],
        ['DTSTART;VALUE=DATE:20261124', 'DTEND:20261124T090000Z'],
        ['DTSTART;VALUE=DATE:20261124', 'DURATION:PT1H'],
        ['DTSTART:20261124T090000Z', 'DTEND:20261124T080000Z'],
        ['DTSTART:20261124T090000Z', 'DTEND:20261124T100000Z', 'DURATION:PT1H'],
        [
          'DTSTART:20261124T090000Z',
          'RRULE:FREQ=DAILY;COUNT=2;UNTIL=20261130T090000Z',
        ],
        ['DTSTART:20261124T090000Z', 'RRULE:FREQ=WEEKLY;INTERVAL=0'],
        [
          'DTSTART:20261124T090000Z',
          'RDATE;VALUE=PERIOD:20261125T090000Z/20261125T083000Z',
        ],
      ]) {
        expect(
          () =>
              IcsCalendar.parse(_calendar(_event(['UID:bad', ...properties]))),
          throwsFormatException,
          reason: properties.join(', '),
        );
      }
      expect(
        () => IcsCalendar.parse('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VEVENT'),
        throwsFormatException,
      );
    },
  );
}
