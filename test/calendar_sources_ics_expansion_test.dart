import 'dart:math' as math;

import 'package:easy/calendar_sources/ics_calendar.dart';
import 'package:easy/calendar_sources/ics_import_export.dart';
import 'package:easy/calendar_sources/ics_occurrence_expander.dart';
import 'package:flutter_test/flutter_test.dart';

IcsDateTime _utc(
  int year,
  int month,
  int day, [
  int hour = 9,
  int minute = 0,
]) => IcsDateTime.utc(DateTime.utc(year, month, day, hour, minute));

IcsDateTime _named(
  String zone,
  int year,
  int month,
  int day,
  int hour, [
  int minute = 0,
]) => IcsDateTime.zoned(DateTime.utc(year, month, day, hour, minute), zone);

IcsCalendar _calendar(Iterable<IcsEvent> events) => IcsCalendar(events: events);

List<IcsOccurrence> _expand(
  IcsCalendar calendar,
  DateTime start,
  DateTime end, {
  String? zone,
  int limit = 10000,
}) => expandIcsCalendar(
  calendar,
  windowStart: start,
  windowEnd: end,
  floatingTimeZone: zone,
  limit: limit,
);

void main() {
  test(
    'includes and deduplicates RDATE while applying EXDATE and detached edits',
    () {
      final calendar = _calendar([
        IcsEvent(
          uid: 'series',
          summary: 'Schedule',
          start: _utc(2026, 11, 23),
          end: _utc(2026, 11, 23, 10),
          recurrenceRule: 'FREQ=DAILY;INTERVAL=2;COUNT=4',
          recurrenceDates: [_utc(2026, 11, 24), _utc(2026, 11, 29)],
          exceptionDates: [_utc(2026, 11, 25)],
        ),
        IcsEvent(
          uid: 'series',
          start: _utc(2026, 11, 28, 15),
          end: _utc(2026, 11, 28, 16),
          recurrenceId: _utc(2026, 11, 27),
          summary: 'Moved',
        ),
      ]);
      final occurrences = _expand(
        calendar,
        DateTime.utc(2026, 11, 22),
        DateTime.utc(2026, 12),
      );
      expect(occurrences.map((item) => item.start), [
        DateTime.utc(2026, 11, 23, 9),
        DateTime.utc(2026, 11, 24, 9),
        DateTime.utc(2026, 11, 28, 15),
        DateTime.utc(2026, 11, 29, 9),
      ]);
      expect(occurrences[2].sourceIndex, 1);
      expect(occurrences[2].sourceUid, 'series');
      expect(occurrences[2].recurrenceId, _utc(2026, 11, 27));
      expect(occurrences[2].event.summary, 'Moved');
    },
  );

  test('moves detached events into a window even if their original date is elsewhere', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'series',
        start: _utc(2026, 11, 23),
        recurrenceRule: 'FREQ=DAILY;COUNT=4',
      ),
      IcsEvent(
        uid: 'series',
        start: _utc(2027, 1, 10),
        recurrenceId: _utc(2026, 11, 24),
      ),
    ]);
    final moved = _expand(
      calendar,
      DateTime.utc(2027, 1, 10),
      DateTime.utc(2027, 1, 11),
    ).single;
    expect(moved.sourceIndex, 1);
    expect(moved.recurrenceId, _utc(2026, 11, 24));
    expect(moved.start, DateTime.utc(2027, 1, 10, 9));
  });

  test('cancellation without DTSTART removes the original recurrence', () {
    final calendar = IcsCalendar.parse(
      [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'BEGIN:VEVENT',
        'UID:s',
        'DTSTART:20261123T090000Z',
        'RRULE:FREQ=DAILY;COUNT=3',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:s',
        'RECURRENCE-ID:20261124T090000Z',
        'STATUS:CANCELLED',
        'END:VEVENT',
        'END:VCALENDAR',
        '',
      ].join('\r\n'),
    );
    final items = _expand(
      calendar,
      DateTime.utc(2026, 11, 23),
      DateTime.utc(2026, 11, 27),
    );
    expect(items.map((item) => item.start.day), [23, 25]);
    expect(calendar.encode(), contains('STATUS:CANCELLED\r\n'));
  });

  test('period RDATE supplies its own exact duration', () {
    final calendar = IcsCalendar.parse(
      [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'BEGIN:VEVENT',
        'UID:p',
        'DTSTART:20261123T090000Z',
        'DURATION:PT1H',
        'RDATE;VALUE=PERIOD:20261124T090000Z/PT2H,20261125T090000Z/20261125T113000Z',
        'END:VEVENT',
        'END:VCALENDAR',
        '',
      ].join('\r\n'),
    );
    expect(calendar.events.single.recurrencePeriods, hasLength(2));
    final items = _expand(
      calendar,
      DateTime.utc(2026, 11, 23),
      DateTime.utc(2026, 11, 27),
    );
    expect(items.map((item) => item.end.difference(item.start).inMinutes), [
      60,
      120,
      150,
    ]);
  });

  test('weekly periods honor WKST, multiple days and interval', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'w',
        start: _utc(2026, 11, 22),
        recurrenceRule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU;COUNT=4',
      ),
    ]);
    final events = _expand(
      calendar,
      DateTime.utc(2026, 11, 21),
      DateTime.utc(2026, 12, 20),
    );
    expect(events.map((item) => item.start), [
      DateTime.utc(2026, 11, 22, 9),
      DateTime.utc(2026, 11, 23, 9),
      DateTime.utc(2026, 12, 6, 9),
      DateTime.utc(2026, 12, 7, 9),
    ]);
  });

  test('monthly positioning and invalid dates follow calendar months', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'last-weekday',
        start: _utc(2026, 1, 30),
        recurrenceRule: 'FREQ=MONTHLY;COUNT=3;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1',
      ),
      IcsEvent(
        uid: 'first-monday',
        start: _utc(2026, 1, 5),
        recurrenceRule: 'FREQ=MONTHLY;COUNT=3;BYDAY=1MO',
      ),
      IcsEvent(
        uid: 'end',
        start: _utc(2026, 1, 31),
        recurrenceRule: 'FREQ=MONTHLY;COUNT=3',
      ),
    ]);
    final items = _expand(
      calendar,
      DateTime.utc(2026),
      DateTime.utc(2026, 6, 2),
    );
    List<(int, int)> dates(String uid) => [
      for (final item in items.where((value) => value.sourceUid == uid))
        (item.start.month, item.start.day),
    ];
    expect(dates('last-weekday'), [(1, 30), (2, 27), (3, 31)]);
    expect(dates('first-monday'), [(1, 5), (2, 2), (3, 2)]);
    expect(dates('end'), [(1, 31), (3, 31), (5, 31)]);
  });

  test('a yearly leap-day event skips invalid years without using COUNT', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'leap',
        start: IcsDateTime.date(DateTime(2024, 2, 29)),
        recurrenceRule: 'FREQ=YEARLY;COUNT=3',
      ),
    ]);
    for (final year in [2024, 2028, 2032]) {
      final event = _expand(
        calendar,
        DateTime.utc(year),
        DateTime.utc(year + 1),
      ).single;
      expect(event.start, DateTime(year, 2, 29));
      expect(event.end, DateTime(year, 3));
      expect(event.allDay, isTrue);
    }
    expect(_expand(calendar, DateTime.utc(2036), DateTime.utc(2037)), isEmpty);
  });

  test(
    'weekly periods and exclusive all-day ends handle RFC year boundaries',
    () {
      final historical = _calendar([
        IcsEvent(
          uid: 'historical',
          start: _utc(1, 1, 1),
          recurrenceRule: 'FREQ=WEEKLY;WKST=SU;BYDAY=SU,MO;COUNT=3',
        ),
      ]);
      expect(
        _expand(
          historical,
          DateTime.utc(1),
          DateTime.utc(1, 1, 20),
        ).map((item) => item.start.day),
        [1, 7, 8],
      );
      final later = _calendar([
        IcsEvent(
          uid: 'later',
          start: IcsDateTime.date(DateTime.utc(9999, 12, 30)),
          recurrenceRule: 'FREQ=DAILY;COUNT=2',
        ),
      ]);
      final event = _expand(
        later,
        DateTime.utc(9999, 12, 31),
        DateTime.utc(10000),
        zone: 'UTC',
      ).single;
      expect(event.start, DateTime(9999, 12, 31));
      expect(event.end, DateTime(10000));
    },
  );

  test('UNTIL is inclusive and the occurrence window is half-open', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'u',
        start: _utc(2026, 11, 23),
        end: _utc(2026, 11, 23, 10),
        recurrenceRule: 'FREQ=DAILY;UNTIL=20261125T090000Z',
      ),
    ]);
    final events = _expand(
      calendar,
      DateTime.utc(2026, 11, 23, 10),
      DateTime.utc(2026, 11, 26),
    );
    expect(events.map((item) => item.start.day), [24, 25]);
    expect(
      _expand(
        calendar,
        DateTime.utc(2026, 11, 24, 9, 30),
        DateTime.utc(2026, 11, 25, 9),
      ).single.start.day,
      24,
    );
  });

  test('the DST gap is skipped and the repeated wall time selects the first instant', () {
    const zone = 'America/New_York';
    final calendar = _calendar([
      IcsEvent(
        uid: 'gap',
        start: _named(zone, 2026, 3, 7, 2, 30),
        recurrenceRule: 'FREQ=DAILY;COUNT=3',
      ),
      IcsEvent(uid: 'fold', start: _named(zone, 2026, 11, 1, 1, 30)),
    ]);
    final spring = _expand(
      calendar,
      DateTime.utc(2026, 3, 7),
      DateTime.utc(2026, 3, 12),
    );
    expect(spring.map((item) => item.start), [
      DateTime.utc(2026, 3, 7, 7, 30),
      DateTime.utc(2026, 3, 9, 6, 30),
      DateTime.utc(2026, 3, 10, 6, 30),
    ]);
    final autumn = _expand(
      calendar,
      DateTime.utc(2026, 11, 1),
      DateTime.utc(2026, 11, 2),
    ).single;
    expect(autumn.start, DateTime.utc(2026, 11, 1, 5, 30));
  });

  test('nominal day duration and explicit end duration differ across DST', () {
    const zone = 'America/New_York';
    final start = _named(zone, 2026, 3, 7, 12);
    final calendar = _calendar([
      IcsEvent(
        uid: 'nominal',
        start: start,
        duration: 'P1D',
        recurrenceRule: 'FREQ=DAILY;COUNT=2',
      ),
      IcsEvent(
        uid: 'exact',
        start: start,
        end: _named(zone, 2026, 3, 8, 12),
        recurrenceRule: 'FREQ=DAILY;COUNT=2',
      ),
    ]);
    final events = _expand(
      calendar,
      DateTime.utc(2026, 3, 7),
      DateTime.utc(2026, 3, 10),
    );
    List<int> durations(String uid) => [
      for (final item in events.where((value) => value.sourceUid == uid))
        item.end.difference(item.start).inHours,
    ];
    expect(durations('nominal'), [23, 24]);
    expect(durations('exact'), [23, 23]);
  });

  test('floating times use the display zone and all-day bounds stay civil', () {
    final calendar = _calendar([
      IcsEvent(
        uid: 'float',
        start: IcsDateTime.floating(DateTime(2026, 3, 29, 9)),
      ),
      IcsEvent(
        uid: 'whole',
        start: IcsDateTime.date(DateTime(2026, 3, 29)),
        duration: 'P2D',
      ),
    ]);
    final events = _expand(
      calendar,
      DateTime.utc(2026, 3, 28, 20),
      DateTime.utc(2026, 3, 29, 23),
      zone: 'Europe/London',
    );
    expect(events.first.allDay, isTrue);
    expect(events.first.start, DateTime(2026, 3, 29));
    expect(events.first.end, DateTime(2026, 3, 31));
    expect(events.last.start, DateTime.utc(2026, 3, 29, 8));
  });

  test('unknown zones and unsupported expansion rules fail explicitly', () {
    final start = _utc(2026, 11, 24);
    final startWindow = DateTime.utc(2026, 11, 24);
    final endWindow = DateTime.utc(2026, 12);
    final invalid = [
      IcsEvent(uid: 'a', start: _named('Unlisted/Zone', 2026, 11, 24, 9)),
      IcsEvent(uid: 'b', start: start, recurrenceRule: 'FREQ=HOURLY'),
      IcsEvent(uid: 'c', start: start, recurrenceRule: 'FREQ=DAILY;BYHOUR=9'),
      IcsEvent(
        uid: 'd',
        start: start,
        recurrenceRule: 'FREQ=DAILY;UNTIL=20261129',
      ),
      IcsEvent(
        uid: 'e',
        start: start,
        recurrenceId: start,
        recurrenceRange: 'THISANDFUTURE',
      ),
    ];
    for (final event in invalid) {
      expect(
        () => _expand(_calendar([event]), startWindow, endWindow),
        throwsA(isA<IcsExpansionException>()),
        reason: event.uid,
      );
    }
    expect(
      () => _expand(_calendar([]), startWindow, DateTime.utc(2028)),
      throwsArgumentError,
    );
    expect(
      () => _expand(
        _calendar([
          IcsEvent(uid: 'b', start: start, recurrenceRule: 'FREQ=DAILY'),
        ]),
        startWindow,
        endWindow,
        limit: 2,
      ),
      throwsA(isA<IcsExpansionException>()),
    );
  });

  test('far-future uncounted queries seek and historical counted rules honor a budget', () {
    final start = _utc(1, 1, 1);
    final steady = _calendar([
      IcsEvent(uid: 'steady', start: start, recurrenceRule: 'FREQ=DAILY'),
    ]);
    final future = _expand(
      steady,
      DateTime.utc(2026, 11, 24),
      DateTime.utc(2026, 11, 26),
    );
    expect(future.map((item) => item.start.day), [24, 25]);
    final hugeCount = _calendar([
      IcsEvent(
        uid: 'counted',
        start: start,
        recurrenceRule: 'FREQ=DAILY;COUNT=1000000',
      ),
    ]);
    expect(
      () => _expand(
        hugeCount,
        DateTime.utc(2026, 11, 24),
        DateTime.utc(2026, 11, 26),
      ),
      throwsA(isA<IcsExpansionException>()),
    );
  });

  test('seeded daily rules match a simple civil calendar across windows', () {
    final random = math.Random(20261124);
    final base = DateTime.utc(2024, 1, 5, 9);
    const codes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    for (var scenario = 0; scenario < 80; scenario++) {
      final interval = 1 + random.nextInt(7);
      final count = 1 + random.nextInt(15);
      final days = {base.weekday, 1 + random.nextInt(7), 1 + random.nextInt(7)};
      final byDay = days.map((day) => codes[day - 1]).join(',');
      final windowStart = base.add(Duration(days: random.nextInt(60)));
      final windowEnd = windowStart.add(Duration(days: 1 + random.nextInt(60)));
      final rule = 'FREQ=DAILY;INTERVAL=$interval;COUNT=$count;BYDAY=$byDay';
      final calendar = _calendar([
        IcsEvent(
          uid: 'scenario-$scenario',
          start: IcsDateTime.utc(base),
          recurrenceRule: rule,
        ),
      ]);
      final starts = <DateTime>[];
      for (var offset = 0; starts.length < count && offset < 1000; offset++) {
        final date = base.add(Duration(days: offset));
        if (offset % interval == 0 && days.contains(date.weekday)) {
          starts.add(date);
        }
      }
      expect(
        _expand(calendar, windowStart, windowEnd).map((item) => item.start),
        starts.where(
          (date) => !date.isBefore(windowStart) && date.isBefore(windowEnd),
        ),
        reason: '$rule window $windowStart to $windowEnd',
      );
    }
  });

  test(
    'import preview preserves duplicate UIDs and isolates different imports',
    () {
      final calendar = _calendar([
        IcsEvent(uid: 'same UID', start: _utc(2026, 11, 24), summary: 'First'),
        IcsEvent(uid: 'same UID', start: _utc(2026, 11, 24), summary: 'Second'),
      ]);
      IcsImportPreview preview(String importId) => previewIcsImport(
        calendar,
        importId: importId,
        windowStart: DateTime.utc(2026, 11, 24),
        windowEnd: DateTime.utc(2026, 11, 25),
      );
      final first = preview('import/a');
      final second = preview('import/b');
      expect(first.items.map((item) => item.sourceUid), [
        'same UID',
        'same UID',
      ]);
      expect(first.items.map((item) => item.occurrence.event.summary), [
        'First',
        'Second',
      ]);
      expect(
        first.items
            .map((item) => item.localId)
            .toSet()
            .intersection(second.items.map((item) => item.localId).toSet()),
        isEmpty,
      );
      expect(
        first.items.map((item) => item.localId),
        preview('import/a').items.map((item) => item.localId),
      );
      expect(first.calendar, same(calendar));
    },
  );

  test(
    'workspace export distinguishes zero-length instants and all-day intervals',
    () {
      final calendar = exportIcsRecords([
        IcsExportRecord(
          uid: 'instant',
          title: 'Milestone',
          start: DateTime.utc(2026, 11, 24, 9),
          end: DateTime.utc(2026, 11, 24, 9),
        ),
        IcsExportRecord(
          uid: 'date',
          title: 'Holiday',
          start: DateTime(2026, 11, 25),
          end: DateTime(2026, 11, 26),
          allDay: true,
        ),
      ], name: 'Workspace');
      final decoded = IcsCalendar.parse(
        calendar.encode(timestamp: DateTime.utc(2026, 11, 23)),
      );
      expect(decoded.name, 'Workspace');
      expect(
        decoded.events.first.start.utcInstant,
        DateTime.utc(2026, 11, 24, 9),
      );
      expect(decoded.events.first.end, isNull);
      expect(
        decoded.events.last.start,
        IcsDateTime.date(DateTime(2026, 11, 25)),
      );
      expect(decoded.events.last.end, IcsDateTime.date(DateTime(2026, 11, 26)));
    },
  );
}
