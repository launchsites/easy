import 'package:timezone/data/latest_all.dart' as zone_data;
import 'package:timezone/timezone.dart' as tz;

import '../calendar_page.dart';
import 'calendar_window_feed.dart';
import 'ics_calendar.dart';
import 'internal_recurrence.dart';

typedef InternalWorkspaceEvent = ({
  InternalRecurringEvent series,
  InternalEventOccurrence occurrence,
  CalendarEvent event,
});

bool _zoneDataReady = false;

InternalEventDraft adaptSeriesDraft(
  CalendarEvent value, {
  InternalWorkspaceEvent? original,
}) {
  final old = original?.occurrence.event;
  final previous = original?.event;
  if (old != null &&
      previous != null &&
      value.allDay == previous.allDay &&
      value.start.isAtSameMomentAs(previous.start) &&
      value.end.isAtSameMomentAs(previous.end)) {
    return InternalEventDraft(
      title: value.title,
      start: old.start,
      end: old.end,
      category: value.category,
      location: value.location,
      description: value.description,
    );
  }
  final zone = value.allDay ? null : old?.start.timeZoneId;
  DateTime basis(DateTime value) {
    if (zone != null) {
      if (!_zoneDataReady) {
        zone_data.initializeTimeZones();
        _zoneDataReady = true;
      }
      return tz.TZDateTime.from(value, tz.getLocation(zone));
    }
    return old?.start.kind == IcsDateTimeKind.utc ? value.toUtc() : value;
  }

  return InternalEventDraft.fromDates(
    title: value.title,
    start: basis(value.start),
    end: basis(value.end),
    category: value.category,
    allDay: value.allDay,
    timeZoneId: zone,
    location: value.location,
    description: value.description,
  );
}

class InternalWorkspaceFeed
    extends CalendarWindowFeed<InternalRecurringEvent, InternalWorkspaceEvent> {
  InternalWorkspaceFeed()
    : super(
        expand: expandInternalWorkspace,
        errorMessage:
            'Repeating events could not be displayed for these dates.',
      );
}

List<InternalRecurringEvent> readInternalSeries(Object? json) {
  if (json == null) return const [];
  if (json is! List || json.length > 500) {
    throw const FormatException('Invalid workspace event series.');
  }
  final series = [
    for (final value in json)
      InternalRecurringEvent.fromJson(value as Map<String, Object?>),
  ];
  if (series.map((record) => record.id).toSet().length != series.length) {
    throw const FormatException('Duplicate event series.');
  }
  return List.unmodifiable(series);
}

List<InternalWorkspaceEvent> expandInternalWorkspace(
  CalendarWindowInput<InternalRecurringEvent> input,
) {
  const limit = 16000;
  final result = <InternalWorkspaceEvent>[];
  for (final series in input.sources) {
    final remaining = limit - result.length;
    if (remaining == 0) {
      throw const FormatException('Too many repeating events.');
    }
    for (final occurrence in series.occurrences(
      windowStart: input.start,
      windowEnd: input.end,
      limit: remaining,
    )) {
      final draft = occurrence.event;
      result.add((
        series: series,
        occurrence: occurrence,
        event: CalendarEvent(
          id: occurrence.id,
          title: draft.title,
          start: occurrence.start.toLocal(),
          end: occurrence.end.toLocal(),
          allDay: occurrence.event.allDay,
          category: draft.category,
          location: draft.location,
          description: draft.description,
          recurringSeriesId: series.id,
        ),
      ));
    }
  }
  return List.unmodifiable(result);
}
