import 'dart:math';

import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'planner.dart';

enum AvailabilityKind { available, unavailable }

const maxSchedulingBufferMinutes = 7 * 24 * 60;
const maxPlanningWindowDays = 31;

class WeeklyAvailability {
  WeeklyAvailability({
    required this.id,
    required Iterable<int> weekdays,
    required this.startMinute,
    required this.endMinute,
    Iterable<String>? categories,
    this.kind = AvailabilityKind.available,
  }) : weekdays = Set.unmodifiable(weekdays),
       categories = categories == null ? null : Set.unmodifiable(categories) {
    if (id.trim().isEmpty ||
        this.weekdays.isEmpty ||
        this.weekdays.any(
          (value) => value < DateTime.monday || value > DateTime.sunday,
        )) {
      throw ArgumentError('Choose at least one weekday.');
    }
    if (startMinute < 0 ||
        startMinute >= 1440 ||
        endMinute < 0 ||
        endMinute > 1440 ||
        startMinute == endMinute) {
      throw ArgumentError('Choose different start and end times.');
    }
    if (this.categories case final scopes?) {
      if (scopes.isEmpty || scopes.any((value) => value.trim().isEmpty)) {
        throw ArgumentError('Choose one or more categories.');
      }
    }
  }

  factory WeeklyAvailability.fromJson(Map<String, Object?> json) =>
      WeeklyAvailability(
        id: json['id'] as String,
        weekdays: (json['weekdays'] as List<Object?>).cast<int>(),
        startMinute: json['startMinute'] as int,
        endMinute: json['endMinute'] as int,
        categories: (json['categories'] as List<Object?>?)?.cast<String>(),
        kind: AvailabilityKind.values.byName(
          json['kind'] as String? ?? 'available',
        ),
      );

  final String id;
  final Set<int> weekdays;
  final int startMinute;
  final int endMinute;
  final Set<String>? categories;
  final AvailabilityKind kind;

  bool get crossesMidnight => endMinute < startMinute;

  Map<String, Object?> toJson() => {
    'id': id,
    'weekdays': weekdays.toList()..sort(),
    'startMinute': startMinute,
    'endMinute': endMinute,
    if (categories != null) 'categories': categories!.toList()..sort(),
    if (kind != AvailabilityKind.available) 'kind': kind.name,
  };
}

/// The name and detail are local display text. Planning only receives the ID.
class SavedPlace {
  SavedPlace({required this.id, required String name, String? privateDetail})
    : name = name.trim(),
      privateDetail = privateDetail?.trim() {
    if (id.trim().isEmpty || this.name.isEmpty) {
      throw ArgumentError('Give the saved place a name.');
    }
  }

  factory SavedPlace.fromJson(Map<String, Object?> json) => SavedPlace(
    id: json['id'] as String,
    name: json['name'] as String,
    privateDetail: json['privateDetail'] as String?,
  );

  final String id;
  final String name;
  final String? privateDetail;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (privateDetail != null && privateDetail!.isNotEmpty)
      'privateDetail': privateDetail,
  };
}

class TravelDuration {
  TravelDuration({
    required this.fromPlaceId,
    required this.toPlaceId,
    required this.minutes,
  }) {
    if (fromPlaceId.trim().isEmpty ||
        toPlaceId.trim().isEmpty ||
        fromPlaceId == toPlaceId) {
      throw ArgumentError('Choose two different saved places.');
    }
    _checkMinutes(minutes);
  }

  factory TravelDuration.fromJson(Map<String, Object?> json) => TravelDuration(
    fromPlaceId: json['fromPlaceId'] as String,
    toPlaceId: json['toPlaceId'] as String,
    minutes: json['minutes'] as int,
  );

  final String fromPlaceId;
  final String toPlaceId;
  final int minutes;

  Map<String, Object?> toJson() => {
    'fromPlaceId': fromPlaceId,
    'toPlaceId': toPlaceId,
    'minutes': minutes,
  };
}

/// A local projection that carries no title, address, trajectory or raw event.
class PlacedCommitment {
  PlacedCommitment({
    required this.id,
    required this.span,
    this.placeId,
    this.beforeMinutes,
    this.afterMinutes,
  }) {
    if (id.trim().isEmpty || placeId?.trim().isEmpty == true) {
      throw ArgumentError('Choose a valid commitment and saved place.');
    }
    if (beforeMinutes case final value?) _checkMinutes(value);
    if (afterMinutes case final value?) _checkMinutes(value);
  }

  final String id;
  final TimeSpan span;
  final String? placeId;
  final int? beforeMinutes;
  final int? afterMinutes;
}

enum TravelIssueKind { missingDuration, insufficientGap }

class TravelIssue {
  const TravelIssue._({
    required this.kind,
    required this.fromCommitmentId,
    required this.toCommitmentId,
    required this.fromPlaceId,
    required this.toPlaceId,
    required this.requiredGap,
  });

  final TravelIssueKind kind;
  final String fromCommitmentId;
  final String toCommitmentId;
  final String fromPlaceId;
  final String toPlaceId;
  final Duration? requiredGap;
}

class SchedulingInputs {
  SchedulingInputs._({
    required Iterable<PlanningWindow> availability,
    required Iterable<FixedCommitment> commitments,
    required Iterable<TravelIssue> travelIssues,
  }) : availability = List.unmodifiable(availability),
       commitments = List.unmodifiable(commitments),
       travelIssues = List.unmodifiable(travelIssues);

  final List<PlanningWindow> availability;
  final List<FixedCommitment> commitments;
  final List<TravelIssue> travelIssues;
}

class SchedulingSettings {
  SchedulingSettings({
    this.timeZoneId,
    Iterable<WeeklyAvailability> availability = const [],
    Iterable<SavedPlace> places = const [],
    Iterable<TravelDuration> routes = const [],
    this.beforeMinutes = 0,
    this.afterMinutes = 0,
  }) : availability = List.unmodifiable(availability),
       places = List.unmodifiable(places),
       routes = List.unmodifiable(routes) {
    _checkMinutes(beforeMinutes);
    _checkMinutes(afterMinutes);
    _checkUnique(
      this.availability.map((entry) => entry.id),
      'availability window',
    );
    _placeIds = _checkUnique(
      this.places.map((entry) => entry.id),
      'saved place',
    );
    final values = <(String, String), Duration>{};
    for (final route in this.routes) {
      final key = (route.fromPlaceId, route.toPlaceId);
      if (!_placeIds.contains(route.fromPlaceId) ||
          !_placeIds.contains(route.toPlaceId) ||
          values.containsKey(key)) {
        throw ArgumentError(
          'Each travel direction must link two saved places once.',
        );
      }
      values[key] = Duration(minutes: route.minutes);
    }
    _travel = Map.unmodifiable(values);
    _clock = _AvailabilityClock(timeZoneId);
  }

  factory SchedulingSettings.fromJson(Map<String, Object?> json) =>
      SchedulingSettings(
        timeZoneId: json['timeZoneId'] as String?,
        availability: _decodeList(
          json['availability'],
          WeeklyAvailability.fromJson,
        ),
        places: _decodeList(json['places'], SavedPlace.fromJson),
        routes: _decodeList(json['routes'], TravelDuration.fromJson),
        beforeMinutes: json['beforeMinutes'] as int? ?? 0,
        afterMinutes: json['afterMinutes'] as int? ?? 0,
      );

  final String? timeZoneId;
  final List<WeeklyAvailability> availability;
  final List<SavedPlace> places;
  final List<TravelDuration> routes;
  final int beforeMinutes;
  final int afterMinutes;
  late final Set<String> _placeIds;
  late final Map<(String, String), Duration> _travel;
  late final _AvailabilityClock _clock;

  Map<String, Object?> toJson() => {
    if (timeZoneId != null) 'timeZoneId': timeZoneId,
    if (availability.isNotEmpty)
      'availability': availability.map((entry) => entry.toJson()).toList(),
    if (places.isNotEmpty)
      'places': places.map((entry) => entry.toJson()).toList(),
    if (routes.isNotEmpty)
      'routes': routes.map((entry) => entry.toJson()).toList(),
    if (beforeMinutes != 0) 'beforeMinutes': beforeMinutes,
    if (afterMinutes != 0) 'afterMinutes': afterMinutes,
  };

  Duration? travelDuration(String fromPlaceId, String toPlaceId) =>
      fromPlaceId == toPlaceId && _placeIds.contains(fromPlaceId)
      ? Duration.zero
      : _travel[(fromPlaceId, toPlaceId)];

  /// Applications supply actual task categories. Category-less weekly entries
  /// apply to every category; allowed windows add together and exclusions win.
  List<PlanningWindow> availabilityFor({
    required TimeSpan horizon,
    required Iterable<String> categories,
  }) {
    _checkHorizon(horizon);
    if (availability.isEmpty) return const [];
    final offsetSegments = _clock.segments(horizon);
    final days = _clock.civilBounds(offsetSegments);
    final projected = <({WeeklyAvailability entry, List<TimeSpan> spans})>[];
    for (final entry in availability) {
      final spans = <TimeSpan>[];
      for (
        var day = _plusDay(days.first, -1);
        !day.isAfter(days.last);
        day = _plusDay(day, 1)
      ) {
        if (!entry.weekdays.contains(day.weekday)) continue;
        final wallStart = day.add(Duration(minutes: entry.startMinute));
        final wallEnd = day.add(
          Duration(
            minutes: entry.endMinute + (entry.crossesMidnight ? 1440 : 0),
          ),
        );
        for (final segment in offsetSegments) {
          final actual = TimeSpan(
            wallStart.subtract(segment.offset),
            wallEnd.subtract(segment.offset),
          ).intersection(segment.span);
          if (actual != null) spans.add(actual);
        }
      }
      if (spans.isNotEmpty) projected.add((entry: entry, spans: spans));
    }
    final bySpan = <(DateTime, DateTime), Set<String>>{};
    for (final category in categories.toSet()) {
      final allowed = <TimeSpan>[];
      final excluded = <TimeSpan>[];
      for (final record in projected) {
        if (record.entry.categories?.contains(category) == false) continue;
        switch (record.entry.kind) {
          case AvailabilityKind.available:
            allowed.addAll(record.spans);
          case AvailabilityKind.unavailable:
            excluded.addAll(record.spans);
        }
      }
      for (final span in _subtractRanges(_merge(allowed), _merge(excluded))) {
        (bySpan[(span.start, span.end)] ??= {}).add(category);
      }
    }
    final windows = [
      for (final entry in bySpan.entries)
        PlanningWindow(
          TimeSpan(entry.key.$1, entry.key.$2),
          categories: entry.value,
        ),
    ]..sort((left, right) => _compareSpans(left.span, right.span));
    return List.unmodifiable(windows);
  }

  /// Apply explicit neighborhood travel and buffer values to fixed commitments.
  /// Adjacent commitments with two saved places and unknown travel keep their
  /// unresolved gap unavailable and return an issue without assigning a time.
  SchedulingInputs planningInputs({
    required TimeSpan horizon,
    required Iterable<String> categories,
    required Iterable<PlacedCommitment> commitments,
  }) {
    final windows = availabilityFor(horizon: horizon, categories: categories);
    final events = commitments.toList()
      ..sort((a, b) {
        final order = _compareSpans(a.span, b.span);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    _checkUnique(events.map((entry) => entry.id), 'fixed commitment');
    final placed = events.where((entry) => entry.placeId != null).toList();
    final issues = <TravelIssue>[];
    final blocked = <FixedCommitment>[];
    final travelBefore = <String, Duration>{};
    Duration before(PlacedCommitment item) =>
        Duration(minutes: item.beforeMinutes ?? beforeMinutes);
    Duration after(PlacedCommitment item) =>
        Duration(minutes: item.afterMinutes ?? afterMinutes);

    for (var index = 1; index < placed.length; index++) {
      final previous = placed[index - 1];
      final next = placed[index];
      final from = previous.placeId!;
      final to = next.placeId!;
      final configured = travelDuration(from, to);
      final availableGap = next.span.start.difference(previous.span.end);
      final needed = configured == null
          ? null
          : configured + after(previous) + before(next);
      if (configured != null) travelBefore[next.id] = configured;
      if (from == to || (needed != null && availableGap >= needed)) continue;
      final intervalStart = needed == null
          ? (previous.span.end.isBefore(next.span.start)
                ? previous.span.end
                : next.span.start)
          : next.span.start.subtract(needed);
      if (intervalStart.isBefore(horizon.end) &&
          next.span.start.isAfter(horizon.start)) {
        issues.add(
          TravelIssue._(
            kind: needed == null
                ? TravelIssueKind.missingDuration
                : TravelIssueKind.insufficientGap,
            fromCommitmentId: previous.id,
            toCommitmentId: next.id,
            fromPlaceId: from,
            toPlaceId: to,
            requiredGap: needed,
          ),
        );
      }
      if (needed == null && availableGap > Duration.zero) {
        final gap = TimeSpan(
          previous.span.end,
          next.span.start,
        ).intersection(horizon);
        if (gap != null) blocked.add(FixedCommitment(gap));
      }
    }

    for (final event in events) {
      final entrance =
          before(event) + (travelBefore[event.id] ?? Duration.zero);
      final departure = after(event);
      if (event.span.start.subtract(entrance).isBefore(horizon.end) &&
          event.span.end.add(departure).isAfter(horizon.start)) {
        blocked.add(
          FixedCommitment(event.span, before: entrance, after: departure),
        );
      }
    }
    blocked.sort((a, b) => _compareSpans(a.span, b.span));
    return SchedulingInputs._(
      availability: windows,
      commitments: blocked,
      travelIssues: issues,
    );
  }
}

String newSchedulingEntryId() {
  final random = Random.secure();
  return List.generate(
    12,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

typedef _OffsetSegment = ({TimeSpan span, Duration offset});

class _AvailabilityClock {
  _AvailabilityClock(String? zoneId)
    : location = zoneId == null ? null : _readLocation(zoneId);

  final timezone.Location? location;

  static timezone.Location _readLocation(String zoneId) {
    if (timezone.timeZoneDatabase.locations.isEmpty) {
      timezone_data.initializeTimeZones();
    }
    return timezone.timeZoneDatabase.locations[zoneId] ??
        (throw ArgumentError('Choose a valid IANA time zone.'));
  }

  ({DateTime first, DateTime last}) civilBounds(List<_OffsetSegment> segments) {
    DateTime date(DateTime instant, Duration offset) {
      final local = instant.toUtc().add(offset);
      return DateTime.utc(local.year, local.month, local.day);
    }

    var first = date(segments.first.span.start, segments.first.offset);
    var last = first;
    for (final segment in segments) {
      final begin = date(segment.span.start, segment.offset);
      final end = date(
        segment.span.end.subtract(const Duration(microseconds: 1)),
        segment.offset,
      );
      if (begin.isBefore(first)) first = begin;
      if (end.isAfter(last)) last = end;
    }
    return (first: first, last: last);
  }

  Duration _offsetAt(DateTime instant) {
    final named = location;
    return named == null
        ? instant.toLocal().timeZoneOffset
        : named.timeZone(instant.millisecondsSinceEpoch).offset;
  }

  List<_OffsetSegment> segments(TimeSpan horizon) {
    final start = horizon.start.toUtc();
    final end = horizon.end.toUtc();
    final named = location;
    final changes = named == null
        ? _deviceChanges(start, end)
        : _namedChanges(named, start, end);
    var cursor = start;
    final output = <_OffsetSegment>[];
    for (final boundary in [...changes, end]) {
      output.add((span: TimeSpan(cursor, boundary), offset: _offsetAt(cursor)));
      cursor = boundary;
    }
    return output;
  }

  Iterable<DateTime> _namedChanges(
    timezone.Location zone,
    DateTime start,
    DateTime end,
  ) sync* {
    var cursor = start;
    while (cursor.isBefore(end)) {
      final periods = zone.lookupTimeZone(cursor.millisecondsSinceEpoch);
      if (periods.end > end.millisecondsSinceEpoch) return;
      cursor = DateTime.fromMillisecondsSinceEpoch(periods.end, isUtc: true);
      if (cursor.isAfter(start) && cursor.isBefore(end)) yield cursor;
    }
  }

  Iterable<DateTime> _deviceChanges(DateTime start, DateTime end) sync* {
    const stride = Duration(minutes: 30);
    var left = start;
    var offset = _offsetAt(left);
    while (left.isBefore(end)) {
      final next = left.add(stride);
      final right = next.isBefore(end) ? next : end;
      final nextOffset = _offsetAt(right);
      if (offset != nextOffset) {
        var low = left.microsecondsSinceEpoch;
        var high = right.microsecondsSinceEpoch;
        while (high - low > 1) {
          final middle = low + (high - low) ~/ 2;
          final instant = DateTime.fromMicrosecondsSinceEpoch(
            middle,
            isUtc: true,
          );
          if (_offsetAt(instant) == offset) {
            low = middle;
          } else {
            high = middle;
          }
        }
        final transition = DateTime.fromMicrosecondsSinceEpoch(
          high,
          isUtc: true,
        );
        if (transition.isBefore(end)) yield transition;
      }
      left = right;
      offset = nextOffset;
    }
  }
}

void _checkHorizon(TimeSpan span) {
  if (span.length > const Duration(days: maxPlanningWindowDays) ||
      span.start.year < 1 ||
      span.end.year > 9999) {
    throw ArgumentError(
      'Choose a scheduling range of up to $maxPlanningWindowDays days.',
    );
  }
}

void _checkMinutes(int value) {
  if (value < 0 || value > maxSchedulingBufferMinutes) {
    throw ArgumentError(
      'Use a whole number of minutes from 0 to $maxSchedulingBufferMinutes.',
    );
  }
}

Set<String> _checkUnique(Iterable<String> values, String field) {
  final unique = <String>{};
  for (final value in values) {
    if (!unique.add(value)) throw ArgumentError('Duplicate $field ID.');
  }
  return unique;
}

List<T> _decodeList<T>(
  Object? value,
  T Function(Map<String, Object?>) decode,
) => (value as List<Object?>? ?? const [])
    .map((entry) => decode(entry as Map<String, Object?>))
    .toList();

DateTime _plusDay(DateTime date, int days) => date.add(Duration(days: days));

int _compareSpans(TimeSpan left, TimeSpan right) {
  final start = left.start.compareTo(right.start);
  return start != 0 ? start : left.end.compareTo(right.end);
}

List<TimeSpan> _merge(List<TimeSpan> values) {
  if (values.isEmpty) return const [];
  values.sort(_compareSpans);
  final merged = <TimeSpan>[values.first];
  for (final value in values.skip(1)) {
    final last = merged.last;
    if (value.start.isAfter(last.end)) {
      merged.add(value);
    } else if (value.end.isAfter(last.end)) {
      merged[merged.length - 1] = TimeSpan(last.start, value.end);
    }
  }
  return merged;
}

Iterable<TimeSpan> _subtractRanges(
  List<TimeSpan> allowed,
  List<TimeSpan> excluded,
) sync* {
  var next = 0;
  for (final span in allowed) {
    var cursor = span.start;
    while (next < excluded.length && !excluded[next].end.isAfter(cursor)) {
      next++;
    }
    for (
      var index = next;
      index < excluded.length && excluded[index].start.isBefore(span.end);
      index++
    ) {
      final denied = excluded[index];
      if (denied.start.isAfter(cursor)) yield TimeSpan(cursor, denied.start);
      if (denied.end.isAfter(cursor)) cursor = denied.end;
      if (!cursor.isBefore(span.end)) break;
    }
    if (cursor.isBefore(span.end)) yield TimeSpan(cursor, span.end);
  }
}
