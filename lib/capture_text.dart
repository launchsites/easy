class EventCaptureText {
  const EventCaptureText({
    required this.title,
    required this.date,
    this.start,
    this.end,
    this.duration,
    this.allDay = false,
    this.location,
    this.error,
  });

  final String title;
  final DateTime date;
  final DateTime? start;
  final DateTime? end;
  final Duration? duration;
  final bool allDay;
  final String? location;
  final String? error;
}

class TaskCaptureText {
  const TaskCaptureText({required this.title, this.dueDate});

  final String title;
  final DateTime? dueDate;
}

/// Reads explicitly supplied scheduling details and preserves missing times.
/// Relative phrases use [now] when provided. [date] anchors an undated entry.
EventCaptureText parseEventCapture(
  String input, {
  required DateTime date,
  DateTime? now,
}) {
  final reference = _day(now?.toLocal() ?? date);
  final place = _takeLocation(input.trim());
  final duration = _takeDuration(place.text);
  final clocks = _takeClocks(duration.text, reference);
  final allDay = _takeAllDay(clocks.text, reference);
  final datePhrase = _takeDate(
    allDay.text,
    reference,
    allowLeading:
        allDay.value || clocks.start != null || duration.value != null,
  );
  final effectiveDate = datePhrase.value ?? _day(date);
  var error = duration.error ?? clocks.error ?? datePhrase.error;
  final startClock = clocks.start;
  final endClock = clocks.end;
  if (allDay.value && (startClock != null || duration.value != null)) {
    error ??= 'Use only a date for an all-day event.';
  } else if (endClock != null && duration.value != null) {
    error ??= 'Choose a time range or a duration.';
  }

  DateTime? start;
  DateTime? end;
  if (!allDay.value && startClock != null) {
    final (startMinute, endMinute) = _resolveRange(startClock, endClock);
    start = _atMinute(effectiveDate, startMinute);
    if (start == null) {
      error ??= _invalidTime;
    } else if (endMinute != null && endMinute == startMinute) {
      error ??= 'Enter a different end time.';
    } else if (endMinute != null &&
        endMinute < startMinute &&
        !_isOvernight(startMinute, endMinute)) {
      error ??= 'Enter a later end time or use an evening-to-morning range.';
    } else if (endMinute != null) {
      final endDate = endMinute < startMinute
          ? _plusDays(effectiveDate, 1)
          : effectiveDate;
      end = _atMinute(endDate, endMinute);
      if (end == null || !end.isAfter(start)) error ??= _invalidTime;
    } else if (duration.value case final length?) {
      end = start.add(length);
    }
  }

  return EventCaptureText(
    title: datePhrase.text,
    date: effectiveDate,
    start: start,
    end: end,
    duration: duration.value,
    allDay: allDay.value,
    location: place.value,
    error: error,
  );
}

TaskCaptureText parseTaskCapture(
  String input, {
  required DateTime date,
  DateTime? now,
}) {
  final text = input.trim();
  final phrase = _takeDate(text, _day(now?.toLocal() ?? date));
  if (phrase.value == null || phrase.text.isEmpty) {
    return TaskCaptureText(title: text);
  }
  return TaskCaptureText(title: phrase.text, dueDate: phrase.value);
}

DateTime? parseCaptureTime(String input, {required DateTime date}) {
  final value = _parseClock(input.trim().replaceFirst(_timeQualifier, ''));
  return value == null ? null : _atMinute(_day(date), value.minutes);
}

/// Resolves a complete numeric date without assuming a regional date order.
DateTime? parseCaptureNumericDate(String text) {
  if (_yearFirstDate.firstMatch(text) case final date?) {
    return _validatedDay(
      int.parse(date[1]!),
      int.parse(date[3]!),
      int.parse(date[4]!),
    );
  }
  final date = _trailingYearDate.firstMatch(text);
  if (date == null) return null;
  final first = int.parse(date[1]!);
  final second = int.parse(date[2]!);
  final year = int.parse(date[3]!);
  if (first == second || second > 12) {
    return _validatedDay(year, first, second);
  }
  if (first > 12) return _validatedDay(year, second, first);
  return null;
}

const _invalidDate = 'Enter a valid date, such as tomorrow or 2026-11-24.';
const _invalidTime = 'Enter a valid time, such as 18:30 or 6:30pm.';
const _invalidDuration = 'Enter a duration from 1 minute to 24 hours.';
const _weekday =
    r'mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?';
const _month =
    r'jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?';
const _dayNumber = r'\d{1,2}(?:st|nd|rd|th)?';
const _yearSuffix = r'(?:[,]?\s+\d{4})?';
const _yearFirstPattern = r'(?:\d{4}-\d{1,2}-\d{1,2}|\d{4}/\d{1,2}/\d{1,2})';
const _trailingYearPattern = r'\d{1,2}/\d{1,2}/\d{4}';
const _monthFirstPattern = '(?:$_month)\\.?[ \\t]+$_dayNumber$_yearSuffix';
const _dayFirstPattern = '$_dayNumber[ \\t]+(?:$_month)\\.?$_yearSuffix';
const _datePattern =
    '(?:$_yearFirstPattern|$_trailingYearPattern|$_monthFirstPattern|$_dayFirstPattern|today|tomorrow|yesterday|(?:next[ \\t]+|this[ \\t]+)?(?:$_weekday)\\.?)';
final _dates = RegExp(
  '(?<![\\w/:-])$_datePattern(?![\\w/:-])',
  caseSensitive: false,
);
final _dateOnly = RegExp('^$_datePattern\$', caseSensitive: false);
final _monthFirst = RegExp(
  '^($_month)\\.?[ \\t]+(\\d{1,2})(?:st|nd|rd|th)?(?:[,]?\\s+(\\d{4}))?\$',
  caseSensitive: false,
);
final _dayFirst = RegExp(
  '^(\\d{1,2})(?:st|nd|rd|th)?[ \\t]+($_month)\\.?(?:[,]?\\s+(\\d{4}))?\$',
  caseSensitive: false,
);
final _yearFirstDate = RegExp(r'^(\d{4})([-/])(\d{1,2})\2(\d{1,2})$');
final _trailingYearDate = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$');
final _dateQualifier = RegExp(
  r'(?:^|\s)(?:on|by|for|due(?:\s+(?:by|on))?:?)[ \t]+$',
  caseSensitive: false,
);
final _schedulePunctuation = RegExp(r'^\s*[,;.]?\s*$');
final _doubleQuotes = RegExp(r'"[^"]*"|“[^”]*”');

({String text, DateTime? value, String? error}) _takeDate(
  String text,
  DateTime reference, {
  bool allowLeading = false,
}) {
  final matches = <({int start, int end, String token})>[];
  for (final match in _dates.allMatches(text)) {
    if (_quoted(text, match)) continue;
    final token = match[0]!;
    final before = text.substring(0, match.start);
    final after = text.substring(match.end);
    final qualifier = _dateQualifier.firstMatch(before);
    final terminal = _schedulePunctuation.hasMatch(after);
    final leading = allowLeading && before.trim().isEmpty;
    if (terminal ||
        leading ||
        qualifier != null ||
        _yearFirstDate.hasMatch(token)) {
      matches.add((
        start: qualifier?.start ?? match.start,
        end: terminal ? text.length : match.end,
        token: token,
      ));
    }
  }
  if (matches.isEmpty) return (text: text, value: null, error: null);
  final selected = matches.last;
  final precedingDate =
      matches.length == 1 &&
      _dates.allMatches(text.substring(0, selected.start)).any((match) {
        final remaining = text.substring(match.end, selected.start);
        return _schedulePunctuation.hasMatch(remaining);
      });
  if (matches.length > 1 || precedingDate) {
    return (text: text, value: null, error: 'Enter one date for this item.');
  }
  final value = _parseDate(selected.token, reference);
  if (value == null) return (text: text, value: null, error: _invalidDate);
  return (
    text: _remove(text, selected.start, selected.end),
    value: value,
    error: null,
  );
}

DateTime? _parseDate(String text, DateTime reference) {
  if (!_dateOnly.hasMatch(text)) return null;
  final lower = text.toLowerCase();
  switch (lower) {
    case 'today':
      return reference;
    case 'tomorrow':
      return _plusDays(reference, 1);
    case 'yesterday':
      return _plusDays(reference, -1);
  }

  if (_yearFirstDate.hasMatch(lower) || _trailingYearDate.hasMatch(lower)) {
    return parseCaptureNumericDate(lower);
  }

  final monthFirst = _monthFirst.firstMatch(lower);
  final dayFirst = _dayFirst.firstMatch(lower);
  if (monthFirst != null || dayFirst != null) {
    final match = monthFirst ?? dayFirst!;
    final month =
        const [
          'jan',
          'feb',
          'mar',
          'apr',
          'may',
          'jun',
          'jul',
          'aug',
          'sep',
          'oct',
          'nov',
          'dec',
        ].indexOf(match[monthFirst == null ? 2 : 1]!.substring(0, 3)) +
        1;
    final day = int.parse(match[monthFirst == null ? 1 : 2]!);
    final year = int.tryParse(match[3] ?? '') ?? reference.year;
    return _validatedDay(year, month, day);
  }

  final words = lower.split(RegExp(r'\s+'));
  final dayName = words.last.substring(0, 3);
  final weekday =
      const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'].indexOf(dayName) +
      1;
  final distance = (weekday - reference.weekday) % 7;
  return _plusDays(
    reference,
    words.first == 'next' && distance == 0 ? 7 : distance,
  );
}

DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);

DateTime _plusDays(DateTime value, int amount) =>
    DateTime(value.year, value.month, value.day + amount);

DateTime? _validatedDay(int year, int month, int day) {
  if (year < 1 ||
      year > 9999 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31) {
    return null;
  }
  final value = DateTime(year, month, day);
  return value.year == year && value.month == month && value.day == day
      ? value
      : null;
}

DateTime? _atMinute(DateTime date, int minute) {
  final hour = minute ~/ 60;
  final value = DateTime(date.year, date.month, date.day, hour, minute % 60);
  return value.day == date.day &&
          value.hour == hour &&
          value.minute == minute % 60
      ? value
      : null;
}

final _locationSuffix = RegExp(
  r'(?:^|\s)(?:@\s*|location:\s*)([^\n]+)$',
  caseSensitive: false,
);
final _zoneLike = RegExp(r'^[A-Za-z_]+/[A-Za-z_]+(?:/[A-Za-z_]+)?$');

({String text, String? value}) _takeLocation(String text) {
  final location = _locationSuffix.firstMatch(text);
  if (location == null || _quoted(text, location)) {
    return (text: text, value: null);
  }
  final value = location[1]!.trim();
  if (value.isEmpty || _zoneLike.hasMatch(value)) {
    return (text: text, value: null);
  }
  return (text: _remove(text, location.start, location.end), value: value);
}

const _durationUnit = r'hours?|hrs?|h|minutes?|mins?|m';
const _durationPart = '([+-]?\\d+(?:\\.\\d+)?)[ \\t]*($_durationUnit)';
final _duration = RegExp(
  '\\bfor[ \\t]+((?:$_durationPart(?:[ \\t]+|\\b))+)',
  caseSensitive: false,
);
final _durationValues = RegExp(_durationPart, caseSensitive: false);

({String text, Duration? value, String? error}) _takeDuration(String text) {
  final matches = _duration
      .allMatches(text)
      .where((match) => !_quoted(text, match))
      .toList();
  if (matches.isEmpty) return (text: text, value: null, error: null);
  if (matches.length > 1) {
    return (
      text: text,
      value: null,
      error: 'Enter one duration for this event.',
    );
  }
  final match = matches.single;
  var minutes = 0.0;
  for (final part in _durationValues.allMatches(match[1]!)) {
    final amount = double.tryParse(part[1]!) ?? 0;
    if (amount <= 0) return (text: text, value: null, error: _invalidDuration);
    minutes += amount * (part[2]!.toLowerCase().startsWith('h') ? 60 : 1);
  }
  if (!minutes.isFinite ||
      minutes < 1 ||
      minutes > 1440 ||
      minutes != minutes.truncate()) {
    return (text: text, value: null, error: _invalidDuration);
  }
  return (
    text: _remove(text, match.start, match.end),
    value: Duration(minutes: minutes.toInt()),
    error: null,
  );
}

final _allDay = RegExp(r'\ball[ -]+day\b', caseSensitive: false);

({String text, bool value}) _takeAllDay(String text, DateTime reference) {
  for (final match in _allDay.allMatches(text)) {
    if (_quoted(text, match)) continue;
    final before = text.substring(0, match.start).trim();
    final after = text.substring(match.end).trim();
    if (after.isEmpty ||
        _parseDate(after, reference) != null ||
        (before.isEmpty && _dates.hasMatch(after))) {
      return (text: _remove(text, match.start, match.end), value: true);
    }
  }
  return (text: text, value: false);
}

const _clockAtom =
    r'(?:\d{1,3}(?::\d{0,3})?(?:[ \t]*[ap]\.?m\.?)?|noon|midnight)';
final _clock = RegExp(
  r'^(\d{1,2})(?::(\d{2}))?(?:[ \t]*([ap])\.?m\.?)?$',
  caseSensitive: false,
);
final _timeQualifier = RegExp(
  r'^(?:at|from|to|until)\s+',
  caseSensitive: false,
);
final _period = RegExp(r'[ap]\.?m\.?$', caseSensitive: false);
final _range = RegExp(
  '(?<![\\w:/–—-])(?:(at|from)[ \\t]+)?($_clockAtom)[ \\t]*(?:[-–—]|[ \\t]+(?:to|until|through)[ \\t]+)[ \\t]*($_clockAtom)(?![\\w:/–—-])',
  caseSensitive: false,
);
final _singleTime = RegExp(
  '(?<![\\w:/–—-])(?:(at|from)[ \\t]+)?($_clockAtom)(?![\\w:/–—-])',
  caseSensitive: false,
);

class _Clock {
  const _Clock(
    this.minutes, {
    this.fixedPeriod = false,
    this.inferPeriod = false,
  });

  final int minutes;
  final bool fixedPeriod;
  final bool inferPeriod;
}

_Clock? _parseClock(String text) {
  final raw = text.toLowerCase();
  if (raw == 'noon') return const _Clock(12 * 60, fixedPeriod: true);
  if (raw == 'midnight') return const _Clock(0, fixedPeriod: true);
  final match = _clock.firstMatch(raw);
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.tryParse(match[2] ?? '') ?? 0;
  final period = match[3];
  if (minute > 59 || hour > 23 || (period != null && (hour < 1 || hour > 12))) {
    return null;
  }
  if (period != null) {
    return _Clock(
      (hour % 12 + (period == 'p' ? 12 : 0)) * 60 + minute,
      fixedPeriod: true,
    );
  }
  return _Clock(
    hour * 60 + minute,
    inferPeriod: hour >= 1 && hour <= 12 && !match[1]!.startsWith('0'),
  );
}

bool _strongClock(String token) =>
    token.contains(':') || _period.hasMatch(token);

bool _wordClock(String token) =>
    token.toLowerCase() == 'noon' || token.toLowerCase() == 'midnight';

bool _qualifiedRange(RegExpMatch match) {
  final first = match[2]!;
  final second = match[3]!;
  return match[1] != null ||
      _strongClock(first) ||
      _strongClock(second) ||
      _wordClock(first) ||
      _wordClock(second) ||
      ((int.tryParse(first) ?? 0) >= 13 && (int.tryParse(second) ?? 0) >= 13);
}

({String text, _Clock? start, _Clock? end, String? error}) _takeClocks(
  String text,
  DateTime reference,
) {
  final ranges = _range
      .allMatches(text)
      .where((match) => _qualifiedRange(match) && !_quoted(text, match))
      .toList();
  if (ranges.length > 1) {
    return (
      text: text,
      start: null,
      end: null,
      error: 'Enter one time range for this event.',
    );
  }
  final range = ranges.singleOrNull;
  final remaining = range == null
      ? text
      : _remove(text, range.start, range.end);
  final singles = _singleTime.allMatches(remaining).where((match) {
    final raw = match[2]!;
    final trailing = _schedulePunctuation.hasMatch(
      remaining.substring(match.end),
    );
    return !_quoted(remaining, match) &&
        (match[1] != null ||
            _strongClock(raw) ||
            (_wordClock(raw) && trailing));
  }).toList();

  if (range != null) {
    final start = _parseClock(range[2]!);
    final end = _parseClock(range[3]!);
    if (start == null || end == null) {
      return (text: text, start: null, end: null, error: _invalidTime);
    }
    if (singles.isNotEmpty) {
      return (
        text: text,
        start: null,
        end: null,
        error: 'Enter one time range for this event.',
      );
    }
    return (text: remaining, start: start, end: end, error: null);
  }
  if (singles.isEmpty) return (text: text, start: null, end: null, error: null);
  if (singles.length > 2) {
    return (
      text: text,
      start: null,
      end: null,
      error: 'Enter up to two times for this event.',
    );
  }
  final start = _parseClock(singles.first[2]!);
  final end = singles.length == 2 ? _parseClock(singles.last[2]!) : null;
  if (start == null || (singles.length == 2 && end == null)) {
    return (text: text, start: null, end: null, error: _invalidTime);
  }
  if (end != null) {
    final between = text
        .substring(singles.first.end, singles.last.start)
        .trim();
    if (!_schedulePunctuation.hasMatch(between) &&
        _parseDate(between, reference) == null) {
      return (
        text: text,
        start: null,
        end: null,
        error: 'Use a dash between the start and end times.',
      );
    }
  }
  var rest = text;
  for (final match in singles.reversed) {
    rest = _remove(rest, match.start, match.end);
  }
  return (text: rest, start: start, end: end, error: null);
}

(int, int?) _resolveRange(_Clock start, _Clock? end) {
  if (end == null) return (start.minutes, null);
  if (start.inferPeriod && end.fixedPeriod) {
    return (
      _nearestPeriod(start.minutes, end.minutes, start: true),
      end.minutes,
    );
  }
  if (end.inferPeriod && start.fixedPeriod) {
    return (
      start.minutes,
      _nearestPeriod(end.minutes, start.minutes, start: false),
    );
  }
  return (start.minutes, end.minutes);
}

int _nearestPeriod(int clock, int anchor, {required bool start}) {
  final morning = clock % (12 * 60);
  final evening = morning + 12 * 60;
  int distance(int candidate) =>
      (start ? anchor - candidate : candidate - anchor) % (24 * 60);
  return distance(morning) <= distance(evening) ? morning : evening;
}

bool _isOvernight(int start, int end) =>
    (start >= 12 * 60 || end == 0) &&
    end < 12 * 60 &&
    24 * 60 - start + end <= 16 * 60;

bool _quoted(String text, RegExpMatch match) => _doubleQuotes
    .allMatches(text)
    .any((quote) => match.start >= quote.start && match.end <= quote.end);

String _remove(String text, int start, int end) {
  final before = text.substring(0, start).trimRight();
  final after = text.substring(end).trimLeft();
  if (before.isEmpty) return after;
  if (after.isEmpty) return before.replaceFirst(RegExp(r'\s*[,;]\s*$'), '');
  return '$before $after';
}
