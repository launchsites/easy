import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'ics_calendar.dart';
import 'ics_occurrence_expander.dart';

enum InternalRecurrenceFrequency { daily, weekly, monthly, yearly }

enum InternalOccurrenceScope { one, future, series }

class InternalRecurrenceRule {
  InternalRecurrenceRule({
    required this.frequency,
    this.interval = 1,
    Iterable<int> weekdays = const [],
    this.count,
    DateTime? until,
  }) : weekdays = List.unmodifiable(weekdays.toSet().toList()..sort()),
       until = until == null ? null : _day(until) {
    if (interval < 1) throw ArgumentError('Use a positive repeat interval.');
    if (this.weekdays.any(
          (day) => day < DateTime.monday || day > DateTime.sunday,
        ) ||
        (frequency != InternalRecurrenceFrequency.weekly &&
            this.weekdays.isNotEmpty)) {
      throw ArgumentError('Choose weekdays for a weekly recurrence.');
    }
    if (count != null && (count! < 1 || count! > 10000 || until != null)) {
      throw ArgumentError('Choose up to 10,000 occurrences or an end date.');
    }
  }

  factory InternalRecurrenceRule.fromJson(Map<String, Object?> json) =>
      InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.values.byName(
          json['frequency'] as String,
        ),
        interval: json['interval'] as int? ?? 1,
        weekdays: (json['weekdays'] as List<Object?>? ?? const []).cast<int>(),
        count: json['count'] as int?,
        until: json['until'] == null ? null : _readDate(json['until']),
      );

  final InternalRecurrenceFrequency frequency;
  final int interval;
  final List<int> weekdays;
  final int? count;

  /// Inclusive last civil start date in the series' own time basis.
  final DateTime? until;

  Map<String, Object?> toJson() => {
    'frequency': frequency.name,
    'interval': interval,
    if (weekdays.isNotEmpty) 'weekdays': weekdays,
    if (count != null) 'count': count,
    if (until != null) 'until': until!.toIso8601String(),
  };

  String get _ics => _icsRule(count: count);

  String _icsRule({int? count, String? until}) => [
    'FREQ=${frequency.name.toUpperCase()}',
    if (interval != 1) 'INTERVAL=$interval',
    if (weekdays.isNotEmpty)
      'BYDAY=${weekdays.map((day) => _weekdayNames[day - 1]).join(',')}',
    if (count != null) 'COUNT=$count',
    if (until != null) 'UNTIL=$until',
  ].join(';');

  InternalRecurrenceRule _withCount(int value) => InternalRecurrenceRule(
    frequency: frequency,
    interval: interval,
    weekdays: weekdays,
    count: value,
  );

  @override
  bool operator ==(Object other) =>
      other is InternalRecurrenceRule &&
      other.frequency == frequency &&
      other.interval == interval &&
      other.until == until &&
      other.count == count &&
      other.weekdays.join(',') == weekdays.join(',');

  @override
  int get hashCode =>
      Object.hash(frequency, interval, until, count, Object.hashAll(weekdays));
}

const _weekdayNames = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// A local event with its original calendar type and wall-clock basis.
class InternalEventDraft {
  InternalEventDraft({
    required this.title,
    required this.start,
    required this.end,
    required this.category,
    this.location,
    this.description,
    this.plannedTaskId,
  }) {
    if (title.trim().isEmpty) throw ArgumentError('Enter an event title.');
    if (start.kind != end.kind || start.timeZoneId != end.timeZoneId) {
      throw ArgumentError('Use the same time basis for the start and end.');
    }
    if (!end.components.isAfter(start.components)) {
      throw ArgumentError('Choose a later end.');
    }
  }

  factory InternalEventDraft.fromDates({
    required String title,
    required DateTime start,
    required DateTime end,
    required String category,
    bool allDay = false,
    String? timeZoneId,
    String? location,
    String? description,
    String? plannedTaskId,
  }) {
    IcsDateTime convert(DateTime value) => allDay
        ? IcsDateTime.date(value)
        : timeZoneId != null
        ? IcsDateTime.zoned(value, timeZoneId)
        : start.isUtc
        ? IcsDateTime.utc(value)
        : IcsDateTime.floating(value.toLocal());
    return InternalEventDraft(
      title: title,
      start: convert(start),
      end: convert(end),
      category: category,
      location: location,
      description: description,
      plannedTaskId: plannedTaskId,
    );
  }

  factory InternalEventDraft.fromJson(Map<String, Object?> json) =>
      InternalEventDraft(
        title: json['title'] as String,
        start: _readTime(json['start']),
        end: _readTime(json['end']),
        category: json['category'] as String,
        location: json['location'] as String?,
        description: json['description'] as String?,
        plannedTaskId: json['plannedTaskId'] as String?,
      );

  final String title;
  final IcsDateTime start;
  final IcsDateTime end;
  final String category;
  final String? location;
  final String? description;
  final String? plannedTaskId;

  bool get allDay => start.kind == IcsDateTimeKind.date;

  Map<String, Object?> toJson() => {
    'title': title,
    'start': _timeJson(start),
    'end': _timeJson(end),
    'category': category,
    if (location != null) 'location': location,
    if (description != null) 'description': description,
    if (plannedTaskId != null) 'plannedTaskId': plannedTaskId,
  };

  InternalEventDraft _withTimes(IcsDateTime begin, IcsDateTime finish) =>
      InternalEventDraft(
        title: title,
        start: begin,
        end: finish,
        category: category,
        location: location,
        description: description,
        plannedTaskId: plannedTaskId,
      );

  InternalEventDraft _applyDetails(
    InternalEventDraft before,
    InternalEventDraft edited,
  ) => InternalEventDraft(
    title: edited.title == before.title ? title : edited.title,
    start: start,
    end: end,
    category: edited.category == before.category ? category : edited.category,
    location: edited.location == before.location ? location : edited.location,
    description: edited.description == before.description
        ? description
        : edited.description,
    plannedTaskId: edited.plannedTaskId == before.plannedTaskId
        ? plannedTaskId
        : edited.plannedTaskId,
  );

  InternalEventDraft _shiftDays(int days) => _withTimes(
    _atComponents(start, start.components.add(Duration(days: days))),
    _atComponents(end, end.components.add(Duration(days: days))),
  );

  IcsEvent _master(String id, [InternalRecurrenceRule? recurrence]) => IcsEvent(
    uid: id,
    summary: title,
    start: start,
    end: end,
    recurrenceRule: recurrence?._ics,
    location: location,
    description: description,
  );
}

class InternalEventOccurrence {
  const InternalEventOccurrence._({
    required this.seriesId,
    required this.identityDate,
    required this.scheduledStart,
    required this.event,
    required this.rule,
    required this.start,
    required this.end,
    required this._revision,
    required this._floatingTimeZone,
  });

  final String seriesId;
  final DateTime identityDate;
  final IcsDateTime scheduledStart;
  final InternalEventDraft event;
  final InternalRecurrenceRule rule;
  final DateTime start;
  final DateTime end;
  final int _revision;
  final String? _floatingTimeZone;

  String get id =>
      'internal-recurring/${Uri.encodeComponent(seriesId)}/${identityDate.toIso8601String().split('T').first}';
  bool get allDay => event.allDay;
}

class InternalRecurringEvent {
  InternalRecurringEvent({
    required String id,
    required InternalEventDraft event,
    required InternalRecurrenceRule rule,
  }) : this._(
         id,
         0,
         [_Segment(_day(event.start.components), event, rule)],
         const {},
         null,
       );

  InternalRecurringEvent._(
    this.id,
    this.revision,
    Iterable<_Segment> segments,
    Map<DateTime, _OccurrenceOverride> overrides,
    this._cutoff,
  ) : _segments = List.unmodifiable(segments),
      _overrides = Map.unmodifiable(overrides) {
    if (id.trim().isEmpty || revision < 0 || _segments.isEmpty) {
      throw const FormatException('Invalid recurring event identity.');
    }
    for (var index = 1; index < _segments.length; index++) {
      if (!_segments[index].firstIdentity.isAfter(
        _segments[index - 1].firstIdentity,
      )) {
        throw const FormatException(
          'Recurring event segments are out of order.',
        );
      }
    }
  }

  factory InternalRecurringEvent.fromJson(Map<String, Object?> json) {
    final overrides = <DateTime, _OccurrenceOverride>{};
    for (final raw in json['overrides'] as List<Object?>? ?? const []) {
      final record = raw as Map<String, Object?>;
      final date = _readDate(record['date']);
      if (overrides.containsKey(date)) {
        throw const FormatException('Duplicate occurrence override.');
      }
      overrides[date] = _OccurrenceOverride(
        _readTime(record['scheduledStart']),
        record['event'] == null
            ? null
            : InternalEventDraft.fromJson(
                record['event'] as Map<String, Object?>,
              ),
      );
    }
    return InternalRecurringEvent._(
      json['id'] as String,
      json['revision'] as int? ?? 0,
      (json['segments'] as List<Object?>).map(
        (value) => _Segment.fromJson(value as Map<String, Object?>),
      ),
      overrides,
      json['cutoff'] == null ? null : _readDate(json['cutoff']),
    );
  }

  final String id;
  final int revision;
  final List<_Segment> _segments;
  final Map<DateTime, _OccurrenceOverride> _overrides;
  final DateTime? _cutoff;

  InternalEventDraft get event => _segments.first.event;
  InternalRecurrenceRule get rule => _segments.first.rule;

  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'segments': _segments.map((segment) => segment.toJson()).toList(),
    'overrides': [
      for (final entry in _overrides.entries)
        {
          'date': entry.key.toIso8601String(),
          'scheduledStart': _timeJson(entry.value.scheduledStart),
          if (entry.value.event case final event?) 'event': event.toJson(),
        },
    ],
    if (_cutoff != null) 'cutoff': _cutoff.toIso8601String(),
  };

  /// Calendar snapshot with a stable master UID for each active segment.
  /// A future pattern change is a new master because it cannot be represented
  /// by a detached RFC 5545 RANGE edit. Local series and occurrence IDs are
  /// untouched. The returned events can be combined with standalone exports.
  List<IcsEvent> toIcsEvents({String? floatingTimeZone}) {
    final events = <IcsEvent>[];
    final overrides = _overrides.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final (index, segment) in _segments.indexed) {
      if (_cutoff != null && !segment.firstIdentity.isBefore(_cutoff)) break;
      final next = index + 1 < _segments.length
          ? _segments[index + 1].firstIdentity
          : null;
      final boundary = _earlierDay(next, _cutoff);
      final event = segment.event;
      final uid = index == 0
          ? 'easy-series/${Uri.encodeComponent(id)}@calendar.easy'
          : 'easy-series/${Uri.encodeComponent(id)}/${_icalDate(segment.firstIdentity)}@calendar.easy';
      _validatePortableDraft(event, uid, floatingTimeZone);

      final rule = segment.rule;
      final truncation = boundary == null
          ? null
          : segment
                .scheduledOn(boundary)
                .components
                .subtract(const Duration(days: 1));
      final last = _earlierDay(
        rule.until,
        truncation == null ? null : _day(truncation),
      );
      final counted = rule.count;
      // Avoid putting COUNT and UNTIL on the same RFC rule. A counted arm
      // retains the exact number of nominal starts before its local split.
      final cutoffCount = counted != null && boundary != null
          ? _countBefore(segment, boundary, floatingTimeZone)
          : counted;
      final exportRule = rule._icsRule(
        count: cutoffCount,
        until: last == null || counted != null
            ? null
            : _exportUntil(event.start, last),
      );

      final detached = <IcsEvent>[];
      final excluded = <IcsDateTime>[];
      final extra = <IcsDateTime>[];
      for (final entry in overrides) {
        final identity = entry.key;
        if (identity.isBefore(segment.firstIdentity) ||
            (boundary != null && !identity.isBefore(boundary))) {
          continue;
        }
        final original = segment.scheduledOn(identity);
        final changed = entry.value.event;
        // The current segment time can differ from the time at which the
        // exception was made. Only the logical day is stable locally.
        final hasClock = _hasPortableClock(original, floatingTimeZone);
        if (!hasClock && original.kind == IcsDateTimeKind.floating) {
          throw IcsExpansionException(
            'A floating recurrence exception falls in a skipped local clock time.',
            uid: uid,
          );
        }
        if (changed == null) {
          if (!hasClock) continue;
          excluded.add(original);
          detached.add(
            IcsEvent(
              uid: uid,
              summary: event.title,
              start: original,
              recurrenceId: original,
              status: 'CANCELLED',
            ),
          );
          continue;
        }
        _validatePortableDraft(changed, uid, floatingTimeZone);
        if (!hasClock) {
          // A retained exception can outlive a nominal local clock skipped by
          // DST. A standalone stable UID preserves the moved event itself.
          detached.add(changed._master('$uid/override/${_icalDate(identity)}'));
          continue;
        }
        // RDATE makes a retained exception portable even when a subsequent
        // segment change removed that logical day from the regular cadence.
        extra.add(original);
        detached.add(
          IcsEvent(
            uid: uid,
            summary: changed.title,
            start: changed.start,
            end: changed.end,
            location: changed.location,
            description: changed.description,
            recurrenceId: original,
          ),
        );
      }
      events.add(
        IcsEvent(
          uid: uid,
          summary: event.title,
          start: event.start,
          end: event.end,
          location: event.location,
          description: event.description,
          recurrenceRule: exportRule,
          recurrenceDates: extra,
          exceptionDates: excluded,
        ),
      );
      events.addAll(detached);
    }
    return List.unmodifiable(events);
  }

  List<InternalEventOccurrence> occurrences({
    required DateTime windowStart,
    required DateTime windowEnd,
    String? floatingTimeZone,
    int limit = 10000,
  }) {
    if (!windowEnd.isAfter(windowStart) ||
        windowEnd.difference(windowStart) > const Duration(days: 367) ||
        limit < 1 ||
        limit > 100000) {
      throw ArgumentError(
        'Choose a positive calendar window of at most 367 days and a valid limit.',
      );
    }
    final output = <InternalEventOccurrence>[];
    void include(InternalEventOccurrence occurrence) {
      if (output.length >= limit) {
        throw IcsExpansionException(
          'Too many occurrences in this event window.',
          uid: id,
        );
      }
      output.add(occurrence);
    }

    for (final (index, segment) in _segments.indexed) {
      if (_cutoff != null && !segment.firstIdentity.isBefore(_cutoff)) break;
      final next = index + 1 < _segments.length
          ? _segments[index + 1].firstIdentity
          : null;
      for (final occurrence in _expand(
        segment.event,
        segment.rule,
        windowStart,
        windowEnd,
        floatingTimeZone,
      )) {
        final scheduled = occurrence.recurrenceId ?? segment.event.start;
        final identity = segment.identityOf(scheduled);
        final until = segment.rule.until;
        if ((next != null && !identity.isBefore(next)) ||
            (_cutoff != null && !identity.isBefore(_cutoff)) ||
            _overrides.containsKey(identity) ||
            (until != null && _day(scheduled.components).isAfter(until))) {
          continue;
        }
        include(
          _occurrence(
            identity,
            scheduled,
            segment.rule,
            segment.event,
            occurrence,
            floatingTimeZone,
          ),
        );
      }
    }
    for (final entry in _overrides.entries) {
      final changed = entry.value.event;
      final segment = changed == null ? null : _segmentAt(entry.key);
      if (changed == null || segment == null) continue;
      for (final occurrence in _expand(
        changed,
        null,
        windowStart,
        windowEnd,
        floatingTimeZone,
      )) {
        include(
          _occurrence(
            entry.key,
            entry.value.scheduledStart,
            segment.rule,
            changed,
            occurrence,
            floatingTimeZone,
          ),
        );
      }
    }
    output.sort((a, b) {
      final order = a.start.compareTo(b.start);
      return order == 0 ? a.identityDate.compareTo(b.identityDate) : order;
    });
    return List.unmodifiable(output);
  }

  /// A one-off edit retains the original identity. Replacing a rule replaces
  /// individual exceptions in the edited scope as part of that new schedule.
  InternalRecurringEvent edit(
    InternalEventOccurrence occurrence, {
    required InternalOccurrenceScope scope,
    required InternalEventDraft event,
    InternalRecurrenceRule? rule,
  }) {
    final previous = _requireCurrent(occurrence);
    final date = occurrence.identityDate;
    if (scope == InternalOccurrenceScope.one) {
      if (rule != null) {
        throw ArgumentError(
          'A single occurrence cannot change the repeat rule.',
        );
      }
      return _updated(_segments, {
        ..._overrides,
        date: _OccurrenceOverride(occurrence.scheduledStart, event),
      }, _cutoff);
    }
    final first = _segments.first.firstIdentity;
    final boundary = scope == InternalOccurrenceScope.future ? date : first;
    final previousRule = scope == InternalOccurrenceScope.future
        ? previous.rule
        : this.rule;
    final replacesRule = rule != null && rule != previousRule;
    final before = occurrence.event;
    final detailsOnly =
        !replacesRule && event.start == before.start && event.end == before.end;
    if (detailsOnly && scope == InternalOccurrenceScope.series) {
      return _updated(
        [for (final segment in _segments) segment.withDetails(before, event)],
        {
          for (final entry in _overrides.entries)
            entry.key: entry.value.withDetails(before, event),
        },
        _cutoff,
      );
    }
    var newRule = rule ?? previousRule;
    var anchor = event;
    if (_overrides.containsKey(date) &&
        event.start == occurrence.event.start &&
        event.end == occurrence.event.end) {
      final scheduled = previous.scheduledOn(date);
      final offset = scheduled.components.difference(
        previous.event.start.components,
      );
      anchor = event._withTimes(
        scheduled,
        _atComponents(
          previous.event.end,
          previous.event.end.components.add(offset),
        ),
      );
    }
    if (scope == InternalOccurrenceScope.future &&
        !replacesRule &&
        previousRule.count != null) {
      newRule = newRule._withCount(_remainingCount(previous, occurrence));
    }
    if (scope == InternalOccurrenceScope.series) {
      anchor = anchor._shiftDays(-date.difference(first).inDays);
    }
    if (detailsOnly) {
      anchor = previous.event
          ._applyDetails(before, event)
          ._withTimes(anchor.start, anchor.end);
    }
    return _updated(
      [
        for (final segment in _segments)
          if (segment.firstIdentity.isBefore(boundary)) segment,
        _Segment(boundary, anchor, newRule),
        if (detailsOnly)
          for (final segment in _segments)
            if (segment.firstIdentity.isAfter(boundary))
              segment.withDetails(before, event),
      ],
      {
        for (final entry in _overrides.entries)
          if (entry.key.isBefore(boundary))
            entry.key: entry.value
          else if (detailsOnly)
            entry.key: entry.value.withDetails(before, event)
          else if (!replacesRule && entry.key != date)
            entry.key: entry.value,
      },
      _cutoff,
    );
  }

  InternalRecurringEvent skip(
    InternalEventOccurrence occurrence, {
    required InternalOccurrenceScope scope,
  }) {
    _requireCurrent(occurrence);
    if (scope == InternalOccurrenceScope.one) {
      return _updated(_segments, {
        ..._overrides,
        occurrence.identityDate: _OccurrenceOverride(
          occurrence.scheduledStart,
          null,
        ),
      }, _cutoff);
    }
    final cutoff = scope == InternalOccurrenceScope.series
        ? _segments.first.firstIdentity
        : occurrence.identityDate;
    return _updated(
      [
        _segments.first,
        for (final segment in _segments.skip(1))
          if (segment.firstIdentity.isBefore(cutoff)) segment,
      ],
      {
        for (final entry in _overrides.entries)
          if (entry.key.isBefore(cutoff)) entry.key: entry.value,
      },
      cutoff,
    );
  }

  InternalRecurringEvent _updated(
    Iterable<_Segment> segments,
    Map<DateTime, _OccurrenceOverride> overrides,
    DateTime? cutoff,
  ) => InternalRecurringEvent._(id, revision + 1, segments, overrides, cutoff);

  Iterable<IcsOccurrence> _expand(
    InternalEventDraft event,
    InternalRecurrenceRule? rule,
    DateTime start,
    DateTime end,
    String? zone,
  ) => expandIcsCalendar(
    IcsCalendar(events: [event._master(id, rule)]),
    windowStart: start,
    windowEnd: end,
    floatingTimeZone: zone,
  );

  _Segment? _segmentAt(DateTime date) {
    if (_cutoff != null && !date.isBefore(_cutoff)) return null;
    return _segments.reversed
        .where((segment) => !segment.firstIdentity.isAfter(date))
        .firstOrNull;
  }

  _Segment _requireCurrent(InternalEventOccurrence occurrence) {
    final segment = _segmentAt(occurrence.identityDate);
    if (occurrence.seriesId != id ||
        occurrence._revision != revision ||
        segment == null) {
      throw StateError(
        'The recurring event changed. Open the occurrence again.',
      );
    }
    return segment;
  }

  int _remainingCount(_Segment segment, InternalEventOccurrence selected) {
    final remaining =
        segment.rule.count! -
        _countBefore(
          segment,
          selected.identityDate,
          selected._floatingTimeZone,
        );
    if (remaining < 1) {
      throw StateError(
        'The recurring event changed. Open the occurrence again.',
      );
    }
    return remaining;
  }

  int _countBefore(_Segment segment, DateTime boundary, String? zone) {
    if (!boundary.isAfter(segment.firstIdentity)) return 0;
    if (segment.rule.count == 1) return 1;
    final begin = _day(segment.event.start.components)
        .subtract(const Duration(days: 2));
    final end = _day(segment.scheduledOn(boundary).components)
        .add(const Duration(days: 2));
    final safeBegin = begin.year < 1 ? DateTime.utc(1) : begin;
    final safeEnd = end.isAfter(DateTime.utc(10000))
        ? DateTime.utc(10000)
        : end;
    final counted = <DateTime>{};
    var start = safeBegin;
    var scans = 0;
    while (start.isBefore(safeEnd) && counted.length < segment.rule.count!) {
      if (++scans > 512) {
        throw IcsExpansionException(
          'The counted series is too long to measure at this date.',
          uid: id,
        );
      }
      final next = start.add(const Duration(days: 365));
      final windowEnd = next.isAfter(safeEnd) ? safeEnd : next;
      for (final occurrence in _expand(
        segment.event,
        segment.rule,
        start,
        windowEnd,
        zone,
      )) {
        final date = segment.identityOf(
          occurrence.recurrenceId ?? segment.event.start,
        );
        if (date.isBefore(boundary)) counted.add(date);
      }
      start = windowEnd;
    }
    return counted.length;
  }

  InternalEventOccurrence _occurrence(
    DateTime identity,
    IcsDateTime scheduled,
    InternalRecurrenceRule rule,
    InternalEventDraft template,
    IcsOccurrence value,
    String? floatingZone,
  ) {
    final begin = value.recurrenceId ?? template.start;
    final finish = _fromResolved(template.end, value.end, floatingZone);
    // A repeat during a clock fold can end at an earlier displayed clock time.
    final actualDraft = finish.components.isAfter(begin.components)
        ? template._withTimes(begin, finish)
        : template._withTimes(
            IcsDateTime.utc(value.start),
            IcsDateTime.utc(value.end),
          );
    return InternalEventOccurrence._(
      seriesId: id,
      identityDate: identity,
      scheduledStart: scheduled,
      rule: rule,
      start: value.start,
      end: value.end,
      revision: revision,
      floatingTimeZone: floatingZone,
      event: actualDraft,
    );
  }
}

class _Segment {
  _Segment(this.firstIdentity, this.event, this.rule) {
    final until = rule.until;
    if (until != null && until.isBefore(_day(event.start.components))) {
      throw ArgumentError(
        'The final repeat date must follow the first occurrence or fall on the same day.',
      );
    }
  }

  factory _Segment.fromJson(Map<String, Object?> json) => _Segment(
    _readDate(json['firstIdentity']),
    InternalEventDraft.fromJson(json['event'] as Map<String, Object?>),
    InternalRecurrenceRule.fromJson(json['rule'] as Map<String, Object?>),
  );

  final DateTime firstIdentity;
  final InternalEventDraft event;
  final InternalRecurrenceRule rule;

  DateTime identityOf(IcsDateTime scheduled) => firstIdentity.add(
    _day(scheduled.components).difference(_day(event.start.components)),
  );

  IcsDateTime scheduledOn(DateTime identity) => _atComponents(
    event.start,
    event.start.components.add(identity.difference(firstIdentity)),
  );

  _Segment withDetails(InternalEventDraft before, InternalEventDraft edited) =>
      _Segment(firstIdentity, event._applyDetails(before, edited), rule);

  Map<String, Object?> toJson() => {
    'firstIdentity': firstIdentity.toIso8601String(),
    'event': event.toJson(),
    'rule': rule.toJson(),
  };
}

class _OccurrenceOverride {
  const _OccurrenceOverride(this.scheduledStart, this.event);
  final IcsDateTime scheduledStart;
  final InternalEventDraft? event;

  _OccurrenceOverride withDetails(
    InternalEventDraft before,
    InternalEventDraft edited,
  ) =>
      _OccurrenceOverride(scheduledStart, event?._applyDetails(before, edited));
}

DateTime _day(DateTime date) => DateTime.utc(date.year, date.month, date.day);

DateTime _readDate(Object? raw) {
  final value = _readComponents(raw);
  if (value != _day(value)) {
    throw const FormatException('Expected a civil calendar date.');
  }
  return value;
}

DateTime _readComponents(Object? raw) {
  final date = raw is String ? DateTime.tryParse(raw) : null;
  if (date == null || !date.isUtc || date.toIso8601String() != raw) {
    throw const FormatException('Invalid calendar date or time.');
  }
  return date;
}

Map<String, Object?> _timeJson(IcsDateTime value) => {
  'kind': value.kind.name,
  'components': value.components.toIso8601String(),
  if (value.timeZoneId != null) 'zone': value.timeZoneId,
};

IcsDateTime _readTime(Object? raw) {
  final json = raw as Map<String, Object?>;
  final components = _readComponents(json['components']);
  final kind = IcsDateTimeKind.values.byName(json['kind'] as String);
  return switch (kind) {
    IcsDateTimeKind.date => IcsDateTime.date(components),
    IcsDateTimeKind.utc => IcsDateTime.utc(components),
    IcsDateTimeKind.floating => IcsDateTime.floating(components),
    IcsDateTimeKind.zoned => IcsDateTime.zoned(
      components,
      json['zone'] as String,
    ),
  };
}

IcsDateTime _atComponents(IcsDateTime original, DateTime components) =>
    switch (original.kind) {
      IcsDateTimeKind.date => IcsDateTime.date(components),
      IcsDateTimeKind.utc => IcsDateTime.utc(components),
      IcsDateTimeKind.floating => IcsDateTime.floating(components),
      IcsDateTimeKind.zoned => IcsDateTime.zoned(
        components,
        original.timeZoneId!,
      ),
    };

IcsDateTime _fromResolved(
  IcsDateTime pattern,
  DateTime instant,
  String? floatingZone,
) {
  if (pattern.kind == IcsDateTimeKind.date ||
      pattern.kind == IcsDateTimeKind.utc) {
    return _atComponents(pattern, instant);
  }
  final zone = pattern.timeZoneId ?? floatingZone;
  final clock = zone == null
      ? instant.toLocal()
      : timezone.TZDateTime.from(instant, timezone.getLocation(zone));
  return _atComponents(pattern, clock);
}

DateTime? _earlierDay(DateTime? left, DateTime? right) =>
    left == null || (right != null && right.isBefore(left)) ? right : left;

String _icalDate(DateTime value) =>
    value.toIso8601String().split('T').first.replaceAll('-', '');

String _icalClock(DateTime value) =>
    value.toIso8601String().split('.').first.replaceAll(RegExp('[-:]'), '');

String _exportUntil(IcsDateTime basis, DateTime last) {
  final wall = last.add(const Duration(hours: 23, minutes: 59, seconds: 59));
  return switch (basis.kind) {
    IcsDateTimeKind.date => _icalDate(last),
    IcsDateTimeKind.floating => _icalClock(wall),
    IcsDateTimeKind.utc => '${_icalClock(wall)}Z',
    IcsDateTimeKind.zoned =>
      '${_icalClock(_lastInstantAtOrBefore(wall, _portableZone(basis.timeZoneId!)))}Z',
  };
}

timezone.Location _portableZone(String name) {
  if (timezone.timeZoneDatabase.locations.isEmpty) {
    timezone_data.initializeTimeZones();
  }
  return timezone.timeZoneDatabase.locations[name] ??
      (throw IcsExpansionException('Unknown calendar time zone $name.'));
}

/// Find the last instant still on or before an inclusive wall-clock bound.
/// This handles offset changes at midnight and entirely skipped civil dates.
DateTime _lastInstantAtOrBefore(DateTime wall, timezone.Location zone) {
  const margin = Duration(days: 2);
  final end = wall.add(margin);
  var cursor = wall.subtract(margin);
  DateTime? latest;
  while (cursor.isBefore(end)) {
    final period = zone.lookupTimeZone(cursor.millisecondsSinceEpoch);
    final boundary = period.end >= end.millisecondsSinceEpoch
        ? end
        : DateTime.fromMillisecondsSinceEpoch(period.end, isUtc: true);
    final nominal = wall.subtract(period.timeZone.offset);
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
    throw const IcsExpansionException(
      'The last repeat is outside the portable calendar range.',
    );
  }
  return latest;
}

void _validatePortableDraft(
  InternalEventDraft draft,
  String uid,
  String? floatingZone,
) {
  if (!_hasPortableClock(draft.start, floatingZone) ||
      !_hasPortableClock(draft.end, floatingZone)) {
    throw IcsExpansionException(
      'An exported event time falls in a daylight-saving gap.',
      uid: uid,
    );
  }
}

bool _hasPortableClock(IcsDateTime value, String? floatingZone) {
  if (value.kind == IcsDateTimeKind.date || value.kind == IcsDateTimeKind.utc) {
    return true;
  }
  final name = value.timeZoneId ?? floatingZone;
  final zone = name == null ? null : _portableZone(name);
  final wall = value.components;
  DateTime clock(DateTime instant) => zone == null
      ? instant.toLocal()
      : timezone.TZDateTime.from(instant, zone);
  return [-2, 0, 2]
      .map((day) => clock(wall.add(Duration(days: day))).timeZoneOffset)
      .toSet()
      .any((offset) {
        final actual = clock(wall.subtract(offset));
        return actual.year == wall.year &&
            actual.month == wall.month &&
            actual.day == wall.day &&
            actual.hour == wall.hour &&
            actual.minute == wall.minute &&
            actual.second == wall.second;
      });
}
