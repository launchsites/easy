part of 'ics_occurrence_expander.dart';

/// A finite transition table plus the annual observances read from the file.
class _ImportedIcsZone extends IcsZone {
  _ImportedIcsZone(String id, List<IcsZoneObservance> observances) {
    final fixed = <IcsZoneTransition>[];
    for (final item in observances) {
      fixed.add(_asTransition(item, item.start));
      for (final wall in item.dates) {
        fixed.add(_asTransition(item, wall));
      }
      if (item.recurrence case final text?) {
        final annual = _ImportedAnnualRule(id, item, text);
        if (annual.rule.count case final count?) {
          fixed.addAll(annual.firstChanges(count - 1));
        } else {
          _annual.add(annual);
        }
      }
      if (fixed.length > 8192 || _annual.length > 32) {
        throw const IcsExpansionException('Too many time-zone transitions.');
      }
    }
    _fixed = _orderedZoneChanges(fixed);
    offsets = Set.unmodifiable({
      for (final item in observances) ...[item.offsetFrom, item.offsetTo],
    });
    if (offsets.length > 64) {
      throw const IcsExpansionException(
        'Too many different time-zone offsets.',
      );
    }
  }

  late final List<IcsZoneTransition> _fixed;
  final _annual = <_ImportedAnnualRule>[];

  /// Bounded year slices make multiple events in the same clock cheap.
  final _years = <int, ({int startOffset, List<IcsZoneTransition> changes})>{};

  @override
  late final Set<int> offsets;

  ({int startOffset, List<IcsZoneTransition> changes}) _year(int year) {
    if (_years.remove(year) case final existing?) {
      _years[year] = existing;
      return existing;
    }
    final start = DateTime.utc(year);
    final end = DateTime.utc(year + 1);
    final found = _zoneChangeIndex(_fixed, start);
    IcsZoneTransition? previous = found == 0 ? null : _fixed[found - 1];
    for (final rule in _annual) {
      final candidate = rule.latestBefore(start);
      if (candidate != null) {
        if (previous == null || candidate.instant.isAfter(previous.instant)) {
          previous = candidate;
        } else if (candidate.instant == previous.instant) {
          _checkAgreement(candidate, previous);
        }
      }
    }
    final candidates = [
      ..._fixed.getRange(found, _zoneChangeIndex(_fixed, end)),
    ];
    for (final rule in _annual) {
      for (final change in rule.changesBetween(start, end)) {
        if (candidates.length == 8192) {
          throw const IcsExpansionException(
            'Too many time-zone transitions in one year.',
          );
        }
        candidates.add(change);
      }
    }
    final value = (
      startOffset: previous?.after.offset ?? _fixed.first.before,
      changes: _orderedZoneChanges(candidates),
    );
    if (_years.length == 8) _years.remove(_years.keys.first);
    _years[year] = value;
    return value;
  }

  @override
  int offsetAt(DateTime instant) {
    final (:startOffset, :changes) = _year(instant.toUtc().year);
    final index = _zoneChangeIndex(
      changes,
      instant.add(const Duration(microseconds: 1)),
    );
    return index == 0 ? startOffset : changes[index - 1].after.offset;
  }

  @override
  Iterable<IcsZoneTransition> transitions(DateTime start, DateTime end) sync* {
    for (var year = start.toUtc().year; year <= end.toUtc().year; year++) {
      for (final change in _year(year).changes) {
        if (!change.instant.isBefore(start) && change.instant.isBefore(end)) {
          yield change;
        }
      }
    }
  }
}

class _ImportedAnnualRule {
  _ImportedAnnualRule(String id, this.item, String text)
    : rule = _RecurrenceRule.parse(
        IcsEvent(
          uid: id,
          start: IcsDateTime.floating(item.start),
          recurrenceRule: _localObservanceUntil(text, item.offsetFrom),
        ),
      ) {
    if (rule.frequency != _Frequency.yearly ||
        rule.interval > 400 ||
        (rule.count ?? 1) > 2048) {
      throw IcsExpansionException(
        'Unsupported time-zone observance rule.',
        uid: id,
      );
    }
  }

  final IcsZoneObservance item;
  final _RecurrenceRule rule;

  Iterable<IcsZoneTransition> firstChanges(int count) sync* {
    var emitted = 0;
    // Leap dates and ordinal weekdays repeat over the Gregorian 400-year
    // cycle. Empty rules have a hard ceiling instead of spinning forever.
    var emptyYears = 0;
    for (var year = item.start.year; year <= 9999; year += rule.interval) {
      if (emitted >= count || emptyYears == 401) return;
      var selected = false;
      for (final change in _inYear(year)) {
        if (emitted >= count) return;
        yield change;
        selected = true;
        emitted++;
      }
      emptyYears = selected ? 0 : emptyYears + 1;
    }
  }

  IcsZoneTransition? latestBefore(DateTime instant) {
    final local = instant.add(Duration(seconds: item.offsetFrom));
    final untilYear = rule.until?.components.year;
    final latestYear = untilYear == null
        ? local.year
        : math.min(untilYear, local.year);
    final anchor = item.start.year;
    if (latestYear < anchor) return null;
    var year = latestYear - (latestYear - anchor) % rule.interval;
    for (var attempts = 0; year >= anchor && attempts < 401; attempts++) {
      IcsZoneTransition? latest;
      for (final change in _inYear(year)) {
        if (!change.instant.isBefore(instant)) break;
        latest = change;
      }
      if (latest != null) return latest;
      year -= rule.interval;
    }
    return null;
  }

  Iterable<IcsZoneTransition> changesBetween(
    DateTime start,
    DateTime end,
  ) sync* {
    final shift = Duration(seconds: item.offsetFrom);
    final fromYear = start.add(shift).year;
    final untilYear = end.add(shift).year;
    for (var year = fromYear; year <= untilYear; year++) {
      if (year < item.start.year ||
          year > 9999 ||
          (year - item.start.year) % rule.interval != 0) {
        continue;
      }
      for (final change in _inYear(year)) {
        if (!change.instant.isBefore(start) && change.instant.isBefore(end)) {
          yield change;
        }
      }
    }
  }

  Iterable<IcsZoneTransition> _inYear(int year) sync* {
    final start = item.start;
    final dates = rule.datesIn(DateTime.utc(year), start);
    final selected = rule.positions.isEmpty
        ? dates
        : _pickPositions(dates.toList(), rule.positions);
    final until = rule.until?.components;
    for (final date in selected) {
      final wall = _atClock(date, start);
      if (wall.isAfter(start) && (until == null || !wall.isAfter(until))) {
        yield _asTransition(item, wall);
      }
    }
  }
}

IcsZoneTransition _asTransition(IcsZoneObservance item, DateTime wall) =>
    IcsZoneTransition(
      wall.subtract(Duration(seconds: item.offsetFrom)),
      item.offsetFrom,
      (offset: item.offsetTo, name: item.name, daylight: item.daylight),
    );

String _localObservanceUntil(String rule, int previousOffset) => [
  for (final part in rule.toUpperCase().split(';'))
    if (part.startsWith('UNTIL=') && part.endsWith('Z'))
      'UNTIL=${_observanceClock(IcsDateTime.parse(part.substring(6)).components.add(Duration(seconds: previousOffset)))}'
    else
      part,
].join(';');

String _observanceClock(DateTime value) =>
    value.toIso8601String().split('.').first.replaceAll(RegExp(r'[-:]'), '');

List<IcsZoneTransition> _orderedZoneChanges(List<IcsZoneTransition> changes) {
  changes.sort((first, last) => first.instant.compareTo(last.instant));
  final unique = <IcsZoneTransition>[];
  for (final next in changes) {
    if (unique.isNotEmpty && unique.last.instant == next.instant) {
      _checkAgreement(unique.last, next);
    } else {
      unique.add(next);
    }
  }
  return unique;
}

void _checkAgreement(IcsZoneTransition a, IcsZoneTransition b) {
  if (a.before != b.before || a.after.offset != b.after.offset) {
    throw const IcsExpansionException('Conflicting time-zone transitions.');
  }
}

int _zoneChangeIndex(List<IcsZoneTransition> changes, DateTime instant) {
  var low = 0;
  var high = changes.length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (changes[mid].instant.isBefore(instant)) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}
