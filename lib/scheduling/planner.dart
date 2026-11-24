import 'dart:collection';
import 'dart:math' as math;

const _maxCachedPlacementFailures = 4096;

enum PlannerPriority { low, normal, high }

enum PlannerProblem {
  needsDuration,
  needsDetails,
  unavailableDependency,
  dependencyCycle,
  deadlinePassed,
  noFeasibleTime,
  reservationsNeedReview,
}

class TimeSpan {
  TimeSpan(this.start, this.end) {
    if (!end.isAfter(start)) {
      throw ArgumentError('An interval must end after it starts.');
    }
  }

  final DateTime start;
  final DateTime end;

  Duration get length => end.difference(start);

  bool overlaps(TimeSpan other) =>
      start.isBefore(other.end) && other.start.isBefore(end);

  TimeSpan? intersection(TimeSpan other) {
    final beginning = _later(start, other.start);
    final finish = _earlier(end, other.end);
    return finish.isAfter(beginning) ? TimeSpan(beginning, finish) : null;
  }
}

class PlanningWindow {
  PlanningWindow(this.span, {Set<String>? categories})
    : categories = categories == null ? null : Set.unmodifiable(categories);

  final TimeSpan span;
  final Set<String>? categories;

  bool allows(String category) => categories?.contains(category) ?? true;
}

class FixedCommitment {
  FixedCommitment(
    this.span, {
    this.before = Duration.zero,
    this.after = Duration.zero,
  }) {
    if (before.isNegative || after.isNegative) {
      throw ArgumentError('Commitment buffers must be nonnegative.');
    }
  }

  final TimeSpan span;
  final Duration before;
  final Duration after;
}

class PlanningTask {
  PlanningTask({
    required this.id,
    required this.title,
    required this.category,
    this.remainingMinutes,
    this.earliest,
    this.deadline,
    this.priority = PlannerPriority.normal,
    this.allowSplit = false,
    this.minimumChunkMinutes = 15,
    Set<String> prerequisites = const {},
    this.completed = false,
    this.needsDetails = false,
    this.needsDetailsMessage,
    this.reservationsNeedReview = false,
  }) : prerequisites = Set.unmodifiable(prerequisites) {
    if (id.trim().isEmpty || title.trim().isEmpty) {
      throw ArgumentError('Planning tasks need an ID and title.');
    }
    if ((remainingMinutes ?? 1) <= 0 || minimumChunkMinutes <= 0) {
      throw ArgumentError('Planning durations must be positive.');
    }
  }

  final String id;
  final String title;
  final String category;
  final int? remainingMinutes;
  final DateTime? earliest;
  final DateTime? deadline;
  final PlannerPriority priority;
  final bool allowSplit;
  final int minimumChunkMinutes;
  final Set<String> prerequisites;
  final bool completed;
  final bool needsDetails;
  final String? needsDetailsMessage;
  final bool reservationsNeedReview;
}

sealed class PlanningDecision {
  PlanningTask get task;
}

class ScheduledTask implements PlanningDecision {
  ScheduledTask({
    required this.task,
    required List<TimeSpan> blocks,
    required this.reason,
  }) : blocks = List.unmodifiable(blocks);

  @override
  final PlanningTask task;
  final List<TimeSpan> blocks;
  final String reason;

  DateTime get end => blocks.last.end;
}

class UnscheduledTask implements PlanningDecision {
  const UnscheduledTask(this.task, this.problem, {this.prerequisiteId});

  @override
  final PlanningTask task;
  final PlannerProblem problem;
  final String? prerequisiteId;
}

class ScheduleProposal {
  ScheduleProposal({
    required List<ScheduledTask> scheduled,
    required List<UnscheduledTask> unscheduled,
    Set<String> satisfiedPrerequisites = const {},
    List<String> advisories = const [],
  }) : scheduled = List.unmodifiable(scheduled),
       unscheduled = List.unmodifiable(unscheduled),
       satisfiedPrerequisites = Set.unmodifiable(satisfiedPrerequisites),
       advisories = List.unmodifiable(advisories);

  final List<ScheduledTask> scheduled;
  final List<UnscheduledTask> unscheduled;
  final Set<String> satisfiedPrerequisites;
  final List<String> advisories;
}

/// Plans only within explicitly supplied availability. Commitments are fixed,
/// including accepted suggestions and buffers. A task receives its entire
/// remaining duration or a reason it could not be placed.
ScheduleProposal proposeSchedule({
  required TimeSpan horizon,
  required Iterable<PlanningWindow> availability,
  required Iterable<FixedCommitment> commitments,
  required Iterable<PlanningTask> tasks,
  Set<String> completedPrerequisites = const {},
}) {
  final tasksById = <String, PlanningTask>{};
  for (final task in tasks) {
    if (tasksById.containsKey(task.id)) {
      throw ArgumentError('Task IDs must be unique.');
    }
    tasksById[task.id] = task;
  }

  final finishedAt = <String, DateTime>{
    for (final id in completedPrerequisites) id: horizon.start,
    for (final task in tasksById.values)
      if (task.completed) task.id: horizon.start,
  };
  final satisfied = finishedAt.keys.toSet();
  final remaining = {
    for (final task in tasksById.values)
      if (!finishedAt.containsKey(task.id)) task.id: task,
  };
  final counts = <String, int>{};
  final successors = <String, List<String>>{};
  for (final task in remaining.values) {
    final dependencies = task.prerequisites.where(remaining.containsKey);
    counts[task.id] = dependencies.length;
    for (final dependency in dependencies) {
      successors.putIfAbsent(dependency, () => []).add(task.id);
    }
  }

  final ready = SplayTreeSet<PlanningTask>(
    (first, second) => _compareTasks(first, second, horizon),
  );
  ready.addAll(remaining.values.where((task) => counts[task.id] == 0));

  final categoryWindows = <String, List<TimeSpan>>{};
  final windows = availability.toList();
  final occupied = _merge([
    for (final commitment in commitments) ?_blockedSpan(commitment, horizon),
  ]);
  final scheduled = <ScheduledTask>[];
  final unscheduled = <UnscheduledTask>[];
  // Equivalent failed searches can share a result until occupancy changes.
  final unavailableWindows = <_PlacementKey>{};

  while (ready.isNotEmpty) {
    final task = ready.first;
    ready.remove(task);
    remaining.remove(task.id);

    final knownWindows = categoryWindows.putIfAbsent(
      task.category,
      () => _merge([
        for (final window in windows)
          if (window.allows(task.category)) ?window.span.intersection(horizon),
      ]),
    );
    final outcome = _place(
      task,
      horizon,
      knownWindows,
      occupied,
      finishedAt,
      unavailableWindows,
    );
    switch (outcome) {
      case ScheduledTask():
        scheduled.add(outcome);
        finishedAt[task.id] = outcome.end;
        for (final block in outcome.blocks) {
          _addOccupied(occupied, block);
        }
        unavailableWindows.clear();
      case UnscheduledTask():
        unscheduled.add(outcome);
    }

    for (final id in successors[task.id] ?? const <String>[]) {
      final count = counts[id]! - 1;
      counts[id] = count;
      if (count == 0) ready.add(remaining[id]!);
    }
  }

  final blockedByCycle = remaining.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  unscheduled.addAll(
    blockedByCycle.map(
      (task) => UnscheduledTask(task, PlannerProblem.dependencyCycle),
    ),
  );
  return ScheduleProposal(
    scheduled: scheduled,
    unscheduled: unscheduled,
    satisfiedPrerequisites: satisfied,
  );
}

int _compareTasks(PlanningTask a, PlanningTask b, TimeSpan horizon) {
  double slack(PlanningTask task) {
    final from = _later(task.earliest ?? horizon.start, horizon.start);
    final until = _earlier(task.deadline ?? horizon.end, horizon.end);
    return until.difference(from).inMinutes.toDouble() -
        (task.remainingMinutes ?? 0);
  }

  final bySlack = slack(a).compareTo(slack(b));
  if (bySlack != 0) return bySlack;
  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;
  return a.id.compareTo(b.id);
}

PlanningDecision _place(
  PlanningTask task,
  TimeSpan horizon,
  List<TimeSpan> availability,
  List<TimeSpan> occupied,
  Map<String, DateTime> finishedAt,
  Set<_PlacementKey> unavailableWindows,
) {
  if (task.needsDetails) {
    return UnscheduledTask(task, PlannerProblem.needsDetails);
  }
  if (task.reservationsNeedReview) {
    return UnscheduledTask(task, PlannerProblem.reservationsNeedReview);
  }
  final minutes = task.remainingMinutes;
  if (minutes == null) {
    return UnscheduledTask(task, PlannerProblem.needsDuration);
  }
  final due = task.deadline;
  if (due != null && !due.isAfter(horizon.start)) {
    return UnscheduledTask(task, PlannerProblem.deadlinePassed);
  }

  var release = _later(task.earliest ?? horizon.start, horizon.start);
  final orderedPrerequisites = task.prerequisites.toList()..sort();
  for (final id in orderedPrerequisites) {
    final end = finishedAt[id];
    if (end == null) {
      return UnscheduledTask(
        task,
        PlannerProblem.unavailableDependency,
        prerequisiteId: id,
      );
    }
    release = _later(release, end);
  }
  final deadline = _earlier(due ?? horizon.end, horizon.end);
  if (!deadline.isAfter(release) ||
      deadline.difference(release).inMinutes < minutes) {
    return UnscheduledTask(task, PlannerProblem.noFeasibleTime);
  }

  final splitMinimum = task.allowSplit ? task.minimumChunkMinutes : 0;
  final key = (task.category, release, deadline, minutes, splitMinimum);
  if (unavailableWindows.contains(key)) {
    return UnscheduledTask(task, PlannerProblem.noFeasibleTime);
  }
  final minimum = splitMinimum == 0 ? minutes : math.min(minutes, splitMinimum);
  final candidates = _freeWindows(
    availability,
    occupied,
    release,
    deadline,
    Duration(minutes: minimum),
  );
  final chunks = _takeBlocks(task, minutes, candidates);
  if (chunks.isEmpty) {
    if (unavailableWindows.length < _maxCachedPlacementFailures) {
      unavailableWindows.add(key);
    }
    return UnscheduledTask(task, PlannerProblem.noFeasibleTime);
  }
  return ScheduledTask(
    task: task,
    blocks: chunks,
    reason: chunks.length == 1
        ? 'Fits a free window within your availability.'
        : 'Fits across ${chunks.length} free windows with your minimum block length.',
  );
}

typedef _PlacementKey = (String, DateTime, DateTime, int, int);

List<TimeSpan> _takeBlocks(
  PlanningTask task,
  int minutes,
  Iterable<TimeSpan> candidates,
) {
  final split = <TimeSpan>[];
  // Prefer an uninterrupted block even when earlier fragments are available.
  for (final span in candidates) {
    if (span.length.inMinutes >= minutes) {
      return [TimeSpan(span.start, span.start.add(Duration(minutes: minutes)))];
    }
    if (task.allowSplit) split.add(span);
  }
  if (!task.allowSplit) return const [];

  final minimum = task.minimumChunkMinutes;
  final chronological = _allocateChunks(split, minutes, minimum);
  if (chronological.isNotEmpty) return chronological;

  // An early short gap can consume one of the admissible chunks. The largest
  // gaps determine whether a split is possible at all.
  final largest =
      split.where((span) => span.length.inMinutes >= minimum).toList()
        ..sort((a, b) {
          final size = b.length.compareTo(a.length);
          return size == 0 ? a.start.compareTo(b.start) : size;
        });
  var total = 0;
  final chosen = <TimeSpan>[];
  for (final span in largest) {
    if (chosen.length >= minutes ~/ minimum) break;
    chosen.add(span);
    total += span.length.inMinutes;
    if (total >= minutes) {
      chosen.sort((a, b) => a.start.compareTo(b.start));
      var effortLeft = minutes;
      final blocks = <TimeSpan>[];
      for (var index = 0; index < chosen.length; index++) {
        final window = chosen[index];
        final reserve = (chosen.length - index - 1) * minimum;
        final take = math.min(window.length.inMinutes, effortLeft - reserve);
        blocks.add(
          TimeSpan(window.start, window.start.add(Duration(minutes: take))),
        );
        effortLeft -= take;
      }
      return blocks;
    }
  }
  return const [];
}

List<TimeSpan> _allocateChunks(
  List<TimeSpan> candidates,
  int minutes,
  int minimum,
) {
  final chunks = <TimeSpan>[];
  var remaining = minutes;
  for (final span in candidates) {
    final capacity = span.length.inMinutes;
    final take = capacity >= remaining
        ? remaining
        : math.min(capacity, remaining - minimum);
    if (take < minimum) continue;
    chunks.add(TimeSpan(span.start, span.start.add(Duration(minutes: take))));
    remaining -= take;
    if (remaining == 0) return chunks;
  }
  return const [];
}

TimeSpan? _blockedSpan(FixedCommitment commitment, TimeSpan horizon) {
  final span = commitment.span;
  final left = span.start.difference(horizon.start);
  final right = horizon.end.difference(span.end);
  final start = commitment.before >= left
      ? horizon.start
      : span.start.subtract(commitment.before);
  final end = commitment.after >= right
      ? horizon.end
      : span.end.add(commitment.after);
  return end.isAfter(start) ? TimeSpan(start, end) : null;
}

List<TimeSpan> _merge(List<TimeSpan> spans) {
  if (spans.isEmpty) return [];
  spans.sort((a, b) => a.start.compareTo(b.start));
  final result = <TimeSpan>[];
  var current = spans.first;
  for (final span in spans.skip(1)) {
    if (span.start.isAfter(current.end)) {
      result.add(current);
      current = span;
    } else if (span.end.isAfter(current.end)) {
      current = TimeSpan(current.start, span.end);
    }
  }
  result.add(current);
  return result;
}

void _addOccupied(List<TimeSpan> occupied, TimeSpan block) {
  // A block only replaces the adjacent occupied ranges it touches.
  final first = _firstEndingAfter(occupied, block.start, includeTouching: true);
  var start = block.start;
  var end = block.end;
  var last = first;
  while (last < occupied.length && !occupied[last].start.isAfter(end)) {
    final existing = occupied[last++];
    start = _earlier(start, existing.start);
    end = _later(end, existing.end);
  }
  occupied.replaceRange(first, last, [TimeSpan(start, end)]);
}

int _firstEndingAfter(
  List<TimeSpan> occupied,
  DateTime start, {
  bool includeTouching = false,
}) {
  var low = 0;
  var high = occupied.length;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    final end = occupied[mid].end.compareTo(start);
    if (end < 0 || (end == 0 && !includeTouching)) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

Iterable<TimeSpan> _freeWindows(
  List<TimeSpan> windows,
  List<TimeSpan> occupied,
  DateTime release,
  DateTime deadline,
  Duration minimum,
) sync* {
  for (final window in windows) {
    if (!window.start.isBefore(deadline)) break;
    var cursor = _later(window.start, release);
    final end = _earlier(window.end, deadline);
    if (end.difference(cursor) < minimum) continue;
    for (
      var index = _firstEndingAfter(occupied, cursor);
      index < occupied.length;
      index++
    ) {
      final span = occupied[index];
      if (!span.start.isBefore(end)) break;
      if (span.start.difference(cursor) >= minimum) {
        yield TimeSpan(cursor, span.start);
      }
      cursor = _later(cursor, span.end);
      if (end.difference(cursor) < minimum) break;
    }
    if (end.difference(cursor) >= minimum) yield TimeSpan(cursor, end);
  }
}

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
