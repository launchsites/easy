import 'dart:math' as math;

import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'ics_calendar.dart';

part 'ics_recurrence_rule.dart';

class IcsExpansionException implements Exception {
  const IcsExpansionException(this.message, {this.uid});

  final String message;
  final String? uid;

  @override
  String toString() => uid == null ? message : '$message (UID $uid)';
}

class IcsOccurrence {
  const IcsOccurrence._({
    required this.sourceIndex,
    required this.event,
    required this.start,
    required this.end,
    required this.allDay,
    required this.recurrenceId,
    required this._orderStart,
  });

  /// Position of the original VEVENT, including repeated UIDs in a file.
  final int sourceIndex;
  final IcsEvent event;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final IcsDateTime? recurrenceId;
  final DateTime _orderStart;

  String get sourceUid => event.uid;
}

/// Returns occurrences that overlap the half-open window. Timed bounds are UTC
/// instants. All-day bounds are local civil dates, with an exclusive end.
/// Floating values use the provided IANA display zone or the device's zone.
List<IcsOccurrence> expandIcsCalendar(
  IcsCalendar calendar, {
  required DateTime windowStart,
  required DateTime windowEnd,
  String? floatingTimeZone,
  int limit = 10000,
}) {
  final firstInstant = windowStart.toUtc();
  final lastInstant = windowEnd.toUtc();
  if (firstInstant.year < 1 ||
      lastInstant.isAfter(DateTime.utc(10000)) ||
      !lastInstant.isAfter(firstInstant) ||
      lastInstant.difference(firstInstant) > const Duration(days: 367)) {
    throw ArgumentError(
      'Select an iCalendar window between zero and 367 days.',
    );
  }
  if (limit < 1 || limit > 100000) throw ArgumentError.value(limit, 'limit');
  final expansion = _Expansion(
    firstInstant,
    lastInstant,
    _IcsClock(floatingTimeZone),
    limit,
  );
  final groups = <String, List<({int index, IcsEvent event})>>{};
  for (final (index, event) in calendar.events.indexed) {
    expansion.step(event.uid);
    groups.putIfAbsent(event.uid, () => []).add((index: index, event: event));
  }
  for (final events in groups.values) {
    expansion.series(events);
  }
  expansion.results.sort((first, second) {
    final order = first._orderStart.compareTo(second._orderStart);
    return order == 0 ? first.sourceIndex.compareTo(second.sourceIndex) : order;
  });
  return List.unmodifiable(expansion.results);
}

class _Expansion {
  _Expansion(this.windowStart, this.windowEnd, this.clock, this.limit);

  final DateTime windowStart;
  final DateTime windowEnd;
  final _IcsClock clock;
  final int limit;
  final results = <IcsOccurrence>[];
  int _steps = 0;

  void step(String uid) {
    if (++_steps > 200000) {
      throw IcsExpansionException(
        'Calendar recurrence exceeds the expansion budget.',
        uid: uid,
      );
    }
  }

  void series(List<({int index, IcsEvent event})> events) {
    final masters = events
        .where((entry) => entry.event.recurrenceId == null)
        .toList();
    final detached = events
        .where((entry) => entry.event.recurrenceId != null)
        .toList();
    if (masters.length > 1 && detached.isNotEmpty) {
      throw IcsExpansionException(
        'Detached occurrences have more than one possible source series.',
        uid: events.first.event.uid,
      );
    }
    for (final entry in detached) {
      final event = entry.event;
      if (event.recurrenceRange != null ||
          event.recurrenceRule != null ||
          event.recurrenceDates.isNotEmpty ||
          event.exceptionDates.isNotEmpty ||
          event.recurrencePeriods.isNotEmpty) {
        throw IcsExpansionException(
          'Unsupported recurrence rule on a detached occurrence.',
          uid: event.uid,
        );
      }
    }
    if (masters.length == 1 && _cancelled(masters.single.event)) return;
    for (final master in masters) {
      if (!_cancelled(master.event)) _expandMaster(master, detached);
    }
    for (final entry in detached) {
      if (_cancelled(entry.event)) continue;
      final event = entry.event;
      final start = clock.requireInstant(event.start, event.uid);
      _include(
        entry,
        event.start,
        start,
        _eventLength(event, start),
        event.recurrenceId,
      );
    }
  }

  void _expandMaster(
    ({int index, IcsEvent event}) entry,
    List<({int index, IcsEvent event})> detached,
  ) {
    final event = entry.event;
    final start = clock.requireInstant(event.start, event.uid);
    final length = _eventLength(event, start);
    final rule = event.recurrenceRule == null
        ? null
        : _RecurrenceRule.parse(event);
    final periods = event.recurrencePeriods;
    final isSeries =
        rule != null ||
        detached.isNotEmpty ||
        event.recurrenceDates.isNotEmpty ||
        event.exceptionDates.isNotEmpty ||
        periods.isNotEmpty;
    if (!isSeries) {
      _include(entry, event.start, start, length, null);
      return;
    }

    final excluded = <Object>{};
    for (final exception in [
      ...event.exceptionDates,
      ...detached.map((entry) => entry.event.recurrenceId!),
    ]) {
      step(event.uid);
      excluded.add(
        _recurrenceKey(
          exception,
          event,
          clock.requireInstant(exception, event.uid),
        ),
      );
    }

    final dates =
        <
          Object,
          ({IcsDateTime value, DateTime instant, _EventLength length})
        >{};
    for (final value in [event.start, ...event.recurrenceDates]) {
      step(event.uid);
      final instant = value == event.start
          ? start
          : clock.requireInstant(value, event.uid);
      final key = _recurrenceKey(value, event, instant);
      dates.putIfAbsent(
        key,
        () => (value: value, instant: instant, length: length),
      );
    }
    final periodLengths = <Object, _EventLength>{};
    for (final period in periods) {
      step(event.uid);
      final instant = clock.requireInstant(period.start, event.uid);
      final key = _recurrenceKey(period.start, event, instant);
      final length = _length(
        event.uid,
        period.start,
        instant,
        end: period.end,
        duration: period.duration,
      );
      final previous = periodLengths[key];
      if (previous != null && previous != length) {
        throw IcsExpansionException(
          'RDATE periods have conflicting lengths.',
          uid: event.uid,
        );
      }
      periodLengths[key] = length;
      dates[key] = (value: period.start, instant: instant, length: length);
    }
    for (final date in dates.entries) {
      if (excluded.contains(date.key)) continue;
      final occurrence = date.value;
      _include(
        entry,
        occurrence.value,
        occurrence.instant,
        occurrence.length,
        occurrence.value,
      );
    }
    if (rule == null || rule.count == 1) return;

    final counted = rule.count != null;
    final first = rule.firstPeriod(event.start.components);
    // A civil-day duration and timezone changes can put a start before the
    // window. Keep two extra days for date boundaries and offset transitions.
    final earliest = windowStart.subtract(
      length.exact + Duration(days: length.days + 2),
    );
    final stop = clock
        .wallAt(windowEnd, event.start)
        .add(const Duration(days: 2));
    final cut = math.max(
      0,
      rule.periodIndex(first, clock.wallAt(earliest, event.start)),
    );
    final last = rule.periodIndex(first, stop);
    var generated = 1;
    for (var index = counted ? 0 : cut; index <= last; index++) {
      step(event.uid);
      final period = rule.periodAt(first, index);
      final candidates = <({IcsDateTime value, DateTime instant})>[];
      for (final day in rule.datesIn(period, event.start.components)) {
        step(event.uid);
        if (day.year < 1 || day.year > 9999) continue;
        final value = _withWall(
          event.start,
          _atClock(day, event.start.components),
        );
        final instant = clock.instant(value);
        if (instant != null) candidates.add((value: value, instant: instant));
      }
      final selected = rule.positions.isEmpty
          ? candidates
          : _pickPositions(candidates, rule.positions);
      for (final candidate in selected) {
        final value = candidate.value;
        if (!value.components.isAfter(event.start.components)) continue;
        if (value.components.isAfter(stop) ||
            !_beforeUntil(rule.until, candidate)) {
          return;
        }
        if (rule.count != null && generated >= rule.count!) return;
        generated++;
        final key = _recurrenceKey(value, event, candidate.instant);
        if (dates.containsKey(key) || excluded.contains(key)) continue;
        _include(entry, value, candidate.instant, length, value);
      }
    }
  }

  _EventLength _eventLength(IcsEvent event, DateTime start) => _length(
    event.uid,
    event.start,
    start,
    end: event.end,
    duration: event.duration,
  );

  _EventLength _length(
    String uid,
    IcsDateTime start,
    DateTime instant, {
    IcsDateTime? end,
    String? duration,
  }) {
    if (end != null) {
      if (start.kind == IcsDateTimeKind.date) {
        return _EventLength(
          end.components.difference(start.components).inDays,
          Duration.zero,
        );
      }
      final difference = clock.requireInstant(end, uid).difference(instant);
      if (difference <= Duration.zero) {
        throw IcsExpansionException(
          'DTEND must follow the resolved DTSTART.',
          uid: uid,
        );
      }
      return _EventLength(0, difference);
    }
    if (duration != null) return _durationLength(duration, uid);
    return _EventLength(
      start.kind == IcsDateTimeKind.date ? 1 : 0,
      Duration.zero,
    );
  }

  void _include(
    ({int index, IcsEvent event}) entry,
    IcsDateTime value,
    DateTime begin,
    _EventLength length,
    IcsDateTime? recurrenceId,
  ) {
    if (!begin.isBefore(windowEnd)) return;
    final end = length.days == 0
        ? begin
        : clock.requireInstant(
            value,
            entry.event.uid,
            wall: _addDays(value.components, length.days),
          );
    final finish = end.add(length.exact);
    if (finish.isAfter(begin)
        ? !finish.isAfter(windowStart)
        : begin.isBefore(windowStart)) {
      return;
    }
    if (results.length >= limit) {
      throw IcsExpansionException(
        'More occurrences fall in this calendar window than the configured limit.',
        uid: entry.event.uid,
      );
    }
    final allDay = value.kind == IcsDateTimeKind.date;
    final civilEnd = allDay ? _addDays(value.components, length.days) : null;
    results.add(
      IcsOccurrence._(
        sourceIndex: entry.index,
        event: entry.event,
        start: allDay ? _localDate(value.components, entry.event.uid) : begin,
        end: civilEnd == null ? finish : _localDate(civilEnd, entry.event.uid),
        allDay: allDay,
        recurrenceId: recurrenceId,
        orderStart: begin,
      ),
    );
  }
}

bool _cancelled(IcsEvent event) => event.status?.toUpperCase() == 'CANCELLED';

Object _recurrenceKey(IcsDateTime value, IcsEvent event, DateTime instant) {
  final isDate = value.kind == IcsDateTimeKind.date;
  if (isDate != (event.start.kind == IcsDateTimeKind.date)) {
    throw IcsExpansionException(
      'A recurrence date has an incompatible value type.',
      uid: event.uid,
    );
  }
  return isDate ? value.components : instant.millisecondsSinceEpoch;
}

bool _beforeUntil(
  IcsDateTime? until,
  ({IcsDateTime value, DateTime instant}) candidate,
) {
  if (until == null) return true;
  final time = until.kind == IcsDateTimeKind.utc
      ? candidate.instant
      : candidate.value.components;
  return !time.isAfter(until.components);
}

List<T> _pickPositions<T>(List<T> candidates, Set<int> positions) {
  final indexes = <int>{};
  for (final position in positions) {
    final index = position > 0 ? position - 1 : candidates.length + position;
    if (index >= 0 && index < candidates.length) indexes.add(index);
  }
  return [for (final index in indexes.toList()..sort()) candidates[index]];
}

class _EventLength {
  const _EventLength(this.days, this.exact);

  final int days;
  final Duration exact;

  @override
  bool operator ==(Object other) =>
      other is _EventLength && other.days == days && other.exact == exact;

  @override
  int get hashCode => Object.hash(days, exact);
}

final _durationParts = RegExp(r'(\d+)([WDHMS])');

_EventLength _durationLength(String text, String uid) {
  var days = 0;
  var seconds = 0;
  for (final part in _durationParts.allMatches(text.toUpperCase())) {
    final amount = int.tryParse(part[1]!);
    if (amount == null || amount > 86400000000) {
      throw IcsExpansionException(
        'Event duration exceeds the supported calendar range.',
        uid: uid,
      );
    }
    switch (part[2]!) {
      case 'W':
        days += amount * 7;
      case 'D':
        days += amount;
      case 'H':
        seconds += amount * 3600;
      case 'M':
        seconds += amount * 60;
      case 'S':
        seconds += amount;
    }
  }
  if (days + seconds ~/ Duration.secondsPerDay > 3660000) {
    throw IcsExpansionException(
      'Event duration exceeds the supported calendar range.',
      uid: uid,
    );
  }
  return _EventLength(days, Duration(seconds: seconds));
}

DateTime _localDate(DateTime components, String uid) {
  final local = DateTime(components.year, components.month, components.day);
  if (_civilDay(local) != components) {
    throw IcsExpansionException(
      'An all-day date cannot be represented in the device time zone.',
      uid: uid,
    );
  }
  return local;
}

DateTime _civilDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
DateTime _addDays(DateTime value, int days) => value.add(Duration(days: days));
DateTime _atClock(DateTime date, DateTime time) => DateTime.utc(
  date.year,
  date.month,
  date.day,
  time.hour,
  time.minute,
  time.second,
);

IcsDateTime _withWall(IcsDateTime original, DateTime components) =>
    switch (original.kind) {
      IcsDateTimeKind.date => IcsDateTime.date(components),
      IcsDateTimeKind.utc => IcsDateTime.utc(components),
      IcsDateTimeKind.floating => IcsDateTime.floating(components),
      IcsDateTimeKind.zoned => IcsDateTime.zoned(
        components,
        original.timeZoneId!,
      ),
    };

bool _timeZonesInitialized = false;

class _IcsClock {
  _IcsClock(String? floatingTimeZone) {
    if (floatingTimeZone != null) {
      _floatingLocation = _location(floatingTimeZone);
    }
  }

  timezone.Location? _floatingLocation;

  timezone.Location _location(String zoneId) {
    if (!_timeZonesInitialized) {
      timezone_data.initializeTimeZones();
      _timeZonesInitialized = true;
    }
    final location = timezone.timeZoneDatabase.locations[zoneId];
    if (location == null) {
      throw IcsExpansionException('Unknown calendar time zone $zoneId.');
    }
    return location;
  }

  timezone.Location? _zoneFor(IcsDateTime value) =>
      value.kind == IcsDateTimeKind.zoned
      ? _location(value.timeZoneId!)
      : _floatingLocation;

  DateTime wallAt(DateTime instant, IcsDateTime basis) {
    if (basis.kind == IcsDateTimeKind.utc) return instant.toUtc();
    final zone = _zoneFor(basis);
    final local = zone == null
        ? instant.toLocal()
        : timezone.TZDateTime.from(instant, zone);
    return _atClock(local, local);
  }

  DateTime requireInstant(IcsDateTime value, String uid, {DateTime? wall}) =>
      instant(value, wall: wall) ??
      (throw IcsExpansionException(
        'A calendar time falls in a daylight-saving gap.',
        uid: uid,
      ));

  DateTime? instant(IcsDateTime value, {DateTime? wall}) {
    final components = wall ?? value.components;
    if (value.kind == IcsDateTimeKind.utc) return components;
    final zone = _zoneFor(value);
    if (value.kind == IcsDateTimeKind.date) {
      final midnight = zone == null
          ? DateTime(components.year, components.month, components.day)
          : timezone.TZDateTime(
              zone,
              components.year,
              components.month,
              components.day,
            );
      return _civilDay(midnight) == components ? midnight.toUtc() : null;
    }
    DateTime localAt(DateTime instant) => zone == null
        ? instant.toLocal()
        : timezone.TZDateTime.from(instant, zone);
    final offsets = {
      for (final day in [-2, 0, 2])
        localAt(_addDays(components, day)).timeZoneOffset,
    };
    DateTime? first;
    for (final offset in offsets) {
      final candidate = components.subtract(offset);
      final local = localAt(candidate);
      if (_atClock(local, local) == components &&
          (first == null || candidate.isBefore(first))) {
        first = candidate;
      }
    }
    return first;
  }
}
