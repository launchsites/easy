import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an authored series follows the official clock beyond 2037', () {
    const zone = 'Europe/Lisbon';
    final calendar = IcsCalendar(
      events: [
        IcsEvent(
          uid: 'lisbon-series',
          start: IcsDateTime.zoned(DateTime.utc(2050, 3, 26, 9), zone),
          end: IcsDateTime.zoned(DateTime.utc(2050, 3, 26, 10), zone),
          recurrenceRule: 'FREQ=DAILY;COUNT=3',
        ),
        IcsEvent(
          uid: 'lisbon-single',
          start: IcsDateTime.zoned(DateTime.utc(2050, 3, 28, 12), zone),
        ),
      ],
    );
    final encoded = calendar.encode(timestamp: DateTime.utc(2026));
    expect(RegExp('BEGIN:VTIMEZONE').allMatches(encoded), hasLength(1));
    expect(encoded, contains('TZID:Europe/Lisbon\r\n'));
    expect(encoded, contains('RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU'));
    expect(
      encoded.indexOf('END:VTIMEZONE'),
      lessThan(encoded.indexOf('BEGIN:VEVENT')),
    );
    final restored = IcsCalendar.parseBytes(utf8.encode(encoded));
    const expectedHours = [9, 8, 8];
    for (final source in [calendar, restored]) {
      final instances = expandIcsCalendar(
        source,
        windowStart: DateTime.utc(2050, 3, 26),
        windowEnd: DateTime.utc(2050, 3, 29),
      );
      expect(
        instances
            .where((item) => item.sourceUid == 'lisbon-series')
            .map((item) => item.start),
        [
          for (final (i, hour) in expectedHours.indexed)
            DateTime.utc(2050, 3, 26 + i, hour),
        ],
      );
      expect(instances.last.start, DateTime.utc(2050, 3, 28, 11));
    }
  });

  test(
    'half-hour, overlapping rule fragments and explicit exceptions round-trip',
    () {
      final cases = [
        (
          'Australia/Lord_Howe',
          DateTime.utc(2050, 7, 10, 9),
          DateTime.utc(2050, 7, 9, 22, 30),
        ),
        (
          'Africa/Cairo',
          DateTime.utc(2050, 7, 10, 9),
          DateTime.utc(2050, 7, 10, 6),
        ),
        (
          'Asia/Gaza',
          DateTime.utc(2050, 7, 10, 9),
          DateTime.utc(2050, 7, 10, 6),
        ),
        (
          'Asia/Gaza',
          DateTime.utc(2100, 7, 10, 9),
          DateTime.utc(2100, 7, 10, 6),
        ),
        (
          'America/Santiago',
          DateTime.utc(2100, 7, 10, 9),
          DateTime.utc(2100, 7, 10, 13),
        ),
      ];
      for (final (zone, wall, expected) in cases) {
        final calendar = IcsCalendar(
          events: [IcsEvent(uid: 'zone', start: IcsDateTime.zoned(wall, zone))],
        );
        final restored = IcsCalendar.parse(
          calendar.encode(timestamp: DateTime.utc(2026)),
        );
        for (final source in [calendar, restored]) {
          final instances = expandIcsCalendar(
            source,
            windowStart: expected.subtract(const Duration(days: 1)),
            windowEnd: expected.add(const Duration(days: 1)),
          );
          expect(instances.single.start, expected, reason: zone);
        }
      }
    },
  );

  test('a supplied clock overrides IANA and its raw block is preserved', () {
    const block =
        'begin:vtimezone\r\nTZID:Europe/London\n'
        'BEGIN:STANDARD\r\nCOMMENT:Custom time-zone café;\r\n\t folded\r\n'
        'TZOFFSETFROM:+0315\r\nDTSTART:20000101T000000\r\n'
        'TZOFFSETTO:+0315\r\nEND:STANDARD\r\nend:vtimezone\r\n';
    final input = utf8.encode(
      _document(block, 'Europe/London', '20500701T090000'),
    );
    final calendar = IcsCalendar.parseBytes(input);
    final range = expandIcsCalendar(
      calendar,
      windowStart: DateTime.utc(2050, 7),
      windowEnd: DateTime.utc(2050, 7, 2),
    );
    expect(range.single.start, DateTime.utc(2050, 7, 1, 5, 45));
    final filtered = calendar.withEvents(calendar.events.take(1));
    expect(filtered.encode(timestamp: DateTime.utc(2050)), contains(block));
  });

  test('private recurring clock handles UTC UNTIL and a later RDATE', () {
    const zone = '/Example/Town';
    const block =
        'BEGIN:VTIMEZONE\r\nTZID:$zone\r\n'
        'BEGIN:STANDARD\r\nDTSTART:20250101T000000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+0000\r\nEND:STANDARD\r\n'
        'BEGIN:DAYLIGHT\r\nDTSTART:20250330T010000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+0100\r\n'
        'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3;UNTIL=20270328T010000Z\r\n'
        'RDATE:20300331T010000\r\nEND:DAYLIGHT\r\n'
        'BEGIN:STANDARD\r\nDTSTART:20251026T020000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0000\r\n'
        'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10;COUNT=3\r\n'
        'RDATE:20301027T020000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n';
    final expected = {2026: 8, 2027: 8, 2028: 9, 2030: 8, 2031: 9};
    for (final MapEntry(key: year, value: hour) in expected.entries) {
      final calendar = IcsCalendar.parse(
        _document(block, zone, '${year}0701T090000'),
      );
      final matches = expandIcsCalendar(
        calendar,
        windowStart: DateTime.utc(year, 7),
        windowEnd: DateTime.utc(year, 7, 2),
      );
      expect(matches.single.start, DateTime.utc(year, 7, 1, hour));
    }
  });

  test('conflicting or unsupported private definitions fail explicitly', () {
    const zone = 'Private/Clock';
    const valid =
        'BEGIN:VTIMEZONE\r\nTZID:$zone\r\nBEGIN:STANDARD\r\n'
        'DTSTART:20000101T000000\r\nTZOFFSETFROM:+0000\r\nTZOFFSETTO:+0000\r\n'
        'END:STANDARD\r\nEND:VTIMEZONE\r\n';
    for (final block in [
      valid + valid,
      valid.replaceFirst('+0000', '+1261'),
      valid.replaceFirst('END:STANDARD', 'RRULE:FREQ=SECONDLY\r\nEND:STANDARD'),
      valid.replaceFirst(
        'END:STANDARD',
        'EXDATE:20000101T000000\r\nEND:STANDARD',
      ),
    ]) {
      final calendar = IcsCalendar.parse(
        _document(block, zone, '20260701T090000'),
      );
      expect(
        () => expandIcsCalendar(
          calendar,
          windowStart: DateTime.utc(2026, 7),
          windowEnd: DateTime.utc(2026, 7, 2),
        ),
        throwsA(isA<IcsExpansionException>()),
      );
    }
  });

  test('oversize, nested and seeded malformed input stay bounded', () {
    expect(
      () => IcsCalendar.parseBytes(Uint8List(IcsCalendar.maxImportBytes + 1)),
      throwsFormatException,
    );
    final nested = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      ...List.filled(33, 'BEGIN:X-NESTED'),
      ...List.filled(33, 'END:X-NESTED'),
      'END:VCALENDAR',
      '',
    ].join('\r\n');
    expect(() => IcsCalendar.parse(nested), throwsFormatException);

    final random = Random(642197);
    final valid = utf8.encode(
      _document('', 'Europe/Lisbon', '20260328T090000'),
    );
    var rejected = 0;
    for (var attempt = 0; attempt < 600; attempt++) {
      final bytes = Uint8List.fromList(valid);
      for (var mutation = 0; mutation <= attempt % 5; mutation++) {
        bytes[random.nextInt(bytes.length)] = random.nextInt(256);
      }
      try {
        final calendar = IcsCalendar.parseBytes(bytes);
        expandIcsCalendar(
          calendar,
          windowStart: DateTime.utc(2026),
          windowEnd: DateTime.utc(2027),
        );
      } on FormatException {
        rejected++;
      } on IcsExpansionException {
        rejected++;
      }
    }
    expect(rejected, greaterThan(400));
  });
}

String _document(String zones, String zone, String wall) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${zones}BEGIN:VEVENT\r\nUID:isolated\r\n'
    'DTSTART;TZID=$zone:$wall\r\nSUMMARY:Fixture\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
