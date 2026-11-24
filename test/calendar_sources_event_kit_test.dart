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

  test('lists Apple account calendars with read-only capability', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'calendars');
      return [
        {
          ...source.toJson(),
          'name': 'Calendar',
          'accountName': 'Account A',
          'canWrite': true,
        },
      ];
    });
    final calendar = (await adapter.calendars()).single;
    expect(calendar.id, source);
    expect(calendar.name, 'Calendar');
    expect(calendar.accountName, 'Account A');
    expect(calendar.canRead, isTrue);
    expect(calendar.canWrite, isFalse);
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
