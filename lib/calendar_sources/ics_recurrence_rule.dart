part of 'ics_occurrence_expander.dart';

enum _Frequency { daily, weekly, monthly, yearly }

const _weekdayNames = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
final _byDayPattern = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$');

class _RecurrenceRule {
  _RecurrenceRule({
    required this.frequency,
    required this.interval,
    required this.weekStart,
    required this.days,
    required this.monthDates,
    required this.months,
    required this.positions,
    this.count,
    this.until,
  });

  factory _RecurrenceRule.parse(IcsEvent event) {
    final fields = <String, String>{
      for (final part in event.recurrenceRule!.toUpperCase().split(';'))
        part.substring(0, part.indexOf('=')): part.substring(
          part.indexOf('=') + 1,
        ),
    };
    const supported = {
      'FREQ',
      'INTERVAL',
      'COUNT',
      'UNTIL',
      'BYDAY',
      'BYMONTHDAY',
      'BYMONTH',
      'BYSETPOS',
      'WKST',
    };
    for (final field in fields.keys) {
      if (!supported.contains(field)) {
        throw IcsExpansionException(
          'Unsupported recurrence field $field.',
          uid: event.uid,
        );
      }
    }
    final frequency = switch (fields['FREQ']) {
      'DAILY' => _Frequency.daily,
      'WEEKLY' => _Frequency.weekly,
      'MONTHLY' => _Frequency.monthly,
      'YEARLY' => _Frequency.yearly,
      final name => throw IcsExpansionException(
        'Unsupported recurrence frequency $name.',
        uid: event.uid,
      ),
    };
    final days = <({int weekday, int? ordinal})>{};
    for (final part in fields['BYDAY']?.split(',') ?? const <String>[]) {
      final match = _byDayPattern.firstMatch(part);
      if (match == null) {
        throw IcsExpansionException('Invalid BYDAY value.', uid: event.uid);
      }
      final ordinal = match[1] == null ? null : int.parse(match[1]!);
      if (ordinal != null &&
          (ordinal == 0 ||
              ordinal.abs() > 53 ||
              frequency == _Frequency.daily ||
              frequency == _Frequency.weekly)) {
        throw IcsExpansionException(
          'Unsupported ordinal in BYDAY.',
          uid: event.uid,
        );
      }
      days.add((
        weekday: _weekdayNames.indexOf(match[2]!) + 1,
        ordinal: ordinal,
      ));
    }
    final monthDates = _ruleNumbers(fields, 'BYMONTHDAY', -31, 31, event.uid);
    final months = _ruleNumbers(fields, 'BYMONTH', 1, 12, event.uid);
    final positions = _ruleNumbers(fields, 'BYSETPOS', -366, 366, event.uid);
    if (monthDates.isNotEmpty && frequency == _Frequency.weekly) {
      throw IcsExpansionException(
        'BYMONTHDAY is unsupported for a weekly rule.',
        uid: event.uid,
      );
    }
    if (positions.isNotEmpty &&
        days.isEmpty &&
        monthDates.isEmpty &&
        months.isEmpty) {
      throw IcsExpansionException(
        'BYSETPOS requires another BY field.',
        uid: event.uid,
      );
    }
    final weekStart = _weekdayNames.indexOf(fields['WKST'] ?? 'MO') + 1;
    if (weekStart == 0) {
      throw IcsExpansionException(
        'Invalid recurrence week start.',
        uid: event.uid,
      );
    }
    final until = fields['UNTIL'] == null
        ? null
        : IcsDateTime.parse(fields['UNTIL']!);
    final untilKind = switch (event.start.kind) {
      IcsDateTimeKind.date => IcsDateTimeKind.date,
      IcsDateTimeKind.floating => IcsDateTimeKind.floating,
      _ => IcsDateTimeKind.utc,
    };
    if (until != null && until.kind != untilKind) {
      throw IcsExpansionException(
        'UNTIL has an incompatible date or time type.',
        uid: event.uid,
      );
    }
    return _RecurrenceRule(
      frequency: frequency,
      interval: int.parse(fields['INTERVAL'] ?? '1'),
      count: int.tryParse(fields['COUNT'] ?? ''),
      until: until,
      weekStart: weekStart,
      days: days,
      monthDates: monthDates,
      months: months,
      positions: positions,
    );
  }

  final _Frequency frequency;
  final int interval;
  final int? count;
  final IcsDateTime? until;
  final int weekStart;
  final Set<({int weekday, int? ordinal})> days;
  final Set<int> monthDates;
  final Set<int> months;
  final Set<int> positions;

  DateTime firstPeriod(DateTime start) {
    final date = _civilDay(start);
    return switch (frequency) {
      _Frequency.daily => date,
      _Frequency.weekly => _addDays(date, -((date.weekday - weekStart) % 7)),
      _Frequency.monthly => DateTime.utc(date.year, date.month),
      _Frequency.yearly => DateTime.utc(date.year),
    };
  }

  int periodIndex(DateTime first, DateTime target) {
    if (target.isBefore(first)) return -1;
    final units = switch (frequency) {
      _Frequency.daily => target.difference(first).inDays,
      _Frequency.weekly => target.difference(first).inDays ~/ 7,
      _Frequency.monthly =>
        (target.year - first.year) * 12 + target.month - first.month,
      _Frequency.yearly => target.year - first.year,
    };
    return units ~/ interval;
  }

  DateTime periodAt(DateTime first, int index) {
    final steps = index * interval;
    return switch (frequency) {
      _Frequency.daily => _addDays(first, steps),
      _Frequency.weekly => _addDays(first, steps * 7),
      _Frequency.monthly => DateTime.utc(first.year, first.month + steps),
      _Frequency.yearly => DateTime.utc(first.year + steps),
    };
  }

  Iterable<DateTime> datesIn(DateTime period, DateTime start) sync* {
    switch (frequency) {
      case _Frequency.daily:
        if (_matchesMonth(period) &&
            _matchesMonthDate(period) &&
            _matchesWeekday(period)) {
          yield period;
        }
      case _Frequency.weekly:
        for (var offset = 0; offset < 7; offset++) {
          final date = _addDays(period, offset);
          final selected = days.isEmpty
              ? date.weekday == start.weekday
              : _matchesWeekday(date);
          if (selected && _matchesMonth(date)) yield date;
        }
      case _Frequency.monthly:
        if (_matchesMonth(period)) {
          yield* _datesInMonth(
            period.year,
            period.month,
            start.day,
            ordinalOfYear: false,
          );
        }
      case _Frequency.yearly:
        final firstMonth = months.isEmpty && days.isEmpty && monthDates.isEmpty
            ? start.month
            : 1;
        final lastMonth = months.isEmpty && days.isEmpty && monthDates.isEmpty
            ? start.month
            : 12;
        for (var month = firstMonth; month <= lastMonth; month++) {
          if (months.isNotEmpty && !months.contains(month)) continue;
          yield* _datesInMonth(
            period.year,
            month,
            start.day,
            ordinalOfYear: months.isEmpty,
          );
        }
    }
  }

  Iterable<DateTime> _datesInMonth(
    int year,
    int month,
    int defaultDay, {
    required bool ordinalOfYear,
  }) sync* {
    final last = DateTime.utc(year, month + 1, 0).day;
    if (days.isEmpty && monthDates.isEmpty) {
      if (defaultDay <= last) yield DateTime.utc(year, month, defaultDay);
      return;
    }
    for (var day = 1; day <= last; day++) {
      final date = DateTime.utc(year, month, day);
      if (_matchesMonthDate(date) &&
          _matchesWeekday(date, ordinalOfYear: ordinalOfYear)) {
        yield date;
      }
    }
  }

  bool _matchesMonth(DateTime date) =>
      months.isEmpty || months.contains(date.month);

  bool _matchesMonthDate(DateTime date) {
    if (monthDates.isEmpty || monthDates.contains(date.day)) return true;
    final last = DateTime.utc(date.year, date.month + 1, 0).day;
    return monthDates.contains(date.day - last - 1);
  }

  bool _matchesWeekday(DateTime date, {bool ordinalOfYear = false}) {
    if (days.isEmpty) return true;
    for (final day in days) {
      if (date.weekday != day.weekday) continue;
      final ordinal = day.ordinal;
      if (ordinal == null) return true;
      final first = ordinalOfYear
          ? DateTime.utc(date.year)
          : DateTime.utc(date.year, date.month);
      final last = ordinalOfYear
          ? DateTime.utc(date.year, 12, 31)
          : DateTime.utc(date.year, date.month + 1, 0);
      if (ordinal > 0 && date.difference(first).inDays ~/ 7 + 1 == ordinal) {
        return true;
      }
      if (ordinal < 0 && -(last.difference(date).inDays ~/ 7 + 1) == ordinal) {
        return true;
      }
    }
    return false;
  }
}

Set<int> _ruleNumbers(
  Map<String, String> fields,
  String field,
  int minimum,
  int maximum,
  String uid,
) {
  final result = <int>{};
  for (final raw in fields[field]?.split(',') ?? const <String>[]) {
    final value = int.tryParse(raw);
    if (value == null || value == 0 || value < minimum || value > maximum) {
      throw IcsExpansionException('Invalid $field value.', uid: uid);
    }
    result.add(value);
  }
  return result;
}
