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
    expect(restored.document, contains('RRULE:FREQ=WEEKLY;COUNT=3'));
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
