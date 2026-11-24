import 'ics_calendar.dart';
import 'ics_occurrence_expander.dart';

class IcsImportOccurrence {
  const IcsImportOccurrence._(this.localId, this.occurrence);

  final String localId;
  final IcsOccurrence occurrence;

  String get sourceUid => occurrence.sourceUid;
}

class IcsImportPreview {
  IcsImportPreview._(
    this.importId,
    this.calendar,
    Iterable<IcsImportOccurrence> items,
  ) : items = List.unmodifiable(items);

  final String importId;
  final IcsCalendar calendar;
  final List<IcsImportOccurrence> items;
}

/// Stages events without changing storage. Use a fresh import ID for each file
/// import, and reuse that ID when paging through the same staged calendar.
IcsImportPreview previewIcsImport(
  IcsCalendar calendar, {
  required String importId,
  required DateTime windowStart,
  required DateTime windowEnd,
  String? floatingTimeZone,
  int limit = 10000,
}) {
  if (importId.trim().isEmpty) throw ArgumentError.value(importId, 'importId');
  final occurrences = expandIcsCalendar(
    calendar,
    windowStart: windowStart,
    windowEnd: windowEnd,
    floatingTimeZone: floatingTimeZone,
    limit: limit,
  );
  return IcsImportPreview._(
    importId,
    calendar,
    occurrences.map((occurrence) {
      final recurrence = occurrence.recurrenceId;
      final segments = [
        importId,
        occurrence.sourceIndex.toString(),
        if (recurrence != null) ...[
          recurrence.kind.name,
          recurrence.timeZoneId ?? '',
          recurrence.components.toIso8601String(),
        ],
      ];
      return IcsImportOccurrence._(
        segments.map(Uri.encodeComponent).join('/'),
        occurrence,
      );
    }),
  );
}

class IcsExportRecord {
  const IcsExportRecord({
    required this.uid,
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.description,
    this.location,
  });

  final String uid;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String? description;
  final String? location;
}

/// Exports standalone workspace records. For a previously imported series,
/// encode the original [IcsImportPreview.calendar] to retain its recurrence.
IcsCalendar exportIcsRecords(
  Iterable<IcsExportRecord> records, {
  String? name,
}) {
  return IcsCalendar(
    name: name,
    events: records.map((record) {
      final encodeDate = record.allDay ? IcsDateTime.date : IcsDateTime.utc;
      final end = record.end;
      return IcsEvent(
        uid: record.uid,
        summary: record.title,
        start: encodeDate(record.start),
        end:
            end == null ||
                (!record.allDay && end.isAtSameMomentAs(record.start))
            ? null
            : encodeDate(end),
        description: record.description,
        location: record.location,
      );
    }),
  );
}
