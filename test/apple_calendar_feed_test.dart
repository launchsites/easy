import 'dart:async';

import 'package:easy/calendar_sources/apple_calendar_feed.dart';
import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/event_kit_calendar_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = CalendarIdentity(accountId: 'apple-account', calendarId: 'a');
const _second = CalendarIdentity(accountId: 'apple-account', calendarId: 'b');
final _day = DateTime(2026, 11, 24);

void main() {
  test('no chosen calendar performs no native calls', () async {
    final adapter = _Adapter();
    final feed = AppleCalendarFeed(adapter: adapter);
    addTearDown(feed.dispose);
    await feed.refresh(day: _day, selected: {});
    expect(adapter.accessCalls, 0);
    expect(adapter.queries, isEmpty);
    expect(feed.events, isEmpty);
  });

  test(
    'uses only selected calendars, deduplicates, and clears on removal',
    () async {
      final adapter = _Adapter();
      final feed = AppleCalendarFeed(adapter: adapter);
      addTearDown(feed.dispose);
      await feed.refresh(day: _day, selected: {_first});
      expect(adapter.queries, [
        {_first},
      ]);
      expect(feed.events.map((it) => it.id.calendar), [_first]);
      expect(feed.covers(_day), isTrue);
      await feed.refresh(day: _day, selected: {});
      expect(feed.events, isEmpty);
      expect(feed.sources, isEmpty);
      expect(feed.covers(_day), isFalse);
    },
  );

  test('a stale permission response cannot read a newer selection', () async {
    final adapter = _Adapter();
    final feed = AppleCalendarFeed(adapter: adapter);
    addTearDown(feed.dispose);
    final delayed = Completer<EventKitCalendarAccess>();
    adapter.nextAccess = delayed;
    final obsolete = feed.refresh(day: _day, selected: {_first});
    await feed.refresh(day: _day, selected: {_second});
    delayed.complete(EventKitCalendarAccess.full);
    await obsolete;
    expect(adapter.queries, [
      {_second},
    ]);
    expect(feed.events.map((it) => it.id.calendar), [_second]);
  });

  test(
    'missing selected calendars and denied permissions are reported',
    () async {
      final adapter = _Adapter();
      final feed = AppleCalendarFeed(adapter: adapter);
      addTearDown(feed.dispose);
      adapter.sources = [_first];
      await feed.refresh(day: _day, selected: {_first, _second});
      expect(feed.problem, 'Some Apple calendars are unavailable.');
      expect(feed.events.map((it) => it.id.calendar), [_first]);

      adapter.access = EventKitCalendarAccess.denied;
      adapter.queries.clear();
      await feed.refresh(day: _day, selected: {_first, _second}, force: true);
      expect(feed.problem, 'Review Apple Calendar access in Settings.');
      expect(adapter.queries, isEmpty);
      expect(feed.events, isEmpty);
      expect(feed.covers(_day), isFalse);
    },
  );
}

class _Adapter extends EventKitCalendarAdapter {
  Completer<EventKitCalendarAccess>? nextAccess;
  EventKitCalendarAccess access = EventKitCalendarAccess.full;
  List<CalendarIdentity> sources = [_first, _second];
  final queries = <Set<CalendarIdentity>>[];
  var accessCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<EventKitCalendarAccess> accessStatus() async {
    accessCalls++;
    final requested = nextAccess;
    nextAccess = null;
    return requested == null ? access : await requested.future;
  }

  @override
  Future<EventKitCalendarAccess> requestReadAccess() async =>
      throw StateError('A feed must never request permission.');

  @override
  Future<List<CalendarSource>> calendars() async => [
    for (final calendar in sources)
      CalendarSource(
        id: calendar,
        name: calendar.calendarId,
        accountName: 'Test',
      ),
  ];

  @override
  Future<List<SourcedCalendarEvent<ExternalCalendarEvent>>> events({
    required DateTime start,
    required DateTime end,
    Iterable<CalendarIdentity>? calendars,
  }) async {
    final query = calendars!.toSet();
    queries.add(query);
    return [
      for (final calendar in [_first, _second, _first, _second])
        SourcedCalendarEvent(
          id: CalendarOccurrenceIdentity(calendar: calendar, eventId: 'test'),
          event: ExternalCalendarEvent(
            title: 'Meeting',
            start: _day,
            end: _day.add(const Duration(hours: 1)),
            allDay: false,
          ),
        ),
    ];
  }

  @override
  Stream<void> get changes => const Stream.empty();
}
