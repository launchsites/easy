import 'activity_model.dart';

class ActivityActualTarget {
  const ActivityActualTarget({required this.record, this.scheduled});

  /// The canonical task or event. Its plan is the original booked interval.
  final ActivityTarget record;

  /// The currently accepted event times, when such a timed window exists.
  final ActivityWindow? scheduled;
}

enum ActivityActualKind { startTimer, manualTimes, scheduledTimes }

class ActivityActualSelection {
  const ActivityActualSelection.startTimer(ActivityActualTarget target)
    : this._(target, ActivityActualKind.startTimer);

  const ActivityActualSelection.manualTimes(
    ActivityActualTarget target,
    ActivityWindow window,
  ) : this._(target, ActivityActualKind.manualTimes, window);

  factory ActivityActualSelection.scheduledTimes(ActivityActualTarget target) {
    final window = target.scheduled;
    if (window == null) {
      throw StateError('There are no scheduled times to record.');
    }
    return ActivityActualSelection._(
      target,
      ActivityActualKind.scheduledTimes,
      window,
    );
  }

  const ActivityActualSelection._(this._target, this.kind, [this.window]);

  final ActivityActualTarget _target;
  final ActivityActualKind kind;
  final ActivityWindow? window;

  /// Recheck the reviewed target and the actual-time ledger immediately before
  /// the caller's workspace CAS, with the current clock and active timer.
  String? issue({
    required ActivityData current,
    required ActivityActualTarget target,
    required DateTime now,
  }) {
    final before = _target.record;
    final record = target.record;
    if (before.id != record.id ||
        before.kind != record.kind ||
        before.title != record.title ||
        before.category != record.category ||
        !_sameWindow(before.plan, record.plan) ||
        (kind == ActivityActualKind.scheduledTimes &&
            !_sameWindow(window, target.scheduled))) {
      return 'This task or event changed. Open its current details to track time.';
    }
    final actual = window;
    if (actual == null) {
      if (current.active != null) {
        return 'Finish the current activity before starting another timer.';
      }
    } else if (actual.end.isAfter(now)) {
      return 'Actual time cannot end in the future.';
    }

    final start = actual?.start ?? now;
    for (final entry in current.records) {
      for (final span in entry.spans) {
        final end = span.end;
        if (end != null && (!end.isAfter(start) || !end.isAfter(span.start))) {
          continue;
        }
        if (actual == null || span.start.isBefore(actual.end)) {
          return 'This time overlaps an activity already in your log.';
        }
      }
    }
    return null;
  }

  ActivityData apply({
    required ActivityData current,
    required ActivityActualTarget target,
    required DateTime now,
  }) {
    if (issue(current: current, target: target, now: now) case final problem?) {
      throw StateError(problem);
    }
    final record = target.record;
    final actual = window;
    if (actual == null) {
      return current.begin(
        now: now,
        title: record.title,
        category: record.category,
        target: record,
      );
    }
    return current.logActual(
      title: record.title,
      category: record.category,
      target: record,
      spans: [ActivitySpan(start: actual.start, end: actual.end)],
      timeSource: kind == ActivityActualKind.scheduledTimes
          ? ActivityTimeSource.confirmedSchedule
          : ActivityTimeSource.manual,
    );
  }
}

bool _sameWindow(ActivityWindow? left, ActivityWindow? right) => left == null
    ? right == null
    : right != null &&
          left.start.isAtSameMomentAs(right.start) &&
          left.end.isAtSameMomentAs(right.end);
