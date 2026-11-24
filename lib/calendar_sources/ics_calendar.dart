import 'dart:convert';

enum IcsDateTimeKind { date, utc, floating, zoned }

/// UTC instants and local calendar components are deliberately distinct.
class IcsDateTime {
  factory IcsDateTime.parse(String value) => _readDateTime(value, const {});

  IcsDateTime.date(DateTime value)
    : this._(_components(value, dateOnly: true), IcsDateTimeKind.date);

  IcsDateTime.utc(DateTime value)
    : this._(_components(value.toUtc()), IcsDateTimeKind.utc);

  IcsDateTime.floating(DateTime value)
    : this._(_components(value), IcsDateTimeKind.floating);

  factory IcsDateTime.zoned(DateTime value, String timeZoneId) {
    if (timeZoneId.isEmpty || _invalidParameter.hasMatch(timeZoneId)) {
      throw ArgumentError.value(timeZoneId, 'timeZoneId');
    }
    return IcsDateTime._(_components(value), IcsDateTimeKind.zoned, timeZoneId);
  }

  const IcsDateTime._(this.components, this.kind, [this.timeZoneId]);

  /// A UTC DateTime used to hold civil fields when the kind is not UTC.
  final DateTime components;
  final IcsDateTimeKind kind;
  final String? timeZoneId;

  DateTime? get utcInstant => kind == IcsDateTimeKind.utc ? components : null;

  @override
  bool operator ==(Object other) =>
      other is IcsDateTime &&
      other.components == components &&
      other.kind == kind &&
      other.timeZoneId == timeZoneId;

  @override
  int get hashCode => Object.hash(components, kind, timeZoneId);
}

class IcsRecurrencePeriod {
  const IcsRecurrencePeriod._(this.start, this.end, this.duration);

  final IcsDateTime start;
  final IcsDateTime? end;
  final String? duration;
}

class IcsEvent {
  IcsEvent({
    required String uid,
    required IcsDateTime start,
    String summary = '',
    IcsDateTime? end,
    String? duration,
    String? location,
    String? description,
    String? status,
    IcsDateTime? stamp,
    String? recurrenceRule,
    IcsDateTime? recurrenceId,
    String? recurrenceRange,
    Iterable<IcsDateTime> recurrenceDates = const [],
    Iterable<IcsDateTime> exceptionDates = const [],
  }) : this._(
         uid: uid,
         start: start,
         summary: summary,
         end: end,
         duration: duration,
         location: location,
         description: description,
         status: status,
         stamp: stamp,
         recurrenceRule: recurrenceRule,
         recurrenceId: recurrenceId,
         recurrenceRange: recurrenceRange,
         recurrenceDates: recurrenceDates,
         exceptionDates: exceptionDates,
       );

  IcsEvent._({
    required this.uid,
    required this.start,
    required this.summary,
    this.end,
    this.duration,
    this.location,
    this.description,
    this.status,
    this.stamp,
    this.recurrenceRule,
    this.recurrenceId,
    this.recurrenceRange,
    Iterable<IcsDateTime> recurrenceDates = const [],
    Iterable<IcsDateTime> exceptionDates = const [],
    this._extra = const [],
    this._components = const [],
  }) : recurrenceDates = List.unmodifiable(recurrenceDates),
       exceptionDates = List.unmodifiable(exceptionDates) {
    if (uid.trim().isEmpty) {
      throw const FormatException('An event requires a UID.');
    }
    if (stamp != null && stamp!.kind != IcsDateTimeKind.utc) {
      throw const FormatException('DTSTAMP must be UTC.');
    }
    if (duration != null) {
      _validateDuration(duration!);
      if (end != null) {
        throw const FormatException('An event can specify DTEND or DURATION.');
      }
      if (start.kind == IcsDateTimeKind.date &&
          duration!.toUpperCase().contains('T')) {
        throw const FormatException('An all-day duration uses days or weeks.');
      }
    }
    if (end case final finish?) {
      if ((start.kind == IcsDateTimeKind.date) !=
          (finish.kind == IcsDateTimeKind.date)) {
        throw const FormatException(
          'DTSTART and DTEND must have matching value types.',
        );
      }
      if (start.kind == finish.kind &&
          start.timeZoneId == finish.timeZoneId &&
          !finish.components.isAfter(start.components)) {
        throw const FormatException('DTEND must follow DTSTART.');
      }
    }
    if (recurrenceRule != null) _validateRecurrence(recurrenceRule!);
    if (status != null && !_token.hasMatch(status!)) {
      throw const FormatException('Invalid event status.');
    }
    if (recurrenceRange != null &&
        (recurrenceId == null ||
            !_recurrenceRanges.contains(recurrenceRange!.toUpperCase()))) {
      throw const FormatException('Invalid RECURRENCE-ID range.');
    }
  }

  final String uid;
  final IcsDateTime start;
  final IcsDateTime? end;
  final String? duration;
  final String summary;
  final String? location;
  final String? description;
  final String? status;
  final IcsDateTime? stamp;
  final String? recurrenceRule;
  final IcsDateTime? recurrenceId;
  final String? recurrenceRange;
  final List<IcsDateTime> recurrenceDates;
  final List<IcsDateTime> exceptionDates;
  final List<_ContentLine> _extra;
  final List<_Component> _components;

  List<IcsRecurrencePeriod> get recurrencePeriods => List.unmodifiable(
    _extra.where((property) => property.name == 'RDATE').expand(_readPeriods),
  );

  bool get hasLegacyExclusionRule =>
      _extra.any((property) => property.name == 'EXRULE');
}

class IcsCalendar {
  IcsCalendar({String? name, required Iterable<IcsEvent> events})
    : this._(name: name, events: events);

  IcsCalendar._({
    this.name,
    required Iterable<IcsEvent> events,
    this._extra = const [],
    this._components = const [],
  }) : events = List.unmodifiable(events);

  factory IcsCalendar.parse(String input) {
    final root = _parseComponents(_unfold(input));
    if (root.type != 'VCALENDAR' || _single(root, 'VERSION')?.value != '2.0') {
      throw const FormatException('Expected an iCalendar 2.0 document.');
    }
    final name = _single(root, 'X-WR-CALNAME');
    return IcsCalendar._(
      name: name == null ? null : _decodeText(name.value),
      events: root.children
          .where((child) => child.type == 'VEVENT')
          .map(_parseEvent),
      extra: root.properties
          .where((property) => !_calendarFields.contains(property.name))
          .toList(),
      components: root.children
          .where((child) => child.type != 'VEVENT')
          .toList(),
    );
  }

  factory IcsCalendar.parseBytes(List<int> input) {
    // Undo physical folds first, including producer folds inside UTF-8 scalars.
    final unfolded = <int>[];
    for (var index = 0; index < input.length; index++) {
      final byte = input[index];
      if (byte == 10 || byte == 13) {
        final afterNewline =
            byte == 13 && index + 1 < input.length && input[index + 1] == 10
            ? index + 2
            : index + 1;
        if (afterNewline < input.length &&
            (input[afterNewline] == 32 || input[afterNewline] == 9)) {
          index = afterNewline;
          continue;
        }
      }
      unfolded.add(byte);
    }
    return IcsCalendar.parse(utf8.decode(unfolded));
  }

  final String? name;
  final List<IcsEvent> events;
  final List<_ContentLine> _extra;
  final List<_Component> _components;

  String? get calendarScale => _extra
      .where((property) => property.name == 'CALSCALE')
      .firstOrNull
      ?.value;

  String? get method =>
      _extra.where((property) => property.name == 'METHOD').firstOrNull?.value;

  IcsCalendar withEvents(Iterable<IcsEvent> events) => IcsCalendar._(
    name: name,
    events: events,
    extra: _extra,
    components: _components,
  );

  /// The fallback stamp is only used for events without an explicit DTSTAMP.
  String encode({DateTime? timestamp}) {
    final output = StringBuffer();
    final stamp = IcsDateTime.utc(timestamp ?? DateTime.now());
    final lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      if (!_extra.any((property) => property.name == 'PRODID'))
        'PRODID:-//Easy//Calendar//EN',
      if (name != null) 'X-WR-CALNAME:${_encodeText(name!)}',
      for (final property in _extra) property.line,
      for (final component in _components) ..._componentLines(component),
      for (final event in events) ..._eventLines(event, stamp),
      'END:VCALENDAR',
    ];
    for (final line in lines) {
      _writeFolded(output, line);
    }
    return output.toString();
  }
}

const _calendarFields = {'VERSION', 'X-WR-CALNAME'};
const _eventFields = {
  'UID',
  'DTSTART',
  'DTEND',
  'DURATION',
  'DTSTAMP',
  'SUMMARY',
  'LOCATION',
  'DESCRIPTION',
  'STATUS',
  'RRULE',
  'RECURRENCE-ID',
  'RDATE',
  'EXDATE',
};
const _recurrenceRanges = {'THISANDFUTURE', 'THISANDPRIOR'};
const _frequencies = {
  'SECONDLY',
  'MINUTELY',
  'HOURLY',
  'DAILY',
  'WEEKLY',
  'MONTHLY',
  'YEARLY',
};
final _invalidParameter = RegExp(r'["\x00-\x1f\x7f]');
final _invalidLine = RegExp(r'[\x00-\x08\x0a-\x1f\x7f]');
final _token = RegExp(r'^[A-Z0-9-]+$', caseSensitive: false);
final _datePattern = RegExp(r'^(\d{4})(\d{2})(\d{2})$');
final _timePattern = RegExp(
  r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$',
  caseSensitive: false,
);
final _rulePart = RegExp(
  r'^([A-Z][A-Z0-9-]*)=([A-Z0-9,+-]+)$',
  caseSensitive: false,
);
final _durationPattern = RegExp(
  r'^\+?P(?:\d+W|\d+D(?:T(?:\d+H(?:\d+M)?(?:\d+S)?|\d+M(?:\d+S)?|\d+S))?|T(?:\d+H(?:\d+M)?(?:\d+S)?|\d+M(?:\d+S)?|\d+S))$',
  caseSensitive: false,
);
final _nonzeroDigit = RegExp(r'[1-9]');

DateTime _components(DateTime value, {bool dateOnly = false}) {
  if (value.year < 1 || value.year > 9999) {
    throw ArgumentError.value(
      value,
      'value',
      'Use a four-digit calendar year.',
    );
  }
  return DateTime.utc(
    value.year,
    value.month,
    value.day,
    dateOnly ? 0 : value.hour,
    dateOnly ? 0 : value.minute,
    dateOnly ? 0 : value.second,
  );
}

void _validateDuration(String value) {
  if (!_durationPattern.hasMatch(value) || !_nonzeroDigit.hasMatch(value)) {
    throw const FormatException('Invalid event duration.');
  }
}

void _validateRecurrence(String value) {
  final fields = <String, String>{};
  for (final part in value.split(';')) {
    final match = _rulePart.firstMatch(part);
    final key = match?[1]?.toUpperCase();
    if (match == null || key == null || fields.containsKey(key)) {
      throw const FormatException('Invalid recurrence rule.');
    }
    fields[key] = match[2]!;
  }
  if (!_frequencies.contains(fields['FREQ']?.toUpperCase()) ||
      (fields.containsKey('COUNT') && fields.containsKey('UNTIL'))) {
    throw const FormatException('Invalid recurrence rule.');
  }
  for (final field in ['COUNT', 'INTERVAL']) {
    if (fields[field] case final value?) {
      if ((int.tryParse(value) ?? 0) < 1) {
        throw const FormatException('Invalid recurrence count or interval.');
      }
    }
  }
  if (fields['UNTIL'] case final until?) _readDateTime(until, const {});
}

IcsEvent _parseEvent(_Component object) {
  final uid = _single(object, 'UID');
  final recurrence = _single(object, 'RECURRENCE-ID');
  final status = _single(object, 'STATUS')?.value;
  final start =
      _single(object, 'DTSTART') ??
      (status?.toUpperCase() == 'CANCELLED' ? recurrence : null);
  if (uid == null || start == null) {
    throw const FormatException('An event requires a UID and DTSTART.');
  }
  final extra = <_ContentLine>[];
  final recurrenceDates = <IcsDateTime>[];
  final exceptionDates = <IcsDateTime>[];
  for (final property in object.properties) {
    if (property.name == 'RDATE' || property.name == 'EXDATE') {
      final type = property.parameters['VALUE']?.toUpperCase();
      if (property.name == 'RDATE' && type == 'PERIOD') {
        _readPeriods(property).toList();
        extra.add(property);
      } else {
        final target = property.name == 'RDATE'
            ? recurrenceDates
            : exceptionDates;
        target.addAll(
          property.value
              .split(',')
              .map((value) => _readDateTime(value, property.parameters)),
        );
      }
    } else if (!_eventFields.contains(property.name)) {
      extra.add(property);
    }
  }
  return IcsEvent._(
    uid: _decodeText(uid.value),
    start: _parseDateTime(start),
    end: _optionalDateTime(object, 'DTEND'),
    duration: _single(object, 'DURATION')?.value,
    summary: _decodedField(object, 'SUMMARY') ?? '',
    description: _decodedField(object, 'DESCRIPTION'),
    status: status,
    location: _decodedField(object, 'LOCATION'),
    stamp: _optionalDateTime(object, 'DTSTAMP'),
    recurrenceRule: _single(object, 'RRULE')?.value,
    recurrenceId: recurrence == null ? null : _parseDateTime(recurrence),
    recurrenceRange: recurrence?.parameters['RANGE'],
    recurrenceDates: recurrenceDates,
    exceptionDates: exceptionDates,
    extra: extra,
    components: object.children,
  );
}

Iterable<IcsRecurrencePeriod> _readPeriods(_ContentLine property) sync* {
  final parameters = {...property.parameters}..remove('VALUE');
  for (final value in property.value.split(',')) {
    final parts = value.split('/');
    if (parts.length != 2) throw const FormatException('Invalid RDATE period.');
    final start = _readDateTime(parts.first, parameters);
    if (start.kind == IcsDateTimeKind.date) {
      throw const FormatException('An RDATE period starts at a time.');
    }
    final finish = parts.last;
    if (finish.toUpperCase().startsWith('P') || finish.startsWith('+')) {
      _validateDuration(finish);
      yield IcsRecurrencePeriod._(start, null, finish);
      continue;
    }
    final end = _readDateTime(finish, parameters);
    if (start.kind != end.kind || !end.components.isAfter(start.components)) {
      throw const FormatException('An RDATE period ends after its start time.');
    }
    yield IcsRecurrencePeriod._(start, end, null);
  }
}

String? _decodedField(_Component component, String name) {
  final value = _single(component, name)?.value;
  return value == null ? null : _decodeText(value);
}

IcsDateTime? _optionalDateTime(_Component component, String name) {
  final property = _single(component, name);
  return property == null ? null : _parseDateTime(property);
}

IcsDateTime _parseDateTime(_ContentLine property) =>
    _readDateTime(property.value, property.parameters);

IcsDateTime _readDateTime(String value, Map<String, String> parameters) {
  final type = parameters['VALUE']?.toUpperCase();
  final zone = parameters['TZID'];
  final date = _datePattern.firstMatch(value);
  final time = _timePattern.firstMatch(value);
  if (date != null && (type == null || type == 'DATE') && zone == null) {
    return IcsDateTime._(_checkedDate(date), IcsDateTimeKind.date);
  }
  if (time == null || (type != null && type != 'DATE-TIME')) {
    throw const FormatException('Invalid iCalendar date or time.');
  }
  final fields = _checkedDate(time, includesTime: true);
  if (time[7]!.isNotEmpty) {
    if (zone != null) {
      throw const FormatException('UTC times cannot include a TZID.');
    }
    return IcsDateTime._(fields, IcsDateTimeKind.utc);
  }
  if (zone == null) return IcsDateTime._(fields, IcsDateTimeKind.floating);
  if (zone.isEmpty || _invalidParameter.hasMatch(zone)) {
    throw const FormatException('Invalid TZID.');
  }
  return IcsDateTime._(fields, IcsDateTimeKind.zoned, zone);
}

DateTime _checkedDate(RegExpMatch match, {bool includesTime = false}) {
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = includesTime ? int.parse(match[4]!) : 0;
  final minute = includesTime ? int.parse(match[5]!) : 0;
  final second = includesTime ? int.parse(match[6]!) : 0;
  final date = DateTime.utc(year, month, day, hour, minute, second);
  if (year == 0 ||
      date.year != year ||
      date.month != month ||
      date.day != day ||
      date.hour != hour ||
      date.minute != minute ||
      date.second != second) {
    throw const FormatException('Invalid iCalendar date or time.');
  }
  return date;
}

String _dateTimeLine(String name, IcsDateTime value, {String? range}) {
  final fields = value.components;
  String two(int value) => value.toString().padLeft(2, '0');
  final date =
      '${fields.year.toString().padLeft(4, '0')}${two(fields.month)}${two(fields.day)}';
  final time = '${two(fields.hour)}${two(fields.minute)}${two(fields.second)}';
  final parameters = [
    if (value.kind == IcsDateTimeKind.date) 'VALUE=DATE',
    if (value.timeZoneId case final zone?) 'TZID=${_parameterValue(zone)}',
    if (range != null) 'RANGE=$range',
  ];
  final property = [name, ...parameters].join(';');
  return '$property:$date${value.kind == IcsDateTimeKind.date ? '' : 'T$time'}${value.kind == IcsDateTimeKind.utc ? 'Z' : ''}';
}

String _parameterValue(String value) =>
    value.contains(RegExp(r'[:;,\s]')) ? '"$value"' : value;

Iterable<String> _eventLines(IcsEvent event, IcsDateTime fallbackStamp) sync* {
  yield 'BEGIN:VEVENT';
  yield 'UID:${_encodeText(event.uid)}';
  yield _dateTimeLine('DTSTAMP', event.stamp ?? fallbackStamp);
  yield _dateTimeLine('DTSTART', event.start);
  if (event.end case final end?) yield _dateTimeLine('DTEND', end);
  if (event.duration case final duration?) yield 'DURATION:$duration';
  if (event.status case final status?) yield 'STATUS:$status';
  yield 'SUMMARY:${_encodeText(event.summary)}';
  if (event.description case final description?) {
    yield 'DESCRIPTION:${_encodeText(description)}';
  }
  if (event.location case final location?) {
    yield 'LOCATION:${_encodeText(location)}';
  }
  if (event.recurrenceRule case final rule?) yield 'RRULE:$rule';
  if (event.recurrenceId case final id?) {
    yield _dateTimeLine('RECURRENCE-ID', id, range: event.recurrenceRange);
  }
  for (final date in event.recurrenceDates) {
    yield _dateTimeLine('RDATE', date);
  }
  for (final date in event.exceptionDates) {
    yield _dateTimeLine('EXDATE', date);
  }
  for (final property in event._extra) {
    yield property.line;
  }
  for (final child in event._components) {
    yield* _componentLines(child);
  }
  yield 'END:VEVENT';
}

String _decodeText(String input) {
  final text = StringBuffer();
  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (character != '\\' || index == input.length - 1) {
      text.write(character);
      continue;
    }
    final escaped = input[++index];
    text.write(switch (escaped) {
      'n' || 'N' => '\n',
      '\\' || ',' || ';' => escaped,
      _ => '\\$escaped',
    });
  }
  return text.toString();
}

String _encodeText(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '\\n')
    .replaceAll(',', '\\,')
    .replaceAll(';', '\\;');

Iterable<String> _unfold(String value) sync* {
  final normalized = value.startsWith('\ufeff') ? value.substring(1) : value;
  StringBuffer? pending;
  for (final line in normalized.split(RegExp(r'\r\n|\r|\n'))) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (pending == null || pending.isEmpty) {
        throw const FormatException('Unexpected folded line.');
      }
      pending.write(line.substring(1));
    } else {
      if (pending != null && pending.isNotEmpty) yield pending.toString();
      pending = StringBuffer(line);
    }
  }
  if (pending != null && pending.isNotEmpty) yield pending.toString();
}

void _writeFolded(StringBuffer output, String line) {
  if (_invalidLine.hasMatch(line)) {
    throw const FormatException('Invalid content line.');
  }
  var octets = 0;
  for (final codePoint in line.runes) {
    final length = codePoint <= 0x7F
        ? 1
        : codePoint <= 0x7FF
        ? 2
        : codePoint <= 0xFFFF
        ? 3
        : 4;
    if (octets + length > 75) {
      output.write('\r\n ');
      octets = 1;
    }
    output.writeCharCode(codePoint);
    octets += length;
  }
  output.write('\r\n');
}

class _Component {
  _Component(this.type);

  final String type;
  final properties = <_ContentLine>[];
  final children = <_Component>[];
}

class _ContentLine {
  const _ContentLine(this.line, this.name, this.parameters, this.value);

  final String line;
  final String name;
  final Map<String, String> parameters;
  final String value;
}

_ContentLine _parseLine(String line) {
  if (_invalidLine.hasMatch(line)) {
    throw const FormatException('Invalid content line.');
  }
  final fields = <String>[];
  var quoted = false;
  var start = 0;
  var separator = -1;
  for (var index = 0; index < line.length; index++) {
    final character = line[index];
    if (character == '"') quoted = !quoted;
    if (quoted) continue;
    if (character == ';' || character == ':') {
      fields.add(line.substring(start, index));
      start = index + 1;
      if (character == ':') {
        separator = index;
        break;
      }
    }
  }
  if (separator < 0 || fields.isEmpty || !_token.hasMatch(fields.first)) {
    throw const FormatException('Invalid content line.');
  }
  final parameters = <String, String>{};
  for (final parameter in fields.skip(1)) {
    final equals = parameter.indexOf('=');
    if (equals < 1 || !_token.hasMatch(parameter.substring(0, equals))) {
      throw const FormatException('Invalid content line parameter.');
    }
    final name = parameter.substring(0, equals).toUpperCase();
    var value = parameter.substring(equals + 1);
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (parameters.containsKey(name)) {
      throw const FormatException('Duplicate content line parameter.');
    }
    parameters[name] = value;
  }
  return _ContentLine(
    line,
    fields.first.toUpperCase(),
    parameters,
    line.substring(separator + 1),
  );
}

_Component _parseComponents(Iterable<String> lines) {
  final stack = <_Component>[];
  _Component? root;
  for (final line in lines) {
    final property = _parseLine(line);
    final type = property.value.toUpperCase();
    if (property.name == 'BEGIN') {
      if (!_token.hasMatch(type) ||
          property.parameters.isNotEmpty ||
          (stack.isEmpty && root != null) ||
          stack.length >= 32) {
        throw const FormatException('Invalid calendar component.');
      }
      final component = _Component(type);
      if (stack.isEmpty) {
        root = component;
      } else {
        stack.last.children.add(component);
      }
      stack.add(component);
    } else if (property.name == 'END') {
      if (stack.isEmpty ||
          stack.last.type != type ||
          property.parameters.isNotEmpty) {
        throw const FormatException('Mismatched calendar component.');
      }
      stack.removeLast();
    } else {
      if (stack.isEmpty) {
        throw const FormatException('Property outside a calendar component.');
      }
      stack.last.properties.add(property);
    }
  }
  if (root == null || stack.isNotEmpty) {
    throw const FormatException('Incomplete calendar document.');
  }
  return root;
}

_ContentLine? _single(_Component component, String name) {
  final matches = component.properties.where(
    (property) => property.name == name,
  );
  final iterator = matches.iterator;
  if (!iterator.moveNext()) return null;
  final first = iterator.current;
  if (iterator.moveNext()) throw FormatException('Duplicate $name property.');
  return first;
}

Iterable<String> _componentLines(_Component component) sync* {
  yield 'BEGIN:${component.type}';
  for (final property in component.properties) {
    yield property.line;
  }
  for (final child in component.children) {
    yield* _componentLines(child);
  }
  yield 'END:${component.type}';
}
