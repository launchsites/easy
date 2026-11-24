import 'dart:math' as math;

import '../calendar_page.dart';
import 'availability_settings.dart';
import 'planner.dart' show TimeSpan;

final class TaskObjectiveAvailability {
  TaskObjectiveAvailability._(this.reviewedAt, Map<String, Duration> values)
    : byCategory = Map.unmodifiable(values);

  final DateTime reviewedAt;

  /// A missing category has no verified timing. Zero is a known closed gap.
  final Map<String, Duration> byCategory;
}

/// Finds work starting now under saved rules and verified calendar coverage.
/// Pass [calendarComplete] only with the complete, current accepted timeline.
/// For a bounded timeline, [verifiedCalendarSpan] is the half-open range whose
/// positive and negative calendar facts are current, including selected sources.
TaskObjectiveAvailability deriveTaskObjectiveAvailability({
  required DateTime now,
  required DateTime horizonEnd,
  required SchedulingSettings? settings,
  required List<CalendarEvent> confirmedEvents,
  required Iterable<String> categories,
  TimeSpan? verifiedCalendarSpan,
  bool calendarComplete = false,
}) {
  TaskObjectiveAvailability unknown() => TaskObjectiveAvailability._(now, {});
  if (!horizonEnd.isAfter(now)) {
    throw ArgumentError.value(horizonEnd, 'horizonEnd', 'Must follow now.');
  }
  if (settings == null || settings.availability.isEmpty) return unknown();
  final scopes = categories.toSet();
  if (scopes.isEmpty) return unknown();

  final coverage = calendarComplete ? null : verifiedCalendarSpan;
  if (!calendarComplete && coverage == null) return unknown();
  var end = _earlier(
    horizonEnd,
    now.add(const Duration(days: maxPlanningWindowDays)),
  );
  if (coverage != null) {
    final earliest = coverage.start.add(
      Duration(minutes: settings.afterMinutes),
    );
    if (now.isBefore(earliest)) return unknown();
    final travelLead = settings.routes.fold<int>(
      0,
      (max, route) => math.max(max, route.minutes),
    );
    end = _earlier(
      end,
      coverage.end.subtract(
        Duration(minutes: settings.beforeMinutes + travelLead),
      ),
    );
    if (!end.isAfter(now)) return unknown();
  }

  final commitments = <PlacedCommitment>[];
  final seen = <String>{};
  final placeIds = {for (final place in settings.places) place.id};
  for (final event in confirmedEvents) {
    if (!event.blocksTime) continue;
    if (coverage != null &&
        (!event.start.isBefore(coverage.end) ||
            !coverage.start.isBefore(event.end))) {
      continue;
    }
    if (event.id.trim().isEmpty ||
        !seen.add(event.id) ||
        !event.end.isAfter(event.start)) {
      return unknown();
    }
    commitments.add(
      PlacedCommitment(
        id: event.id,
        span: TimeSpan(event.start, event.end),
        placeId: placeIds.contains(event.savedPlaceId)
            ? event.savedPlaceId
            : null,
      ),
    );
  }
  if (coverage != null &&
      _unknownTravelAcrossCoverage(
        settings,
        placeIds,
        commitments,
        now,
        coverage.start,
      )) {
    return unknown();
  }

  final horizon = TimeSpan(now, end);
  final inputs = settings.planningInputs(
    horizon: horizon,
    categories: scopes,
    commitments: commitments,
  );
  for (final commitment in inputs.commitments) {
    final occupiedFrom = commitment.span.start.subtract(commitment.before);
    if (!occupiedFrom.isAfter(now)) {
      end = now;
      break;
    }
    end = _earlier(end, occupiedFrom);
  }

  final values = {for (final category in scopes) category: Duration.zero};
  for (final window in inputs.availability) {
    if (window.span.start.isAfter(now)) break;
    final time = _earlier(window.span.end, end).difference(now);
    for (final scope in window.categories ?? scopes) {
      if (time > values[scope]!) values[scope] = time;
    }
  }
  return TaskObjectiveAvailability._(now, values);
}

bool _unknownTravelAcrossCoverage(
  SchedulingSettings settings,
  Set<String> placeIds,
  List<PlacedCommitment> commitments,
  DateTime now,
  DateTime coverageStart,
) {
  if (settings.routes.length == placeIds.length * (placeIds.length - 1)) {
    return false;
  }
  PlacedCommitment? previous;
  PlacedCommitment? next;
  for (final item in commitments) {
    if (item.placeId == null || item.span.start.isBefore(coverageStart)) {
      continue;
    }
    if (item.span.start.isAfter(now)) {
      if (next == null || _compare(item, next) < 0) next = item;
    } else {
      if (previous == null || _compare(item, previous) > 0) previous = item;
    }
  }
  final from = previous?.placeId;
  final to = next?.placeId;
  if (from != null && to != null) return false;
  return (from == null ? placeIds : [from]).any(
    (left) => (to == null ? placeIds : [to]).any(
      (right) => settings.travelDuration(left, right) == null,
    ),
  );
}

int _compare(PlacedCommitment left, PlacedCommitment right) {
  final start = left.span.start.compareTo(right.span.start);
  if (start != 0) return start;
  final end = left.span.end.compareTo(right.span.end);
  return end == 0 ? left.id.compareTo(right.id) : end;
}

DateTime _earlier(DateTime left, DateTime right) =>
    left.isBefore(right) ? left : right;
