import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('easy/event_kit_calendar');
const _adapter = EventKitCalendarAdapter(platform: TargetPlatform.iOS);
const _source = CalendarIdentity(
  accountId: 'local-account',
  calendarId: 'home',
);
const _target = CalendarOccurrenceIdentity(
  calendar: _source,
  eventId: 'linked-event',
);
const _revision =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _updated =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _start = DateTime.utc(2026, 11, 24, 15);
final _end = DateTime.utc(2026, 11, 24, 16);

final _draft = EventKitEventDraft(
  title: 'Revised studio meeting',
  start: _start,
  end: _end,
  location: 'Studio B',
  notes: 'Personal planning notes',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test(
    'confirmed copy exposes its native version without a second write',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'prepareCreate' => _reviewFields(),
          'createReviewedEvent' => _receipt(_revision),
          _ => fail('Unexpected action ${call.method}'),
        };
      });
      final review = await _adapter.prepareCreate(
        destination: CalendarSource(
          id: _source,
          name: 'Home',
          accountName: 'On this device',
          capabilities: const [
            CalendarCapability.read,
            CalendarCapability.write,
          ],
        ),
        draft: _draft,
      );
      final result = await _adapter.createReviewedEventWithReceipt(
        review,
        confirmed: true,
      );
      expect(result.id, _target);
      expect(result.revision, _revision);
      expect(calls, ['prepareCreate', 'createReviewedEvent']);
    },
  );

  test('update prioritizes the known version and excludes private fields by default', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'prepareUpdate':
          expect(call.arguments, {
            'target': {..._source.toJson(), 'eventId': _target.eventId},
            'expectedRevision': _revision,
            'scope': {'location': false, 'notes': false},
            'draft': {
              'title': _draft.title,
              'allDay': false,
              'wallTime': false,
              'startMilliseconds': _start.millisecondsSinceEpoch,
              'endMilliseconds': _end.millisecondsSinceEpoch,
            },
          });
          return _updateReview();
        case 'updateReviewedEvent':
          expect(call.arguments, {
            'reviewToken': 'opaque-review',
            'confirmed': true,
          });
          return _receipt(_updated);
        default:
          fail('Unexpected action ${call.method}');
      }
    });
    final review = await _adapter.prepareUpdate(
      target: _target,
      expectedRevision: _revision,
      draft: _draft,
    );
    expect(review.target, _target);
    expect(review.before.title, 'Studio meeting');
    expect(review.start, _start);
    expect(review.before.location, isNull);
    expect(review.before.notes, isNull);
    expect(review.draft.location, isNull);
    expect(review.draft.notes, isNull);
    await expectLater(
      _adapter.updateReviewedEvent(review, confirmed: false),
      throwsStateError,
    );
    expect(calls, ['prepareUpdate']);
    final result = await _adapter.updateReviewedEvent(review, confirmed: true);
    expect(result.id, _target);
    expect(result.revision, _updated);
    expect(calls, ['prepareUpdate', 'updateReviewedEvent']);
  });

  test('each private field requires its own explicit write scope', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'prepareUpdate');
      final input = call.arguments as Map;
      expect(input['scope'], {'location': true, 'notes': false});
      expect((input['draft'] as Map)['location'], 'Studio B');
      expect((input['draft'] as Map).containsKey('notes'), isFalse);
      return _updateReview();
    });
    final review = await _adapter.prepareUpdate(
      target: _target,
      expectedRevision: _revision,
      draft: _draft,
      updateLocation: true,
    );
    expect(review.updateLocation, isTrue);
    expect(review.updateNotes, isFalse);
    expect(review.before.location, 'Studio A');
    expect(review.draft.location, 'Studio B');
    expect(review.before.notes, isNull);
    expect(review.draft.notes, isNull);
  });

  test(
    'a stale or absent target fails and no implicit calendar is chosen',
    () async {
      final errors = [
        'calendar_copy_changed',
        'calendar_copy_missing',
        'calendar_access',
        'calendar_read_only',
      ];
      for (final failure in errors) {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'prepareUpdate' => _updateReview(),
            'updateReviewedEvent' => throw PlatformException(code: failure),
            _ => fail('Unexpected action ${call.method}'),
          };
        });
        final review = await _adapter.prepareUpdate(
          target: _target,
          expectedRevision: _revision,
          draft: _draft,
        );
        await expectLater(
          _adapter.updateReviewedEvent(review, confirmed: true),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              failure,
            ),
          ),
        );
        expect(calls, ['prepareUpdate', 'updateReviewedEvent']);
      }
    },
  );

  test(
    'recurring targets and invalid review identities are rejected',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls++;
        expect(call.method, 'prepareUpdate');
        return _updateReview(eventId: 'other-event');
      });
      await expectLater(
        _adapter.prepareUpdate(
          target: const CalendarOccurrenceIdentity(
            calendar: _source,
            eventId: 'linked-event',
            recurrenceId: 'a-repeat',
          ),
          expectedRevision: _revision,
          draft: _draft,
        ),
        throwsArgumentError,
      );
      await expectLater(
        _adapter.prepareUpdate(
          target: _target,
          expectedRevision: 'legacy',
          draft: _draft,
        ),
        throwsArgumentError,
      );
      expect(calls, 0);
      await expectLater(
        _adapter.prepareUpdate(
          target: _target,
          expectedRevision: _revision,
          draft: _draft,
        ),
        throwsFormatException,
      );
      expect(calls, 1);
    },
  );
}

Map<String, Object?> _receipt(String revision) => {
  ..._source.toJson(),
  'eventId': _target.eventId,
  'revision': revision,
};

Map<String, Object?> _reviewFields() => {
  ..._source.toJson(),
  'name': 'Home',
  'accountName': 'On this device',
  'canWrite': true,
  'reviewToken': 'opaque-review',
  'startMilliseconds': _start.millisecondsSinceEpoch,
  'endMilliseconds': _end.millisecondsSinceEpoch,
  'timeZoneId': 'Europe/London',
};

Map<String, Object?> _updateReview({String eventId = 'linked-event'}) => {
  ..._reviewFields(),
  'revision': _revision,
  'before': {
    ..._source.toJson(),
    'eventId': eventId,
    'title': 'Studio meeting',
    'startMilliseconds': _start.millisecondsSinceEpoch,
    'endMilliseconds': _end.millisecondsSinceEpoch,
    'allDay': false,
    'recurring': false,
    'location': 'Studio A',
    'notes': 'Older personal notes',
  },
};
