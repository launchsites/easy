import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

part 'ics_zone_data.dart';

typedef _ZoneRuleFields = (
  int,
  int,
  int,
  List<int>,
  int,
  int,
  int,
  String,
  bool,
);
typedef _ZoneTransitionFields = (int, int, int, String, bool);
typedef IcsZoneState = ({int offset, String name, bool daylight});

final _continuationStart = DateTime.utc(2038);
const _weekdayNames = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const _clockMargin = Duration(days: 2);

/// A UTC transition and the offsets on either side, in whole seconds.
class IcsZoneTransition {
  const IcsZoneTransition(this.instant, this.before, this.after);

  final DateTime instant;
  final int before;
  final IcsZoneState after;

  DateTime get wallBefore => instant.add(Duration(seconds: before));
  DateTime get wallAfter => instant.add(Duration(seconds: after.offset));
}

/// Civil clock resolution shared by calendar interchange and recurrence.
abstract class IcsZone {
  Iterable<int> get offsets;
  int offsetAt(DateTime instant);
  Iterable<IcsZoneTransition> transitions(DateTime start, DateTime end);

  DateTime wallAt(DateTime instant) =>
      instant.toUtc().add(Duration(seconds: offsetAt(instant)));

  DateTime? resolve(DateTime wall) {
    DateTime? earlier;
    for (final offset in offsets) {
      final candidate = wall.subtract(Duration(seconds: offset));
      if (offsetAt(candidate) == offset &&
          (earlier == null || candidate.isBefore(earlier))) {
        earlier = candidate;
      }
    }
    return earlier;
  }

  /// First instant of a civil day, including a midnight clock gap.
  DateTime? startOfDay(DateTime wall) {
    if (resolve(wall) case final exact?) return exact;
    final nextDay = DateTime.utc(wall.year, wall.month, wall.day + 1);
    for (final change in transitions(
      wall.subtract(_clockMargin),
      wall.add(_clockMargin),
    )) {
      if (!change.wallBefore.isAfter(wall) &&
          change.wallAfter.isAfter(wall) &&
          change.wallAfter.isBefore(nextDay)) {
        return change.instant;
      }
    }
    return null;
  }

  /// Last instant on or before a civil bound, including a skipped date.
  DateTime latestAtOrBefore(DateTime wall) {
    final start = wall.subtract(_clockMargin);
    final end = wall.add(_clockMargin);
    var cursor = start;
    DateTime? latest;
    for (final boundary in [
      for (final change in transitions(start, end)) change.instant,
      end,
    ]) {
      if (!boundary.isAfter(cursor)) continue;
      final nominal = wall.subtract(Duration(seconds: offsetAt(cursor)));
      final candidate = nominal.isBefore(boundary)
          ? nominal
          : boundary.subtract(const Duration(seconds: 1));
      if (!candidate.isBefore(cursor) &&
          (latest == null || candidate.isAfter(latest))) {
        latest = candidate;
      }
      cursor = boundary;
    }
    if (latest == null || latest.year < 1 || latest.year > 9999) {
      throw const FormatException('Time outside the portable calendar range.');
    }
    return latest;
  }
}

final _rulesByName = {
  for (final (names, fields) in _recurringZones)
    for (final name in names) name: fields.map(_ZoneRule.new).toList(),
};

final _changesByName = {
  for (final (names, fields) in _extendedZones)
    for (final name in names)
      name: fields.map((entry) {
        final (at, before, offset, name, daylight) = entry;
        return IcsZoneTransition(
          DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true),
          before,
          (offset: offset, name: name, daylight: daylight),
        );
      }).toList(),
};

final _namedZones = <String, _IanaZone>{};

IcsZone? ianaCalendarZone(String name) => _ianaZone(name);

_IanaZone? _ianaZone(String name) {
  if (timezone.timeZoneDatabase.locations.isEmpty) {
    timezone_data.initializeTimeZones();
  }
  final location = timezone.timeZoneDatabase.locations[name];
  if (location == null) return null;
  return _namedZones.putIfAbsent(name, () => _IanaZone(name, location));
}

IcsZoneState _zoneState(timezone.TimeZone zone) => (
  offset: zone.offset.inSeconds,
  name: zone.abbreviation,
  daylight: zone.isDst,
);

class _IanaZone extends IcsZone {
  _IanaZone(this.name, this._location)
    : _rules = _rulesByName[name] ?? const [],
      _explicit = _changesByName[name] ?? const [];

  final String name;
  final timezone.Location _location;
  final List<_ZoneRule> _rules;
  final List<IcsZoneTransition> _explicit;

  late final DateTime _recurrenceStart = _explicit.isEmpty
      ? _continuationStart
      : _explicit.last.instant.add(const Duration(seconds: 1));

  late final IcsZoneState _cutoverState = _historicState(
    _continuationStart.subtract(const Duration(seconds: 1)),
  );

  @override
  late final Set<int> offsets = Set.unmodifiable({
    for (final zone in _location.zones) zone.offset.inSeconds,
    for (final transition in _explicit) transition.after.offset,
    for (final rule in _rules) rule.after.offset,
  });

  IcsZoneState _historicState(DateTime at) =>
      _zoneState(_location.timeZone(at.millisecondsSinceEpoch));

  IcsZoneState _stateAt(DateTime date) {
    final instant = date.toUtc();
    if (instant.isBefore(_continuationStart)) return _historicState(instant);
    for (final change in _recurringChanges(
      instant.year - 1,
      instant.year + 1,
    ).reversed) {
      if (!change.instant.isAfter(instant)) return change.after;
    }
    final index = _lastAtOrBefore(_explicit, instant);
    return index < 0 ? _cutoverState : _explicit[index].after;
  }

  @override
  int offsetAt(DateTime instant) => _stateAt(instant).offset;

  List<IcsZoneTransition> _recurringChanges(int firstYear, int lastYear) {
    if (_rules.isEmpty || lastYear < _recurrenceStart.year - 1) return const [];
    final result = <IcsZoneTransition>[];
    for (var year = firstYear; year <= lastYear; year++) {
      for (final rule in _rules) {
        final change = rule.transitionIn(year);
        if (change != null && !change.instant.isBefore(_recurrenceStart)) {
          result.add(change);
        }
      }
    }
    return result..sort((a, b) => a.instant.compareTo(b.instant));
  }

  Iterable<IcsZoneTransition> _historicChanges(
    DateTime start,
    DateTime end,
  ) sync* {
    for (final tick in _location.transitionAt) {
      if (tick < start.millisecondsSinceEpoch) continue;
      if (tick >= end.millisecondsSinceEpoch ||
          tick >= _continuationStart.millisecondsSinceEpoch) {
        break;
      }
      final at = DateTime.fromMillisecondsSinceEpoch(tick, isUtc: true);
      final before = _historicState(at.subtract(const Duration(seconds: 1)));
      final after = _historicState(at);
      if (before != after) yield IcsZoneTransition(at, before.offset, after);
    }
    for (final change in _explicit) {
      if (!change.instant.isBefore(start) && change.instant.isBefore(end)) {
        yield change;
      }
    }
  }

  @override
  Iterable<IcsZoneTransition> transitions(DateTime start, DateTime end) sync* {
    yield* _historicChanges(start, end);
    for (final change in _recurringChanges(
      start.toUtc().year - 1,
      end.toUtc().year + 1,
    )) {
      if (!change.instant.isBefore(start) && change.instant.isBefore(end)) {
        yield change;
      }
    }
  }

  Iterable<String> calendarLines(DateTime firstWall) sync* {
    // Include a baseline before the earliest reference and all later pinned
    // transitions. Continuations are expressed as rules, rather than an
    // arbitrary end date that would freeze the receiving calendar's clock.
    final year = firstWall.year > 1 ? firstWall.year - 1 : 1;
    final anchor = DateTime.utc(year);
    final afterAnchor = anchor.add(const Duration(seconds: 1));
    final baseline = _stateAt(anchor);
    final fixed = <({int before, IcsZoneState after}), List<DateTime>>{};
    for (final change in _historicChanges(afterAnchor, DateTime.utc(10000))) {
      if (change.wallBefore.year < 1 || change.wallBefore.year > 9999) continue;
      fixed
          .putIfAbsent((before: change.before, after: change.after), () => [])
          .add(change.wallBefore);
    }

    yield 'BEGIN:VTIMEZONE';
    yield 'TZID:$name';
    final initialWall = anchor.add(Duration(seconds: baseline.offset));
    yield* _zoneLines(
      initialWall.year < 1 ? DateTime.utc(1) : initialWall,
      baseline.offset,
      baseline,
    );
    for (final entry in fixed.entries) {
      yield* _zoneLines(
        entry.value.first,
        entry.key.before,
        entry.key.after,
        dates: entry.value.skip(1),
      );
    }
    for (final rule in _rules) {
      final first = rule.firstFrom(
        afterAnchor.isAfter(_recurrenceStart) ? afterAnchor : _recurrenceStart,
      );
      if (first != null && first.wallBefore.year <= 9999) {
        yield* _zoneLines(
          first.wallBefore,
          rule.before,
          rule.after,
          rule: rule.icalRule,
        );
      }
    }
    yield 'END:VTIMEZONE';
  }
}

int _lastAtOrBefore(List<IcsZoneTransition> values, DateTime instant) {
  var low = 0;
  var high = values.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (values[middle].instant.isAfter(instant)) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  return low - 1;
}

class _ZoneRule {
  _ZoneRule(this._fields);

  final _ZoneRuleFields _fields;

  int get month => _fields.$1;
  int get weekday => _fields.$2;
  int get ordinal => _fields.$3;
  List<int> get monthDays => _fields.$4;
  int get clock => _fields.$5;
  int get before => _fields.$6;
  IcsZoneState get after =>
      (offset: _fields.$7, name: _fields.$8, daylight: _fields.$9);

  String get icalRule => [
    'FREQ=YEARLY',
    'BYMONTH=$month',
    'BYDAY=${ordinal == 0 ? '' : ordinal}${_weekdayNames[weekday - 1]}',
    if (monthDays.isNotEmpty) 'BYMONTHDAY=${monthDays.join(',')}',
  ].join(';');

  IcsZoneTransition? transitionIn(int year) {
    final days = DateTime.utc(year, month + 1, 0).day;
    final int day;
    if (ordinal > 0) {
      final first = DateTime.utc(year, month);
      day = 1 + (weekday - first.weekday) % 7 + (ordinal - 1) * 7;
    } else if (ordinal < 0) {
      final last = DateTime.utc(year, month, days);
      day = days - (last.weekday - weekday) % 7 + (ordinal + 1) * 7;
    } else {
      final match = monthDays
          .where(
            (day) =>
                day <= days &&
                DateTime.utc(year, month, day).weekday == weekday,
          )
          .firstOrNull;
      if (match == null) return null;
      day = match;
    }
    if (day < 1 || day > days) return null;
    final instant = DateTime.utc(
      year,
      month,
      day,
    ).add(Duration(seconds: clock - before));
    return IcsZoneTransition(instant, before, after);
  }

  IcsZoneTransition? firstFrom(DateTime earliest) {
    for (var year = earliest.year - 1; year <= earliest.year + 28; year++) {
      final possible = transitionIn(year);
      if (possible != null && !possible.instant.isBefore(earliest)) {
        return possible;
      }
    }
    return null;
  }
}

String _icalClock(DateTime date) => [
  date.year.toString().padLeft(4, '0'),
  date.month.toString().padLeft(2, '0'),
  date.day.toString().padLeft(2, '0'),
  'T',
  date.hour.toString().padLeft(2, '0'),
  date.minute.toString().padLeft(2, '0'),
  date.second.toString().padLeft(2, '0'),
].join();

String _offset(int seconds) {
  final absolute = seconds.abs();
  final hours = absolute ~/ 3600;
  final minutes = absolute ~/ 60 % 60;
  final remainder = absolute % 60;
  return [
    if (seconds < 0) '-' else '+',
    hours.toString().padLeft(2, '0'),
    minutes.toString().padLeft(2, '0'),
    if (remainder != 0) remainder.toString().padLeft(2, '0'),
  ].join();
}

Iterable<String> _zoneLines(
  DateTime first,
  int before,
  IcsZoneState after, {
  Iterable<DateTime> dates = const [],
  String? rule,
}) sync* {
  final component = after.daylight ? 'DAYLIGHT' : 'STANDARD';
  yield 'BEGIN:$component';
  yield 'DTSTART:${_icalClock(first)}';
  yield 'TZOFFSETFROM:${_offset(before)}';
  yield 'TZOFFSETTO:${_offset(after.offset)}';
  if (after.name.isNotEmpty) yield 'TZNAME:${after.name}';
  if (dates.isNotEmpty) yield 'RDATE:${dates.map(_icalClock).join(',')}';
  if (rule != null) yield 'RRULE:$rule';
  yield 'END:$component';
}

Iterable<String> authoredCalendarZoneLines(
  Map<String, DateTime> references,
) sync* {
  for (final MapEntry(key: name, value: first) in references.entries) {
    final zone = _ianaZone(name);
    if (zone == null) {
      throw FormatException('Unknown calendar time zone $name.');
    }
    yield* zone.calendarLines(first);
  }
}
