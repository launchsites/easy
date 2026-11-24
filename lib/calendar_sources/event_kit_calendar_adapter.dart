import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'calendar_directory.dart';

enum EventKitCalendarAccess {
  unavailable,
  unknown,
  writeOnly,
  denied,
  restricted,
  full,
}

/// EventKit snapshot. Timed values are UTC instants. All-day bounds are civil dates.
class ExternalCalendarEvent {
  const ExternalCalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    this.location,
    this.notes,
    this.timeZoneId,
    this.recurring = false,
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? location;
  final String? notes;
  final String? timeZoneId;
  final bool recurring;
}

class EventKitEventDraft {
  const EventKitEventDraft({
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location,
    this.notes,
    this.timeZoneId,
  }) : _wallTime = false;

  /// Pass civil clock fields in UTC DateTime containers so skipped and repeated
  /// wall times can be validated in the named zone or the device zone.
  const EventKitEventDraft.wallTimes({
    required this.title,
    required this.start,
    required this.end,
    this.location,
    this.notes,
    this.timeZoneId,
  }) : allDay = false,
       _wallTime = true;

  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String? location;
  final String? notes;
  final String? timeZoneId;
  final bool _wallTime;

  EventKitEventDraft _scoped({required bool location, required bool notes}) =>
      _wallTime
      ? EventKitEventDraft.wallTimes(
          title: title,
          start: start,
          end: end,
          location: location ? this.location : null,
          notes: notes ? this.notes : null,
          timeZoneId: timeZoneId,
        )
      : EventKitEventDraft(
          title: title,
          start: start,
          end: end,
          allDay: allDay,
          location: location ? this.location : null,
          notes: notes ? this.notes : null,
          timeZoneId: timeZoneId,
        );

  Map<String, Object?> _payload() {
    if (title.trim().isEmpty) throw ArgumentError('Enter an event title.');
    final startDate = _wallTime ? _civilTime(start) : _civilDate(start);
    final endDate = _wallTime ? _civilTime(end) : _civilDate(end);
    if (allDay) {
      if (!_isDateOnly(start) ||
          !_isDateOnly(end) ||
          endDate.compareTo(startDate) <= 0) {
        throw ArgumentError(
          'Choose an all-day start and a later exclusive end date.',
        );
      }
      if (timeZoneId != null) {
        throw ArgumentError('All-day events use calendar dates.');
      }
    } else if (_wallTime) {
      if (!start.isUtc ||
          !end.isUtc ||
          start.millisecond != 0 ||
          end.millisecond != 0 ||
          start.microsecond != 0 ||
          end.microsecond != 0 ||
          endDate.compareTo(startDate) <= 0) {
        throw ArgumentError('Choose a valid start and later end clock time.');
      }
    } else if (end.millisecondsSinceEpoch <= start.millisecondsSinceEpoch) {
      throw ArgumentError('Choose an end time after the start.');
    }
    return {
      'title': title,
      'allDay': allDay,
      'wallTime': _wallTime,
      if (allDay || _wallTime) ...{
        'startDate': startDate,
        'endDate': endDate,
      } else ...{
        'startMilliseconds': start.millisecondsSinceEpoch,
        'endMilliseconds': end.millisecondsSinceEpoch,
      },
      if (location != null) 'location': location,
      if (notes != null) 'notes': notes,
      if (timeZoneId != null) 'timeZoneId': timeZoneId,
    };
  }
}

class EventKitCreateReview {
  const EventKitCreateReview._({
    required this._token,
    required this.destination,
    required this.draft,
    required this.start,
    required this.end,
    this.timeZoneId,
  });

  final String _token;
  final CalendarSource destination;
  final EventKitEventDraft draft;
  final DateTime start;
  final DateTime end;
  final String? timeZoneId;
}

/// The originating native event and its opaque version at the confirmed save.
class EventKitCopyReceipt {
  const EventKitCopyReceipt._(this.id, this.revision);

  final CalendarOccurrenceIdentity id;
  final String? revision;
}

class EventKitUpdateReview {
  const EventKitUpdateReview._({
    required this._token,
    required this.target,
    required this.destination,
    required this.before,
    required this.draft,
    required this.start,
    required this.end,
    required this.updateLocation,
    required this.updateNotes,
    this.timeZoneId,
  });

  final String _token;
  final CalendarOccurrenceIdentity target;
  final CalendarSource destination;
  final ExternalCalendarEvent before;
  final EventKitEventDraft draft;
  final DateTime start;
  final DateTime end;
  final String? timeZoneId;
  final bool updateLocation;
  final bool updateNotes;
}

/// Apple calendar access. Only requestReadAccess can present an OS prompt.
class EventKitCalendarAdapter {
  const EventKitCalendarAdapter({
    MethodChannel methodChannel = const MethodChannel(
      'easy/event_kit_calendar',
    ),
    EventChannel eventChannel = const EventChannel(
      'easy/event_kit_calendar/changes',
    ),
    this._platform,
  }) : _methods = methodChannel,
       _events = eventChannel;

  final MethodChannel _methods;
  final EventChannel _events;
  final TargetPlatform? _platform;

  bool get isAvailable =>
      !kIsWeb &&
      switch (_platform ?? defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.macOS => true,
        _ => false,
      };

  Future<EventKitCalendarAccess> accessStatus() => _access('accessStatus');

  Future<EventKitCalendarAccess> requestReadAccess() =>
      _access('requestReadAccess');

  Future<EventKitCalendarAccess> _access(String method) async {
    if (!isAvailable) return EventKitCalendarAccess.unavailable;
    try {
      final result = await _methods.invokeMethod<String>(method);
      return EventKitCalendarAccess.values.asNameMap()[result] ??
          EventKitCalendarAccess.unavailable;
    } on MissingPluginException {
      return EventKitCalendarAccess.unavailable;
    }
  }

  Future<List<CalendarSource>> calendars() async {
    if (!isAvailable) return const [];
    final sources =
        await _methods.invokeListMethod<Object?>('calendars') ?? const [];
    return List.unmodifiable(
      sources.map((value) => _readSource(_object(value))),
    );
  }

  Future<EventKitCreateReview> prepareCreate({
    required CalendarSource destination,
    required EventKitEventDraft draft,
  }) async {
    if (!isAvailable) throw UnsupportedError('Apple Calendar is unavailable.');
    if (!destination.canWrite) {
      throw ArgumentError('Choose a writable calendar.');
    }
    final response = _object(
      await _methods.invokeMethod<Object?>('prepareCreate', {
        'destination': {
          ...destination.id.toJson(),
          'name': destination.name,
          'accountName': destination.accountName,
        },
        'draft': draft._payload(),
      }),
    );
    final reviewed = _readSource(response);
    final token = _string(response, 'reviewToken');
    if (!reviewed.canWrite ||
        reviewed.id != destination.id ||
        reviewed.name != destination.name ||
        reviewed.accountName != destination.accountName ||
        token.isEmpty) {
      throw const FormatException(
        'The selected calendar changed. Choose a calendar again.',
      );
    }
    return EventKitCreateReview._(
      token: token,
      destination: reviewed,
      draft: draft,
      start: draft.allDay
          ? _calendarDate(response, 'startDate')
          : _instant(response, 'startMilliseconds'),
      end: draft.allDay
          ? _calendarDate(response, 'endDate')
          : _instant(response, 'endMilliseconds'),
      timeZoneId: _optionalString(response, 'timeZoneId'),
    );
  }

  Future<CalendarOccurrenceIdentity> createReviewedEvent(
    EventKitCreateReview review, {
    required bool confirmed,
  }) async =>
      (await createReviewedEventWithReceipt(review, confirmed: confirmed)).id;

  Future<EventKitCopyReceipt> createReviewedEventWithReceipt(
    EventKitCreateReview review, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw StateError('Confirm the event review before saving.');
    if (!isAvailable) throw UnsupportedError('Apple Calendar is unavailable.');
    final response = _object(
      await _methods.invokeMethod<Object?>('createReviewedEvent', {
        'reviewToken': review._token,
        'confirmed': true,
      }),
    );
    final receipt = _readReceipt(response);
    if (receipt.id.calendar != review.destination.id) {
      throw const FormatException(
        'The calendar returned an invalid event identity.',
      );
    }
    return receipt;
  }

  Future<EventKitUpdateReview> prepareUpdate({
    required CalendarOccurrenceIdentity target,
    required String expectedRevision,
    required EventKitEventDraft draft,
    bool updateLocation = false,
    bool updateNotes = false,
  }) async {
    if (!isAvailable) throw UnsupportedError('Apple Calendar is unavailable.');
    if (target.eventId.isEmpty ||
        target.recurrenceId != null ||
        !_validCopyRevision(expectedRevision)) {
      throw ArgumentError('Choose a verified standalone Apple Calendar copy.');
    }
    final scoped = draft._scoped(location: updateLocation, notes: updateNotes);
    final response = _object(
      await _methods.invokeMethod<Object?>('prepareUpdate', {
        'target': {...target.calendar.toJson(), 'eventId': target.eventId},
        'expectedRevision': expectedRevision,
        'draft': scoped._payload(),
        'scope': {'location': updateLocation, 'notes': updateNotes},
      }),
    );
    final destination = _readSource(response);
    final token = _string(response, 'reviewToken');
    final prior = _object(response['before']);
    if (!updateLocation) prior.remove('location');
    if (!updateNotes) prior.remove('notes');
    final before = _readEvent(prior);
    if (!destination.canWrite ||
        destination.id != target.calendar ||
        token.isEmpty ||
        before.id != target ||
        before.event.recurring ||
        response['revision'] != expectedRevision) {
      throw const FormatException(
        'The Apple Calendar copy changed. Review the current link again.',
      );
    }
    final start = scoped.allDay
        ? _calendarDate(response, 'startDate')
        : _instant(response, 'startMilliseconds');
    final end = scoped.allDay
        ? _calendarDate(response, 'endDate')
        : _instant(response, 'endMilliseconds');
    if (!end.isAfter(start)) {
      throw const FormatException(
        'The calendar returned an invalid update time.',
      );
    }
    return EventKitUpdateReview._(
      token: token,
      target: target,
      destination: destination,
      before: before.event,
      draft: scoped,
      start: start,
      end: end,
      timeZoneId: _optionalString(response, 'timeZoneId'),
      updateLocation: updateLocation,
      updateNotes: updateNotes,
    );
  }

  Future<EventKitCopyReceipt> updateReviewedEvent(
    EventKitUpdateReview review, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw StateError('Confirm the event update before saving.');
    if (!isAvailable) throw UnsupportedError('Apple Calendar is unavailable.');
    final response = _object(
      await _methods.invokeMethod<Object?>('updateReviewedEvent', {
        'reviewToken': review._token,
        'confirmed': true,
      }),
    );
    final receipt = _readReceipt(response);
    if (receipt.id != review.target) {
      throw const FormatException(
        'The calendar returned a different event identity.',
      );
    }
    return receipt;
  }

  Future<List<SourcedCalendarEvent<ExternalCalendarEvent>>> events({
    required DateTime start,
    required DateTime end,
    Iterable<CalendarIdentity>? calendars,
  }) async {
    if (!isAvailable) return const [];
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(days: 367)) {
      throw ArgumentError(
        'Select a calendar window between zero and 367 days.',
      );
    }
    final sources = calendars?.toSet();
    if (sources != null && sources.isEmpty) return const [];
    final events =
        await _methods.invokeListMethod<Object?>('events', {
          'startMilliseconds': start.millisecondsSinceEpoch,
          'endMilliseconds': end.millisecondsSinceEpoch,
          if (sources != null)
            'calendars': [for (final source in sources) source.toJson()],
        }) ??
        const [];
    return List.unmodifiable(events.map(_readEvent));
  }

  Stream<void> get changes => isAvailable
      ? _events.receiveBroadcastStream().map<void>((_) {})
      : const Stream.empty();
}

final _copyRevision = RegExp(r'^[a-f0-9]{64}$');
bool _validCopyRevision(String value) =>
    value.length == 64 && _copyRevision.hasMatch(value);

EventKitCopyReceipt _readReceipt(Map<String, Object?> response) {
  final source = CalendarIdentity.fromJson(response);
  final id = _string(response, 'eventId');
  final revision = _optionalString(response, 'revision');
  if (id.isEmpty ||
      response['recurrenceId'] != null ||
      (revision != null && !_validCopyRevision(revision))) {
    throw const FormatException(
      'The calendar returned an invalid event receipt.',
    );
  }
  return EventKitCopyReceipt._(
    CalendarOccurrenceIdentity(calendar: source, eventId: id),
    revision,
  );
}

CalendarSource _readSource(Map<String, Object?> source) => CalendarSource(
  id: CalendarIdentity.fromJson(source),
  name: _string(source, 'name'),
  accountName: _string(source, 'accountName'),
  color: _opaqueColor(source['color']),
  capabilities: [
    CalendarCapability.read,
    if (source['canWrite'] == true) CalendarCapability.write,
  ],
);

int? _opaqueColor(Object? value) =>
    value is int && value >= 0xff000000 && value <= 0xffffffff ? value : null;

bool _isDateOnly(DateTime date) =>
    date ==
    (date.isUtc
        ? DateTime.utc(date.year, date.month, date.day)
        : DateTime(date.year, date.month, date.day));

String _civilDate(DateTime date) {
  if (date.year < 1 || date.year > 9999) {
    throw ArgumentError('Choose a four-digit calendar year.');
  }
  return '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';
}

String _civilTime(DateTime time) =>
    '${_civilDate(time)}T${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String _two(int value) => value.toString().padLeft(2, '0');

SourcedCalendarEvent<ExternalCalendarEvent> _readEvent(Object? value) {
  final event = _object(value);
  final allDay = _bool(event, 'allDay');
  return SourcedCalendarEvent(
    id: CalendarOccurrenceIdentity(
      calendar: CalendarIdentity.fromJson(event),
      eventId: _string(event, 'eventId'),
      recurrenceId: _optionalString(event, 'recurrenceId'),
    ),
    event: ExternalCalendarEvent(
      title: _string(event, 'title'),
      start: allDay
          ? _calendarDate(event, 'startDate')
          : _instant(event, 'startMilliseconds'),
      end: allDay
          ? _calendarDate(event, 'endDate')
          : _instant(event, 'endMilliseconds'),
      allDay: allDay,
      recurring: _bool(event, 'recurring'),
      location: _optionalString(event, 'location'),
      notes: _optionalString(event, 'notes'),
      timeZoneId: _optionalString(event, 'timeZoneId'),
    ),
  );
}

Map<String, Object?> _object(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }
  throw const FormatException('Expected an EventKit response object.');
}

String _string(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is String) return value;
  throw FormatException('Expected EventKit text for $key.');
}

String? _optionalString(Map<String, Object?> object, String key) =>
    object[key] == null ? null : _string(object, key);

bool _bool(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is bool) return value;
  throw FormatException('Expected an EventKit flag for $key.');
}

DateTime _instant(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  throw FormatException('Expected an EventKit instant for $key.');
}

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

DateTime _calendarDate(Map<String, Object?> object, String key) {
  final match = _datePattern.firstMatch(_string(object, key));
  if (match == null) {
    throw FormatException('Expected an EventKit calendar date for $key.');
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final value = DateTime(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    throw FormatException('Invalid EventKit calendar date for $key.');
  }
  return value;
}
