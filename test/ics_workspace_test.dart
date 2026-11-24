import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/ics_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final original = WorkspaceIcsCalendar(
    id: 'first-import',
    name: 'Training',
    document: [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Easy//Test//EN',
      'BEGIN:VEVENT',
      'UID:imported-series',
      'DTSTAMP:20261101T000000Z',
      'DTSTART;TZID=Europe/London:20261124T180000',
      'DTEND;TZID=Europe/London:20261124T190000',
      'RRULE:FREQ=WEEKLY;COUNT=3',
      'SUMMARY:Strength session',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n'),
  );

  test('retains source recurrence and produces consistent occurrence IDs', () {
    final restored = WorkspaceIcsCalendar.decodeList([original.toJson()])
        .single;
    final whole = expandWorkspaceIcs((
      calendars: [restored],
      start: DateTime(2026, 11, 24),
      end: DateTime(2026, 12, 10),
    ));
    expect(whole.length, 3);
    final oneWeek = expandWorkspaceIcs((
      calendars: [restored],
      start: DateTime(2026, 12, 1),
      end: DateTime(2026, 12, 3),
    )).single;
    expect(oneWeek.calendar, original.identity);
    expect(oneWeek.event.id, whole[1].event.id);
    expect(oneWeek.event.isReadOnly, isTrue);
    expect(oneWeek.event.sourceLabel, 'Training');
    expect(oneWeek.event.start.toUtc(), DateTime.utc(2026, 12, 1, 18));
    expect(oneWeek.status, CalendarEventStatus.unknown);
    expect(restored.document, contains('RRULE:FREQ=WEEKLY;COUNT=3'));
  });

  test('status follows each occurrence in a private time zone', () {
    const zone = '/Example/Status';
    final calendar = WorkspaceIcsCalendar(
      id: 'private-status',
      name: 'Private calendar',
      document: [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//Easy//Test//EN',
        'BEGIN:VTIMEZONE',
        'TZID:$zone',
        'BEGIN:STANDARD',
        'DTSTART:19900101T000000',
        'TZOFFSETFROM:+0315',
        'TZOFFSETTO:+0315',
        'END:STANDARD',
        'END:VTIMEZONE',
        'BEGIN:VEVENT',
        'UID:private-series',
        'DTSTAMP:20261101T000000Z',
        'DTSTART;TZID=$zone:20261124T090000',
        'DTEND;TZID=$zone:20261124T100000',
        'RRULE:FREQ=DAILY;COUNT=5',
        'STATUS:CONFIRMED',
        'SUMMARY:Original',
        'END:VEVENT',
        for (final (day, status) in [
          (25, 'TENTATIVE'),
          (26, null),
          (27, 'CANCELLED'),
        ]) ...[
          'BEGIN:VEVENT',
          'UID:private-series',
          'DTSTAMP:20261102T000000Z',
          'RECURRENCE-ID;TZID=$zone:202611${day}T090000',
          'DTSTART;TZID=$zone:202611${day}T110000',
          'DTEND;TZID=$zone:202611${day}T120000',
          if (status != null) 'STATUS:$status',
          'SUMMARY:Moved',
          'END:VEVENT',
        ],
        'END:VCALENDAR',
      ].join('\r\n'),
    );
    final restored = WorkspaceIcsCalendar.decodeList([calendar.toJson()])
        .single;
    expect(restored.document, calendar.document);

    final rows = expandWorkspaceIcs((
      calendars: [restored],
      start: DateTime.utc(2026, 11, 24),
      end: DateTime.utc(2026, 11, 29),
    ));
    expect(rows.map((row) => row.status), [
      CalendarEventStatus.confirmed,
      CalendarEventStatus.tentative,
      CalendarEventStatus.unknown,
      CalendarEventStatus.confirmed,
    ]);
    expect(rows.map((row) => row.event.start.toUtc()), [
      DateTime.utc(2026, 11, 24, 5, 45),
      DateTime.utc(2026, 11, 25, 7, 45),
      DateTime.utc(2026, 11, 26, 7, 45),
      DateTime.utc(2026, 11, 28, 5, 45),
    ]);
    expect(rows.map((row) => row.event.id).toSet(), hasLength(4));
    expect(rows.map((row) => row.event.isReadOnly), everyElement(isTrue));
    expect(rows.map((row) => row.calendar), everyElement(restored.identity));

    final tentative = expandWorkspaceIcs((
      calendars: [restored],
      start: DateTime.utc(2026, 11, 25),
      end: DateTime.utc(2026, 11, 26),
    )).single;
    expect(tentative.event.id, rows[1].event.id);
    expect(tentative.status, CalendarEventStatus.tentative);
  });

  test('rejects duplicate saved source IDs and oversized imported data', () {
    expect(
      () => WorkspaceIcsCalendar.decodeList([
        original.toJson(),
        original.toJson(),
      ]),
      throwsFormatException,
    );
    expect(
      () => WorkspaceIcsCalendar(
        id: 'large',
        name: 'Large',
        document: 'x' * (WorkspaceIcsCalendar.importByteLimit + 1),
      ),
      throwsFormatException,
    );
  });
}
