import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easy/event_kit_calendar');
  const adapter = EventKitCalendarAdapter(platform: TargetPlatform.iOS);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const source = CalendarIdentity(
    accountId: 'account-a',
    calendarId: 'calendar-a',
  );
  final start = DateTime.utc(2026, 11, 24);
  final end = DateTime.utc(2026, 11, 26);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'only the explicit permission method requests calendar access',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'accessStatus' => 'unknown',
          'requestReadAccess' => 'full',
          _ => throw MissingPluginException(),
        };
      });
      expect(await adapter.accessStatus(), EventKitCalendarAccess.unknown);
      expect(calls, ['accessStatus']);
      expect(await adapter.requestReadAccess(), EventKitCalendarAccess.full);
      expect(calls, ['accessStatus', 'requestReadAccess']);
    },
  );

  test(
    'discovery carries the native write capability and opaque calendar color',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'calendars');
        return [
          {
            ...source.toJson(),
            'name': 'Calendar',
            'accountName': 'Account A',
            'canWrite': true,
            'color': 0xff3d5f4b,
          },
          {
            ...source.toJson(),
            'calendarId': 'read-only',
            'name': 'Read-only calendar',
            'accountName': 'Account A',
            'canWrite': false,
            'color': 0x7f3d5f4b,
          },
        ];
      });
      final calendars = await adapter.calendars();
      final calendar = calendars.first;
      expect(calendar.id, source);
      expect(calendar.name, 'Calendar');
      expect(calendar.accountName, 'Account A');
      expect(calendar.canRead, isTrue);
      expect(calendar.canWrite, isTrue);
      expect(calendar.color, 0xff3d5f4b);
      expect(calendars.last.canWrite, isFalse);
      expect(calendars.last.color, isNull);
    },
  );

  test('review preparation sends the chosen source and an explicit confirmed token creates', () async {
    final destination = _destination(source);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepareCreate') {
        expect(call.arguments, {
          'destination': {
            ...source.toJson(),
            'name': 'Calendar',
            'accountName': 'Account A',
          },
          'draft': {
            'title': 'Meeting',
            'allDay': false,
            'wallTime': false,
            'startMilliseconds': start.millisecondsSinceEpoch,
            'endMilliseconds': end.millisecondsSinceEpoch,
            'location': 'Studio',
            'timeZoneId': 'Europe/London',
          },
        });
        return _review(source, start, end);
      }
      expect(call.method, 'createReviewedEvent');
      expect(call.arguments, {
        'reviewToken': 'reviewed-token',
        'confirmed': true,
      });
      return {...source.toJson(), 'eventId': 'provider-event-id'};
    });
    final review = await adapter.prepareCreate(
      destination: destination,
      draft: EventKitEventDraft(
        title: 'Meeting',
        start: start,
        end: end,
        location: 'Studio',
        timeZoneId: 'Europe/London',
      ),
    );
    expect(review.destination.id, source);
    expect(review.draft.title, 'Meeting');
    expect(review.start, start);
    expect(review.end, end);
    await expectLater(
      adapter.createReviewedEvent(review, confirmed: false),
      throwsStateError,
    );
    expect(calls, ['prepareCreate']);
    final saved = await adapter.createReviewedEvent(review, confirmed: true);
    expect(
      saved,
      CalendarOccurrenceIdentity(
        calendar: source,
        eventId: 'provider-event-id',
      ),
    );
    expect(calls, ['prepareCreate', 'createReviewedEvent']);
  });

  test(
    'all-day draft review preserves civil bounds and requires an exclusive end',
    () async {
      final first = DateTime(2026, 3, 28);
      final last = DateTime(2026, 3, 30);
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'prepareCreate');
        expect((call.arguments as Map)['draft'], {
          'title': 'Holiday',
          'allDay': true,
          'wallTime': false,
          'startDate': '2026-03-28',
          'endDate': '2026-03-30',
        });
        return {
          ..._review(source, start, end),
          'startDate': '2026-03-28',
          'endDate': '2026-03-30',
        };
      });
      final destination = _destination(source);
      final review = await adapter.prepareCreate(
        destination: destination,
        draft: EventKitEventDraft(
          title: 'Holiday',
          start: first,
          end: last,
          allDay: true,
        ),
      );
      expect(review.start, first);
      expect(review.end, last);
      for (final draft in [
        EventKitEventDraft(
          title: 'One date',
          start: first,
          end: first,
          allDay: true,
        ),
        EventKitEventDraft(
          title: 'Timed',
          start: first.add(const Duration(hours: 12)),
          end: last,
          allDay: true,
        ),
      ]) {
        await expectLater(
          adapter.prepareCreate(destination: destination, draft: draft),
          throwsArgumentError,
        );
      }
      expect(calls, 1);
    },
  );

  test('wall drafts retain gap and fold times for native validation', () async {
    const zone = 'America/New_York';
    for (final (month, day, hour, code) in [
      (3, 8, 2, 'calendar_time_gap'),
      (11, 1, 1, 'calendar_time_ambiguous'),
    ]) {
      final wall = DateTime.utc(2026, month, day, hour, 30);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'prepareCreate');
        final draft = (call.arguments as Map)['draft'] as Map;
        expect(draft['wallTime'], isTrue);
        expect(draft['timeZoneId'], zone);
        expect(draft['startDate'], wall.toIso8601String().split('.').first);
        throw PlatformException(code: code);
      });
      await expectLater(
        adapter.prepareCreate(
          destination: _destination(source),
          draft: EventKitEventDraft.wallTimes(
            title: 'Workout',
            start: wall,
            end: wall.add(const Duration(hours: 1)),
            timeZoneId: zone,
          ),
        ),
        throwsA(
          isA<PlatformException>().having((error) => error.code, 'code', code),
        ),
      );
    }
  });

  test('a changed or disabled destination requires another review', () async {
    final draft = EventKitEventDraft(title: 'Meeting', start: start, end: end);
    final destination = _destination(source);
    for (final code in ['calendar_destination_changed', 'calendar_read_only']) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'prepareCreate') return _review(source, start, end);
        expect(call.method, 'createReviewedEvent');
        throw PlatformException(code: code);
      });
      final review = await adapter.prepareCreate(
        destination: destination,
        draft: draft,
      );
      await expectLater(
        adapter.createReviewedEvent(review, confirmed: true),
        throwsA(
          isA<PlatformException>().having((error) => error.code, 'code', code),
        ),
      );
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'prepareCreate');
      return {
        ..._review(source, start, end),
        'name': 'A newly renamed calendar',
      };
    });
    await expectLater(
      adapter.prepareCreate(destination: destination, draft: draft),
      throwsFormatException,
    );
    await expectLater(
      adapter.prepareCreate(
        destination: _destination(source, canWrite: false),
        draft: draft,
      ),
      throwsArgumentError,
    );
  });

  test(
    'requests selected calendars and decodes timed and all-day occurrences',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'events');
        expect(call.arguments, {
          'startMilliseconds': start.millisecondsSinceEpoch,
          'endMilliseconds': end.millisecondsSinceEpoch,
          'calendars': [source.toJson()],
        });
        return [
          {
            ...source.toJson(),
            'eventId': 'meeting',
            'recurrenceId': 'original-start',
            'title': 'Team meeting',
            'allDay': false,
            'recurring': true,
            'startMilliseconds': start
                .add(const Duration(hours: 14))
                .millisecondsSinceEpoch,
            'endMilliseconds': start
                .add(const Duration(hours: 15))
                .millisecondsSinceEpoch,
            'timeZoneId': 'Europe/London',
            'location': 'Room A',
          },
          {
            ...source.toJson(),
            'eventId': 'holiday',
            'title': 'Holiday',
            'allDay': true,
            'recurring': false,
            'startDate': '2026-11-25',
            'endDate': '2026-11-26',
          },
        ];
      });
      final events = await adapter.events(
        start: start,
        end: end,
        calendars: [source, source],
      );
      final meeting = events.first;
      expect(meeting.id.calendar, source);
      expect(meeting.id.eventId, 'meeting');
      expect(meeting.id.recurrenceId, 'original-start');
      expect(meeting.event.start, DateTime.utc(2026, 11, 24, 14));
      expect(meeting.event.start.isUtc, isTrue);
      expect(meeting.event.location, 'Room A');
      expect(meeting.event.timeZoneId, 'Europe/London');
      final holiday = events.last.event;
      expect(holiday.allDay, isTrue);
      expect(holiday.start, DateTime(2026, 11, 25));
      expect(holiday.end, DateTime(2026, 11, 26));
      expect(holiday.start.isUtc, isFalse);
    },
  );

  test(
    'empty selection, invalid windows and other platforms avoid native queries',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => fail('Unexpected native call: ${call.method}'),
      );
      expect(
        await adapter.events(start: start, end: end, calendars: []),
        isEmpty,
      );
      await expectLater(
        adapter.events(start: end, end: start),
        throwsArgumentError,
      );
      await expectLater(
        adapter.events(start: start, end: start.add(const Duration(days: 368))),
        throwsArgumentError,
      );
      const unsupported = EventKitCalendarAdapter(
        platform: TargetPlatform.linux,
      );
      expect(unsupported.isAvailable, isFalse);
      expect(
        await unsupported.accessStatus(),
        EventKitCalendarAccess.unavailable,
      );
      expect(
        await unsupported.requestReadAccess(),
        EventKitCalendarAccess.unavailable,
      );
      expect(await unsupported.calendars(), isEmpty);
      expect(await unsupported.events(start: start, end: end), isEmpty);
    },
  );

  test('absence of a registered Apple bridge reports unavailable', () async {
    expect(await adapter.accessStatus(), EventKitCalendarAccess.unavailable);
  });
}

CalendarSource _destination(CalendarIdentity source, {bool canWrite = true}) =>
    CalendarSource(
      id: source,
      name: 'Calendar',
      accountName: 'Account A',
      capabilities: [
        CalendarCapability.read,
        if (canWrite) CalendarCapability.write,
      ],
    );

Map<String, Object?> _review(
  CalendarIdentity source,
  DateTime start,
  DateTime end,
) => {
  ...source.toJson(),
  'name': 'Calendar',
  'accountName': 'Account A',
  'canWrite': true,
  'reviewToken': 'reviewed-token',
  'startMilliseconds': start.millisecondsSinceEpoch,
  'endMilliseconds': end.millisecondsSinceEpoch,
  'timeZoneId': 'Europe/London',
};
