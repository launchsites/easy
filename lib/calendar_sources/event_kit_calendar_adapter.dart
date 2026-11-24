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

/// Optional Apple calendar reads. Only requestReadAccess can present an OS prompt.
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
      sources.map((value) {
        final source = _object(value);
        return CalendarSource(
          id: CalendarIdentity.fromJson(source),
          name: _string(source, 'name'),
          accountName: _string(source, 'accountName'),
        );
      }),
    );
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
