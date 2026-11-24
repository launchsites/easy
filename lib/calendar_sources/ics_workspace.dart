import 'dart:convert';

import '../calendar_page.dart';
import 'calendar_directory.dart';
import 'ics_calendar.dart';
import 'ics_import_export.dart';

const workspaceIcsAccountId = 'easy-ics';

class WorkspaceIcsCalendar {
  WorkspaceIcsCalendar({
    required this.id,
    required this.name,
    required this.document,
  }) {
    if (id.isEmpty || id.length > 160 || name.isEmpty || name.length > 200) {
      throw const FormatException('Invalid imported calendar name or ID.');
    }
    if (document.isEmpty ||
        document.length > importByteLimit ||
        utf8.encode(document).length > importByteLimit) {
      throw const FormatException('The iCalendar file exceeds 4 MB.');
    }
  }

  factory WorkspaceIcsCalendar.fromJson(Map<String, dynamic> json) =>
      WorkspaceIcsCalendar(
        id: json['id'] as String,
        name: json['name'] as String,
        document: json['document'] as String,
      );

  static const importByteLimit = IcsCalendar.maxImportBytes;
  static const maxCalendars = 12;

  final String id;
  final String name;
  final String document;

  CalendarIdentity get identity =>
      CalendarIdentity(accountId: workspaceIcsAccountId, calendarId: id);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'document': document,
  };

  static List<WorkspaceIcsCalendar> decodeList(Object? stored) {
    if (stored == null) return const [];
    if (stored is! List || stored.length > maxCalendars) {
      throw const FormatException('Invalid imported calendar sources.');
    }
    final calendars = [
      for (final entry in stored)
        WorkspaceIcsCalendar.fromJson(entry as Map<String, dynamic>),
    ];
    if (calendars.map((calendar) => calendar.id).toSet().length !=
        calendars.length) {
      throw const FormatException('Imported calendar IDs must be unique.');
    }
    return List.unmodifiable(calendars);
  }
}

typedef IcsWorkspaceWindow = ({
  List<WorkspaceIcsCalendar> calendars,
  DateTime start,
  DateTime end,
});

typedef IcsWorkspaceEvent = ({CalendarIdentity calendar, CalendarEvent event});

List<IcsWorkspaceEvent> expandWorkspaceIcs(IcsWorkspaceWindow input) {
  const windowLimit = 20000;
  final result = <IcsWorkspaceEvent>[];
  for (final calendar in input.calendars) {
    final remaining = windowLimit - result.length;
    if (remaining == 0) {
      throw const FormatException(
        'Too many imported events in this calendar view.',
      );
    }
    final preview = previewIcsImport(
      IcsCalendar.parse(calendar.document),
      importId: calendar.id,
      windowStart: input.start,
      windowEnd: input.end,
      limit: remaining,
    );
    for (final item in preview.items) {
      final occurrence = item.occurrence;
      final source = occurrence.event;
      result.add((
        calendar: calendar.identity,
        event: CalendarEvent(
          id: 'ics:${item.localId}',
          title: source.summary.isEmpty ? 'Untitled event' : source.summary,
          start: occurrence.start.toLocal(),
          end: occurrence.end.toLocal(),
          category: 'calendar',
          allDay: occurrence.allDay,
          location: source.location,
          description: source.description,
          sourceLabel: calendar.name,
        ),
      ));
    }
  }
  return List.unmodifiable(result);
}
