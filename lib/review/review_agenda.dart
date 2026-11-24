import 'review_data.dart';

class ReviewWindow {
  const ReviewWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

class ReviewEvent {
  const ReviewEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
}

class ReviewTask {
  const ReviewTask({
    required this.id,
    required this.title,
    this.date,
    this.dueAt,
    this.done = false,
    this.estimatedMinutes,
    this.completedAt,
    this.canChangePreferredDate = true,
  });

  final String id;
  final String title;
  final DateTime? date;
  final DateTime? dueAt;
  final bool done;
  final int? estimatedMinutes;
  final DateTime? completedAt;
  final bool canChangePreferredDate;

  DateTime? get _dueDay {
    if (dueAt case final instant?) return reviewDay(instant.toLocal());
    if (date case final civil?) return reviewDay(civil);
    return null;
  }

  bool get canRollForward =>
      canChangePreferredDate && !done && date != null && dueAt == null;
}

class ReviewAgenda {
  const ReviewAgenda({
    this.events = const [],
    this.tasks = const [],
    this.unresolvedCaptures = 0,
    this.confirmedActivityMinutes,
    this.availability,
  });

  final List<ReviewEvent> events;
  final List<ReviewTask> tasks;
  final int unresolvedCaptures;
  final int? confirmedActivityMinutes;
  final List<ReviewWindow>? availability;

  ReviewBrief forDay(DateTime date) {
    final day = reviewDay(date);
    final last = nextReviewDay(day);
    final scheduled = [
      for (final event in events)
        if (event.end.isAfter(event.start) &&
            event.start.isBefore(last) &&
            event.end.isAfter(day))
          event,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final due = [
      for (final task in tasks)
        if (!task.done && (task._dueDay?.isBefore(last) ?? false)) task,
    ]..sort((a, b) => a._dueDay!.compareTo(b._dueDay!));
    final booked = _merged([
      for (final event in scheduled)
        if (!event.allDay)
          ?_intersect(ReviewWindow(event.start, event.end), day, last),
    ]);
    final withinDay = availability == null
        ? null
        : _merged([
            for (final span in availability!) ?_intersect(span, day, last),
          ]);
    int? freeMinutes;
    if (withinDay != null) {
      final usable = _duration(withinDay);
      final used = _overlapDuration(withinDay, booked);
      freeMinutes = (usable - used).inMinutes;
    }
    return ReviewBrief(
      events: List.unmodifiable(scheduled),
      openDueTasks: List.unmodifiable(due),
      completedTasks: List.unmodifiable([
        for (final task in tasks)
          if (task.done &&
              task.completedAt != null &&
              reviewDayKey(task.completedAt!.toLocal()) == reviewDayKey(day))
            task,
      ]),
      scheduledMinutes: _duration(booked).inMinutes,
      freeMinutes: freeMinutes,
      knownEffortMinutes: due.fold(
        0,
        (total, task) =>
            total +
            ((task.estimatedMinutes ?? 0) > 0 ? task.estimatedMinutes! : 0),
      ),
      unestimatedTasks: due
          .where((task) => (task.estimatedMinutes ?? 0) <= 0)
          .length,
      unresolvedCaptures: unresolvedCaptures,
      confirmedActivityMinutes: confirmedActivityMinutes,
    );
  }
}

class ReviewBrief {
  const ReviewBrief({
    required this.events,
    required this.openDueTasks,
    required this.completedTasks,
    required this.scheduledMinutes,
    required this.freeMinutes,
    required this.knownEffortMinutes,
    required this.unestimatedTasks,
    required this.unresolvedCaptures,
    required this.confirmedActivityMinutes,
  });

  final List<ReviewEvent> events;
  final List<ReviewTask> openDueTasks;
  final List<ReviewTask> completedTasks;
  final int scheduledMinutes;
  final int? freeMinutes;
  final int knownEffortMinutes;
  final int unestimatedTasks;
  final int unresolvedCaptures;
  final int? confirmedActivityMinutes;
}

ReviewWindow? _intersect(ReviewWindow window, DateTime start, DateTime end) {
  final first = window.start.isAfter(start) ? window.start : start;
  final last = window.end.isBefore(end) ? window.end : end;
  return last.isAfter(first) ? ReviewWindow(first, last) : null;
}

List<ReviewWindow> _merged(List<ReviewWindow> windows) {
  windows.sort((first, second) => first.start.compareTo(second.start));
  final result = <ReviewWindow>[];
  for (final window in windows) {
    if (result.isEmpty || window.start.isAfter(result.last.end)) {
      result.add(window);
    } else if (window.end.isAfter(result.last.end)) {
      result[result.length - 1] = ReviewWindow(result.last.start, window.end);
    }
  }
  return result;
}

Duration _duration(Iterable<ReviewWindow> windows) => windows.fold(
  Duration.zero,
  (total, span) => total + span.end.difference(span.start),
);

Duration _overlapDuration(List<ReviewWindow> left, List<ReviewWindow> right) {
  var leftIndex = 0;
  var rightIndex = 0;
  var total = Duration.zero;
  while (leftIndex < left.length && rightIndex < right.length) {
    final first = left[leftIndex];
    final second = right[rightIndex];
    if (_intersect(first, second.start, second.end) case final overlap?) {
      total += overlap.end.difference(overlap.start);
    }
    if (first.end.isBefore(second.end)) {
      leftIndex++;
    } else {
      rightIndex++;
    }
  }
  return total;
}
