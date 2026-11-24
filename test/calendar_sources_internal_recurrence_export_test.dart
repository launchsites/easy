import 'dart:convert';

import 'package:easy/calendar_sources/ics_calendar.dart';
import 'package:easy/calendar_sources/ics_import_export.dart';
import 'package:easy/calendar_sources/ics_occurrence_expander.dart';
import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'active split segments keep stable independent UIDs and exact counts',
    () {
      final original = _series(_utc(23), count: 6);
      final pivot = _visible(original)[2];
      final changed = original.edit(
        pivot,
        scope: InternalOccurrenceScope.future,
        event: _utc(26, hour: 11, title: 'New schedule'),
      );
      final skipped = changed.skip(
        _visible(changed)[3],
        scope: InternalOccurrenceScope.one,
      );
      final moved = skipped.edit(
        _visible(skipped).last,
        scope: InternalOccurrenceScope.one,
        event: _utc(30, hour: 14, title: 'Moved'),
      );
      final base = exportIcsRecords([
        IcsExportRecord(
          uid: 'single',
          title: 'Standalone',
          start: DateTime.utc(2026, 11, 20),
          end: DateTime.utc(2026, 11, 20, 1),
        ),
      ], name: 'Schedule');
      final standalone = base.withEvents([
        ...base.events,
        ...moved.toIcsEvents(),
      ]);
      final parsed = IcsCalendar.parse(standalone.encode());
      expect(parsed.name, 'Schedule');
      final masters = parsed.events
          .where((event) => event.recurrenceId == null)
          .toList();
      expect(masters.map((event) => event.recurrenceRule), [
        null,
        'FREQ=DAILY;COUNT=2',
        'FREQ=DAILY;COUNT=4',
      ]);
      expect(masters.map((event) => event.uid).toSet(), hasLength(3));
      expect(masters[1].uid, original.toIcsEvents().single.uid);
      final restored = InternalRecurringEvent.fromJson(
        jsonDecode(jsonEncode(moved.toJson())) as Map<String, Object?>,
      );
      expect(
        restored.toIcsEvents().map((event) => event.uid),
        moved.toIcsEvents().map((event) => event.uid),
      );
      final detached = parsed.events
          .where((event) => event.recurrenceId != null)
          .toList();
      expect(detached, hasLength(2));
      expect(detached.map((event) => event.uid).toSet(), {masters.last.uid});
      expect(detached.first.status, 'CANCELLED');
      expect(detached.last.summary, 'Moved');
      _expectEquivalent(
        moved,
        _span(DateTime.utc(2026, 11, 21), DateTime.utc(2026, 12, 3)),
        parsed: parsed,
      );
    },
  );

  test(
    'cancelled and moved recurrence identifiers follow the active wall time',
    () {
      final original = _series(_utc(23), count: 5);
      final moved = original.edit(
        _visible(original)[1],
        scope: InternalOccurrenceScope.one,
        event: _utc(30, hour: 14, title: 'Detached'),
      );
      final omitted = moved.skip(
        _visible(moved)[1],
        scope: InternalOccurrenceScope.one,
      );
      final changed = omitted.edit(
        _visible(omitted).first,
        scope: InternalOccurrenceScope.series,
        event: _utc(23, hour: 11),
      );
      final exported = IcsCalendar.parse(
        IcsCalendar(events: changed.toIcsEvents()).encode(),
      );
      final members = exported.events
          .where((event) => event.recurrenceId != null)
          .toList();
      expect(members.map((event) => event.recurrenceId!.components), [
        DateTime.utc(2026, 11, 24, 11),
        DateTime.utc(2026, 11, 25, 11),
      ]);
      expect(exported.events.first.exceptionDates.single.components.hour, 11);
      expect(exported.events.first.recurrenceDates.single.components.hour, 11);
      _expectEquivalent(changed, _november(), parsed: exported);
    },
  );

  test(
    'floating and all-day inclusive end dates retain distinct RFC value types',
    () {
      final floating = _series(
        InternalEventDraft(
          title: 'Morning',
          category: 'personal',
          start: IcsDateTime.floating(DateTime(2026, 11, 23, 9)),
          end: IcsDateTime.floating(DateTime(2026, 11, 23, 10)),
        ),
        until: DateTime(2026, 11, 25),
      );
      final allDay = _series(
        InternalEventDraft.fromDates(
          title: 'Trip',
          category: 'personal',
          start: DateTime(2026, 11, 23),
          end: DateTime(2026, 11, 25),
          allDay: true,
        ),
        until: DateTime(2026, 11, 25),
      );
      final omitted = allDay.skip(
        _visible(allDay)[1],
        scope: InternalOccurrenceScope.one,
      );
      final floatingText = IcsCalendar(events: floating.toIcsEvents()).encode();
      final allDayText = IcsCalendar(events: omitted.toIcsEvents()).encode();
      expect(floatingText, contains('RRULE:FREQ=DAILY;UNTIL=20261125T235959'));
      expect(floatingText, isNot(contains('UNTIL=20261125T235959Z')));
      expect(allDayText, contains('RRULE:FREQ=DAILY;UNTIL=20261125'));
      expect(allDayText, contains('RECURRENCE-ID;VALUE=DATE:20261124'));
      expect(allDayText, contains('EXDATE;VALUE=DATE:20261124'));
      expect(allDayText, contains('DTEND;VALUE=DATE:20261125'));
      _expectEquivalent(floating, _november(), floatingZone: 'Europe/London');
      _expectEquivalent(omitted, _november(), floatingZone: 'Europe/London');
    },
  );

  test(
    'named clock DTSTART and recurrence IDs use TZID while UNTIL is UTC',
    () {
      final series = _series(
        _london(27, hour: 9),
        until: DateTime(2026, 3, 29),
      );
      final window = _span(DateTime.utc(2026, 3, 26), DateTime.utc(2026, 4, 1));
      final moved = series.edit(
        _visible(series, window: window)[1],
        scope: InternalOccurrenceScope.one,
        event: _london(28, hour: 13, title: 'Moved'),
      );
      final text = IcsCalendar(events: moved.toIcsEvents()).encode();
      expect(text, contains('DTSTART;TZID=Europe/London:20260327T090000'));
      expect(
        text,
        contains('RECURRENCE-ID;TZID=Europe/London:20260328T090000'),
      );
      expect(text, contains('RRULE:FREQ=DAILY;UNTIL=20260329T225959Z'));
      _expectEquivalent(moved, window);
    },
  );

  test(
    'an inclusive UTC UNTIL on a skipped civil date ends before the jump',
    () {
      final series = _series(
        InternalEventDraft(
          title: 'Apia',
          category: 'personal',
          start: IcsDateTime.zoned(DateTime(2011, 12, 29, 9), 'Pacific/Apia'),
          end: IcsDateTime.zoned(DateTime(2011, 12, 29, 10), 'Pacific/Apia'),
        ),
        until: DateTime(2011, 12, 30),
      );
      expect(
        series.toIcsEvents().single.recurrenceRule,
        'FREQ=DAILY;UNTIL=20111230T095959Z',
      );
      _expectEquivalent(
        series,
        _span(DateTime.utc(2011, 12, 28), DateTime.utc(2012, 1, 3)),
      );
    },
  );

  test('a moved row remains portable when its nominal date falls in a gap', () {
    final initial = _series(_london(27, hour: 3), count: 5);
    final range = _span(DateTime.utc(2026, 3, 26), DateTime.utc(2026, 4, 4));
    final moved = initial.edit(
      _visible(initial, window: range)[2],
      scope: InternalOccurrenceScope.one,
      event: _london(31, hour: 13, title: 'Keep moved occurrence'),
    );
    final updated = moved.edit(
      _visible(moved, window: range).first,
      scope: InternalOccurrenceScope.series,
      event: _london(27, hour: 1, minute: 30),
    );
    final items = updated.toIcsEvents();
    expect(items, hasLength(2));
    expect(items.last.recurrenceId, isNull);
    expect(items.last.uid, isNot(items.first.uid));
    _expectEquivalent(updated, range);
  });

  test(
    'future skip truncates the active master and series skip exports no master',
    () {
      final series = _series(_utc(23));
      final stopped = series.skip(
        _visible(series)[2],
        scope: InternalOccurrenceScope.future,
      );
      expect(
        stopped.toIcsEvents().single.recurrenceRule,
        'FREQ=DAILY;UNTIL=20261124T235959Z',
      );
      _expectEquivalent(stopped, _november());
      final removed = stopped.skip(
        _visible(stopped).first,
        scope: InternalOccurrenceScope.series,
      );
      expect(removed.toIcsEvents(), isEmpty);
      _expectEquivalent(removed, _november());
    },
  );

  test('an invalid master clock fails explicitly and keeps the source', () {
    final series = _series(_london(29, hour: 1, minute: 30));
    final source = series.toJson();
    expect(series.toIcsEvents, throwsA(isA<IcsExpansionException>()));
    expect(series.toJson(), source);
  });

  test('a floating gap exception cannot lose its original day on export', () {
    InternalEventDraft floating(int day, int hour, int minute) =>
        InternalEventDraft(
          title: 'Workshop',
          category: 'work',
          start: IcsDateTime.floating(DateTime.utc(2026, 3, day, hour, minute)),
          end: IcsDateTime.floating(
            DateTime.utc(2026, 3, day, hour + 1, minute),
          ),
        );
    final initial = _series(floating(27, 3, 0), count: 5);
    final range = _span(DateTime.utc(2026, 3, 26), DateTime.utc(2026, 4, 4));
    final moved = initial.edit(
      _visible(initial, window: range, floatingZone: 'Europe/London')[2],
      scope: InternalOccurrenceScope.one,
      event: floating(31, 13, 0),
    );
    final updated = moved.edit(
      _visible(moved, window: range, floatingZone: 'Europe/London').first,
      scope: InternalOccurrenceScope.series,
      event: floating(27, 1, 30),
    );
    final source = updated.toJson();
    expect(
      () => updated.toIcsEvents(floatingTimeZone: 'Europe/London'),
      throwsA(isA<IcsExpansionException>()),
    );
    expect(updated.toJson(), source);
  });
}

InternalEventDraft _utc(int day, {int hour = 9, String title = 'Workshop'}) =>
    InternalEventDraft.fromDates(
      title: title,
      category: 'work',
      start: DateTime.utc(2026, 11, day, hour),
      end: DateTime.utc(2026, 11, day, hour + 1),
    );

InternalEventDraft _london(
  int day, {
  required int hour,
  int minute = 0,
  String title = 'Workshop',
}) => InternalEventDraft(
  title: title,
  category: 'work',
  start: IcsDateTime.zoned(
    DateTime.utc(2026, 3, day, hour, minute),
    'Europe/London',
  ),
  end: IcsDateTime.zoned(
    DateTime.utc(2026, 3, day, hour + 1, minute),
    'Europe/London',
  ),
);

InternalRecurringEvent _series(
  InternalEventDraft draft, {
  int? count,
  DateTime? until,
}) => InternalRecurringEvent(
  id: 'sample/series',
  event: draft,
  rule: InternalRecurrenceRule(
    frequency: InternalRecurrenceFrequency.daily,
    count: count,
    until: until,
  ),
);

typedef _Window = ({DateTime start, DateTime end});

_Window _span(DateTime start, DateTime end) => (start: start, end: end);
_Window _november() =>
    _span(DateTime.utc(2026, 11, 22), DateTime.utc(2026, 12, 5));

List<InternalEventOccurrence> _visible(
  InternalRecurringEvent series, {
  _Window? window,
  String? floatingZone,
}) {
  final range = window ?? _november();
  return series.occurrences(
    windowStart: range.start,
    windowEnd: range.end,
    floatingTimeZone: floatingZone,
  );
}

void _expectEquivalent(
  InternalRecurringEvent series,
  _Window window, {
  IcsCalendar? parsed,
  String? floatingZone,
}) {
  final document =
      parsed ??
      IcsCalendar.parse(
        IcsCalendar(events: series.toIcsEvents(floatingTimeZone: floatingZone))
            .encode(),
      );
  final import = previewIcsImport(
    document,
    importId: 'export-test',
    windowStart: window.start,
    windowEnd: window.end,
    floatingTimeZone: floatingZone,
  );
  final actual = [
    for (final row in import.items)
      (
        row.occurrence.event.summary,
        row.occurrence.start,
        row.occurrence.end,
        row.occurrence.allDay,
      ),
  ];
  final source = _visible(
    series,
    window: window,
    floatingZone: floatingZone,
  ).map((item) => (item.event.title, item.start, item.end, item.allDay));
  expect(actual, unorderedEquals(source));
}
