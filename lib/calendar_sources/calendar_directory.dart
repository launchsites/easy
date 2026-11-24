/// An event calendar's identity is scoped by its owning account or local store.
class CalendarIdentity {
  const CalendarIdentity({required this.accountId, required this.calendarId})
    : assert(accountId != ''),
      assert(calendarId != '');

  factory CalendarIdentity.fromJson(Map<String, Object?> json) {
    final account = json['accountId'];
    final calendar = json['calendarId'];
    if (account is! String ||
        account.isEmpty ||
        calendar is! String ||
        calendar.isEmpty) {
      throw const FormatException(
        'A calendar identity requires accountId and calendarId.',
      );
    }
    return CalendarIdentity(accountId: account, calendarId: calendar);
  }

  final String accountId;
  final String calendarId;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'calendarId': calendarId,
  };

  @override
  bool operator ==(Object other) =>
      other is CalendarIdentity &&
      other.accountId == accountId &&
      other.calendarId == calendarId;

  @override
  int get hashCode => Object.hash(accountId, calendarId);
}

enum CalendarCapability { read, write }

class CalendarSource {
  CalendarSource({
    required this.id,
    required this.name,
    required this.accountName,
    Iterable<CalendarCapability> capabilities = const [CalendarCapability.read],
  }) : capabilities = Set.unmodifiable(capabilities);

  final CalendarIdentity id;
  final String name;
  final String accountName;
  final Set<CalendarCapability> capabilities;

  bool get canRead => capabilities.contains(CalendarCapability.read);
  bool get canWrite => capabilities.contains(CalendarCapability.write);
}

/// Local view preferences. A calendar can belong to any number of modes.
class CalendarModeMemberships {
  CalendarModeMemberships([
    Map<String, Iterable<CalendarIdentity>> memberships = const {},
  ]) : byMode = Map.unmodifiable({
         for (final entry in memberships.entries)
           entry.key: Set<CalendarIdentity>.unmodifiable(entry.value),
       });

  factory CalendarModeMemberships.fromJson(Map<String, Object?> json) {
    final memberships = <String, Iterable<CalendarIdentity>>{};
    for (final entry in json.entries) {
      final values = entry.value;
      if (values is! List) {
        throw const FormatException('Expected a list of calendar identities.');
      }
      memberships[entry.key] = values.map((value) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('Expected a calendar identity.');
        }
        return CalendarIdentity.fromJson(value);
      }).toList();
    }
    return CalendarModeMemberships(memberships);
  }

  final Map<String, Set<CalendarIdentity>> byMode;

  Set<CalendarIdentity> forMode(String modeId) => byMode[modeId] ?? const {};

  CalendarModeMemberships withCalendars(
    String modeId,
    Iterable<CalendarIdentity> calendars,
  ) => CalendarModeMemberships({...byMode, modeId: calendars});

  Map<String, Object?> toJson() => {
    for (final entry in byMode.entries)
      entry.key: [for (final id in entry.value) id.toJson()],
  };
}

/// Adapters supply an occurrence ID for each expanded or detached recurrence.
class CalendarOccurrenceIdentity {
  const CalendarOccurrenceIdentity({
    required this.calendar,
    required this.eventId,
    this.recurrenceId,
  }) : assert(eventId != '');

  final CalendarIdentity calendar;
  final String eventId;
  final String? recurrenceId;

  @override
  bool operator ==(Object other) =>
      other is CalendarOccurrenceIdentity &&
      other.calendar == calendar &&
      other.eventId == eventId &&
      other.recurrenceId == recurrenceId;

  @override
  int get hashCode => Object.hash(calendar, eventId, recurrenceId);
}

class SourcedCalendarEvent<T> {
  const SourcedCalendarEvent({required this.id, required this.event});

  final CalendarOccurrenceIdentity id;
  final T event;
}

enum CalendarWriteStatus { chooseCalendar, unavailable, readOnly, ready }

class CalendarWriteSelection {
  const CalendarWriteSelection._(this.status, [this.source]);

  final CalendarWriteStatus status;
  final CalendarSource? source;
}

/// Projects available calendars into modes. A null mode represents All.
class CalendarDirectory {
  CalendarDirectory({
    required Iterable<CalendarSource> sources,
    CalendarModeMemberships? memberships,
  }) : memberships = memberships ?? CalendarModeMemberships(),
       _sources = Map.unmodifiable(_indexSources(sources));

  final CalendarModeMemberships memberships;
  final Map<CalendarIdentity, CalendarSource> _sources;

  CalendarSource? sourceFor(CalendarIdentity id) => _sources[id];

  List<CalendarSource> readableSources({String? modeId}) => List.unmodifiable(
    _sourcesInMode(modeId).where((source) => source.canRead),
  );

  List<CalendarSource> writableSources({String? modeId}) => List.unmodifiable(
    _sourcesInMode(modeId).where((source) => source.canWrite),
  );

  List<SourcedCalendarEvent<T>> visibleEvents<T>(
    Iterable<SourcedCalendarEvent<T>> events, {
    String? modeId,
  }) {
    final readable = readableSources(modeId: modeId)
        .map((source) => source.id)
        .toSet();
    final unique = <CalendarOccurrenceIdentity, SourcedCalendarEvent<T>>{};
    for (final event in events) {
      if (readable.contains(event.id.calendar)) {
        unique.putIfAbsent(event.id, () => event);
      }
    }
    return List.unmodifiable(unique.values);
  }

  CalendarWriteSelection resolveWriteDestination(CalendarIdentity? selected) {
    if (selected == null) {
      return const CalendarWriteSelection._(CalendarWriteStatus.chooseCalendar);
    }
    final source = _sources[selected];
    if (source == null) {
      return const CalendarWriteSelection._(CalendarWriteStatus.unavailable);
    }
    if (!source.canWrite) {
      return CalendarWriteSelection._(CalendarWriteStatus.readOnly, source);
    }
    return CalendarWriteSelection._(CalendarWriteStatus.ready, source);
  }

  Iterable<CalendarSource> _sourcesInMode(String? modeId) {
    if (modeId == null) return _sources.values;
    final allowed = memberships.forMode(modeId);
    return _sources.values.where((source) => allowed.contains(source.id));
  }

  static Map<CalendarIdentity, CalendarSource> _indexSources(
    Iterable<CalendarSource> sources,
  ) {
    final indexed = <CalendarIdentity, CalendarSource>{};
    for (final source in sources) {
      if (indexed.containsKey(source.id)) {
        throw ArgumentError('Calendar source IDs must be unique.');
      }
      indexed[source.id] = source;
    }
    return indexed;
  }
}
