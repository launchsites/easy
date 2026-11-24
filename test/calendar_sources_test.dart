import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = CalendarIdentity(
  accountId: 'device-account-a',
  calendarId: 'personal',
);
const _second = CalendarIdentity(
  accountId: 'device-account-b',
  calendarId: 'personal',
);
const _missing = CalendarIdentity(
  accountId: 'device-account-c',
  calendarId: 'shared',
);

void main() {
  test(
    'calendar identities include account as well as the provider calendar ID',
    () {
      expect(_first, isNot(_second));
      expect(CalendarIdentity.fromJson(_first.toJson()), _first);
      expect({_first, _second}, hasLength(2));
    },
  );

  test(
    'modes retain shared and unavailable source memberships independently',
    () {
      final ids = [_first, _missing];
      final memberships = CalendarModeMemberships({
        'study': ids,
        'work': [_first, _second],
      });
      ids.clear();
      final updated = memberships.withCalendars('study', [_second]);
      expect(memberships.forMode('study'), {_first, _missing});
      expect(memberships.forMode('work'), {_first, _second});
      expect(updated.forMode('study'), {_second});
      expect(updated.forMode('work'), {_first, _second});
      expect(
        CalendarModeMemberships.fromJson(memberships.toJson()).byMode,
        memberships.byMode,
      );
      expect(
        () => memberships.forMode('study').clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('All deduplicates identical occurrences across modes', () {
    final directory = CalendarDirectory(
      sources: [
        CalendarSource(id: _first, name: 'Personal', accountName: 'Account A'),
        CalendarSource(id: _second, name: 'Personal', accountName: 'Account B'),
      ],
      memberships: CalendarModeMemberships({
        'study': [_first, _missing],
        'work': [_first, _second],
      }),
    );
    SourcedCalendarEvent<String> event(
      CalendarIdentity source,
      String day,
      String title,
    ) => SourcedCalendarEvent(
      id: CalendarOccurrenceIdentity(
        calendar: source,
        eventId: 'provider-event-id',
        recurrenceId: day,
      ),
      event: title,
    );
    final shared = event(_first, '2026-11-24', 'shared occurrence');
    final copiedInput = event(_first, '2026-11-24', 'same identity');
    final next = event(_first, '2026-12-01', 'next occurrence');
    final otherAccount = event(_second, '2026-11-24', 'other account');
    final absent = event(_missing, '2026-11-24', 'unavailable source');
    final events = [shared, copiedInput, next, otherAccount, absent];
    expect(directory.visibleEvents(events, modeId: 'study'), [shared, next]);
    expect(directory.visibleEvents(events, modeId: 'work'), [
      shared,
      next,
      otherAccount,
    ]);
    expect(directory.visibleEvents(events), [shared, next, otherAccount]);
    expect(directory.visibleEvents(events, modeId: 'unknown'), isEmpty);
  });

  test('resolves writes only for an explicitly selected writable calendar', () {
    final readOnly = CalendarSource(
      id: _first,
      name: 'Read only',
      accountName: 'Account A',
    );
    final capabilities = {CalendarCapability.write};
    final writable = CalendarSource(
      id: _second,
      name: 'Write only',
      accountName: 'Account B',
      capabilities: capabilities,
    );
    capabilities.clear();
    final directory = CalendarDirectory(sources: [readOnly, writable]);
    expect(directory.readableSources(), [readOnly]);
    expect(directory.writableSources(), [writable]);
    expect(
      directory.resolveWriteDestination(null).status,
      CalendarWriteStatus.chooseCalendar,
    );
    expect(
      directory.resolveWriteDestination(_missing).status,
      CalendarWriteStatus.unavailable,
    );
    expect(
      directory.resolveWriteDestination(_first).status,
      CalendarWriteStatus.readOnly,
    );
    final ready = directory.resolveWriteDestination(_second);
    expect(ready.status, CalendarWriteStatus.ready);
    expect(ready.source, same(writable));
    expect(() => writable.capabilities.clear(), throwsUnsupportedError);
  });
}
