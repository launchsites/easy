import '../calendar_page.dart';
import '../scheduling/availability_settings.dart';
import '../scheduling/planner.dart';
import 'review_agenda.dart';
import 'review_data.dart';

final class ReviewDayAvailability {
  ReviewDayAvailability._({
    required Iterable<ReviewWindow> windows,
    required this.categoryCount,
    required this.hasAllDayCommitment,
    required Iterable<TravelIssueKind> travelIssues,
  }) : windows = List.unmodifiable(windows),
       travelIssues = Set.unmodifiable(travelIssues);

  /// The attainable union across the requested category scope. These spans
  /// already exclude fixed time, buffers, and unresolved travel gaps.
  final List<ReviewWindow> windows;

  /// The requested categories that have saved hours.
  final int categoryCount;

  /// All-day calendar rows occupy planning time while ReviewAgenda still
  /// omits their civil duration from its elapsed scheduled-time total.
  final bool hasAllDayCommitment;
  final Set<TravelIssueKind> travelIssues;
}

/// Returns known time for a civil review day when the caller has confirmed
/// the complete calendar timeline, including neighboring placed commitments.
/// An empty result is a known closed day. Null leaves available time unknown.
ReviewDayAvailability? deriveReviewDayAvailability({
  required DateTime day,
  required SchedulingSettings? settings,
  required Iterable<String> categories,
  required Iterable<CalendarEvent> events,
  required bool calendarComplete,
}) {
  if (!calendarComplete || settings == null) return null;
  final allowed = settings.availability.where(
    (entry) => entry.kind == AvailabilityKind.available,
  );
  final scopes = categories
      .toSet()
      .where(
        (scope) =>
            allowed.any((entry) => entry.categories?.contains(scope) ?? true),
      )
      .toSet();
  if (scopes.isEmpty) return null;
  final start = reviewDay(day);
  final horizon = TimeSpan(start, nextReviewDay(start));
  final unique = <String, CalendarEvent>{};
  for (final event in events) {
    if (event.id.trim().isEmpty || !event.end.isAfter(event.start)) return null;
    final previous = unique[event.id];
    if (previous != null && _calendarFacts(previous) != _calendarFacts(event)) {
      return null;
    }
    unique[event.id] = event;
  }

  // Keep appointments whose configured buffers could reach this day and the
  // nearest placed neighbors needed to determine any travel across its edges.
  var maxRouteMinutes = 0;
  for (final route in settings.routes) {
    if (route.minutes > maxRouteMinutes) maxRouteMinutes = route.minutes;
  }
  final earliestEnd = horizon.start.subtract(
    Duration(minutes: settings.afterMinutes),
  );
  final latestStart = horizon.end.add(
    Duration(
      minutes: settings.beforeMinutes + settings.afterMinutes + maxRouteMinutes,
    ),
  );
  final placeIds = {for (final place in settings.places) place.id};
  final relevant = <String, CalendarEvent>{};
  CalendarEvent? before;
  CalendarEvent? after;
  var allDay = false;
  for (final event in unique.values) {
    if (event.end.isAfter(earliestEnd) && event.start.isBefore(latestStart)) {
      relevant[event.id] = event;
    }
    if (event.allDay &&
        event.start.isBefore(horizon.end) &&
        event.end.isAfter(horizon.start)) {
      allDay = true;
    }
    if (!placeIds.contains(event.savedPlaceId)) continue;
    if (event.start.isBefore(horizon.start)) {
      if (before == null || _compareEvent(event, before) > 0) before = event;
    } else if (!event.start.isBefore(latestStart)) {
      if (after == null || _compareEvent(event, after) < 0) after = event;
    }
  }
  if (before != null) relevant[before.id] = before;
  if (after != null) relevant[after.id] = after;

  final input = settings.planningInputs(
    horizon: horizon,
    categories: scopes,
    commitments: [
      for (final event in relevant.values)
        PlacedCommitment(
          id: event.id,
          span: TimeSpan(event.start, event.end),
          placeId: placeIds.contains(event.savedPlaceId)
              ? event.savedPlaceId
              : null,
        ),
    ],
  );
  return ReviewDayAvailability._(
    windows: unoccupiedPlanningWindows(
      horizon: horizon,
      availability: input.availability,
      commitments: input.commitments,
    ).map((window) => ReviewWindow(window.start, window.end)),
    categoryCount: scopes.length,
    hasAllDayCommitment: allDay,
    travelIssues: input.travelIssues.map((issue) => issue.kind),
  );
}

Object _calendarFacts(CalendarEvent event) => (
  event.start.microsecondsSinceEpoch,
  event.end.microsecondsSinceEpoch,
  event.savedPlaceId,
  event.allDay,
  event.sourceLabel,
  event.plannedTaskId,
  event.recurringSeriesId,
);

int _compareEvent(CalendarEvent left, CalendarEvent right) {
  final start = left.start.compareTo(right.start);
  if (start != 0) return start;
  final end = left.end.compareTo(right.end);
  return end == 0 ? left.id.compareTo(right.id) : end;
}
