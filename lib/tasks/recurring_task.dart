import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import '../calendar_sources/internal_recurrence.dart';
import '../scheduling/planner.dart';
import '../task_model.dart';

export '../calendar_sources/internal_recurrence.dart'
    show
        InternalOccurrenceScope,
        InternalRecurrenceFrequency,
        InternalRecurrenceRule;

enum RecurringTaskStatus { pending, completed, skipped }

enum RecurringTaskScheduleIssue {
  inactive('Reopen this task before scheduling it.'),
  unavailableClock('A task time falls in a daylight-saving gap.'),
  timeOrder('The due time must follow the earliest start.'),
  beforeEarliest('The block starts before the task is available.'),
  afterDeadline('The block ends after the task is due.'),
  prerequisite('Complete the task’s prerequisites first.'),
  unavailable('The block is outside the task’s available hours.'),
  commitment('The block overlaps a calendar commitment.'),
  softDate('Confirm the block can move outside the task’s preferred date.'),
  shortBlock('The block is shorter than this task’s minimum duration.');

  const RecurringTaskScheduleIssue(this.message);
  final String message;
}

class RecurringTaskScheduleException implements Exception {
  const RecurringTaskScheduleException(this.issue);
  final RecurringTaskScheduleIssue issue;

  @override
  String toString() => issue.message;
}

/// A user-controlled wall-clock preference, independent of notification delivery.
class TaskReminderPreference {
  TaskReminderPreference({required this.minuteOfDay, this.dayOffset = 0}) {
    if (minuteOfDay < 0 ||
        minuteOfDay >= 1440 ||
        dayOffset < -365 ||
        dayOffset > 0) {
      throw ArgumentError('Choose a reminder time on or before the task date.');
    }
  }

  factory TaskReminderPreference.fromJson(Map<String, Object?> json) =>
      TaskReminderPreference(
        minuteOfDay: json['minuteOfDay'] as int,
        dayOffset: json['dayOffset'] as int? ?? 0,
      );

  final int minuteOfDay;
  final int dayOffset;

  Map<String, Object?> toJson() => {
    'minuteOfDay': minuteOfDay,
    if (dayOffset != 0) 'dayOffset': dayOffset,
  };
}

class RecurringTaskOccurrence {
  const RecurringTaskOccurrence._({
    required this.seriesId,
    required this.identityDate,
    required this.scheduledDate,
    required this.task,
    required this.status,
    required this.rule,
    required this.reminder,
    required this.reminderAt,
    required this.constraintIssue,
    required this.manualSchedule,
    required this._revision,
    required this._slot,
  });

  final String seriesId;

  /// Civil day represented by UTC fields, stable when the occurrence moves.
  final DateTime identityDate;

  /// Effective civil day represented by UTC fields.
  final DateTime scheduledDate;
  final TaskItem task;
  final RecurringTaskStatus status;
  final InternalRecurrenceRule rule;
  final TaskReminderPreference? reminder;
  final DateTime? reminderAt;
  final RecurringTaskScheduleIssue? constraintIssue;
  final TimeSpan? manualSchedule;
  final int _revision;
  final InternalEventOccurrence? _slot;

  String get id => task.id;
  bool get canSchedule =>
      status == RecurringTaskStatus.pending && constraintIssue == null;
}

/// One durable repeating task and sparse occurrence decisions.
class RecurringTaskSeries {
  factory RecurringTaskSeries({
    required String id,
    required TaskItem task,
    required InternalRecurrenceRule rule,
    DateTime? startDate,
    DateTime? today,
    String? timeZoneId,
    TaskReminderPreference? reminder,
  }) {
    final clock = _TaskClock(timeZoneId);
    final first = _day(
      startDate ?? task.date ?? clock.localAt(today ?? DateTime.now()),
    );
    return RecurringTaskSeries._(
      id: id,
      timeZoneId: timeZoneId,
      clock: clock,
      schedule: InternalRecurringEvent(
        id: id,
        event: _slotOn(first),
        rule: rule,
      ),
      templates: {first: _TaskTemplate.capture(task, first, clock, reminder)},
    );
  }

  RecurringTaskSeries._({
    required this.id,
    required this.timeZoneId,
    required this._clock,
    required InternalRecurringEvent schedule,
    required Map<DateTime, _TaskTemplate> templates,
    Map<DateTime, _TaskTemplate> edits = const {},
    Map<DateTime, _TaskOutcome> outcomes = const {},
    Map<DateTime, _TaskPlacement> placements = const {},
    this.revision = 0,
  }) : _schedule = schedule,
       _templates = Map.unmodifiable(templates),
       _edits = Map.unmodifiable(edits),
       _outcomes = Map.unmodifiable(outcomes),
       _placements = Map.unmodifiable(placements) {
    if (id != schedule.id || templates.isEmpty || revision < 0) {
      throw const FormatException('Invalid recurring task identity.');
    }
  }

  factory RecurringTaskSeries.fromJson(Map<String, Object?> json) {
    final zone = json['timeZoneId'] as String?;
    return RecurringTaskSeries._(
      id: json['id'] as String,
      timeZoneId: zone,
      clock: _TaskClock(zone),
      revision: json['revision'] as int? ?? 0,
      schedule: InternalRecurringEvent.fromJson(_map(json['schedule'])),
      templates: _readByDay(json['templates'], _TaskTemplate.fromJson),
      edits: _readByDay(json['edits'], _TaskTemplate.fromJson),
      outcomes: _readByDay(json['outcomes'], _TaskOutcome.fromJson),
      placements: _readByDay(json['placements'], _TaskPlacement.fromJson),
    );
  }

  final String id;
  final String? timeZoneId;
  final int revision;
  final _TaskClock _clock;
  final InternalRecurringEvent _schedule;
  final Map<DateTime, _TaskTemplate> _templates;
  final Map<DateTime, _TaskTemplate> _edits;
  final Map<DateTime, _TaskOutcome> _outcomes;
  final Map<DateTime, _TaskPlacement> _placements;

  Map<String, Object?> toJson() => {
    'id': id,
    if (timeZoneId != null) 'timeZoneId': timeZoneId,
    'revision': revision,
    'schedule': _schedule.toJson(),
    'templates': _byDay(_templates, (value) => value.toJson()),
    if (_edits.isNotEmpty) 'edits': _byDay(_edits, (value) => value.toJson()),
    if (_outcomes.isNotEmpty)
      'outcomes': _byDay(_outcomes, (value) => value.toJson()),
    if (_placements.isNotEmpty)
      'placements': _byDay(_placements, (value) => value.toJson()),
  };

  /// A bounded half-open range of civil dates, including confirmed completions.
  List<RecurringTaskOccurrence> occurrences({
    required DateTime windowStart,
    required DateTime windowEnd,
    bool includeSkipped = false,
    int limit = 10000,
  }) {
    final first = _day(windowStart);
    final last = _day(windowEnd);
    if (!last.isAfter(first) ||
        last.difference(first).inDays > 367 ||
        limit < 1 ||
        limit > 10000) {
      throw ArgumentError('Choose a positive task window of at most 367 days.');
    }
    final result = <RecurringTaskOccurrence>[];
    void include(RecurringTaskOccurrence occurrence) {
      if (result.length >= limit) {
        throw StateError('Too many task occurrences in this window.');
      }
      result.add(occurrence);
    }

    for (final slot in _slots(first, last)) {
      if (_outcomes.containsKey(slot.identityDate)) continue;
      include(_pending(slot));
    }
    for (final entry in _outcomes.entries) {
      final outcome = entry.value;
      if (outcome.date.isBefore(first) ||
          !outcome.date.isBefore(last) ||
          (!includeSkipped && outcome.status == RecurringTaskStatus.skipped)) {
        continue;
      }
      include(
        _project(
          identity: entry.key,
          date: outcome.date,
          details: outcome.details,
          rule: outcome.rule,
          status: outcome.status,
          completedAt: outcome.completedAt,
          placement: outcome.placement,
        ),
      );
    }
    result.sort((a, b) {
      final dateOrder = a.scheduledDate.compareTo(b.scheduledDate);
      return dateOrder == 0
          ? a.identityDate.compareTo(b.identityDate)
          : dateOrder;
    });
    return List.unmodifiable(result);
  }

  /// Recorded completions can outlive the visible repeat window.
  Iterable<RecurringTaskOccurrence> get completions sync* {
    for (final entry in _outcomes.entries) {
      final outcome = entry.value;
      if (outcome.status != RecurringTaskStatus.completed) continue;
      yield _project(
        identity: entry.key,
        date: outcome.date,
        details: outcome.details,
        rule: outcome.rule,
        status: outcome.status,
        completedAt: outcome.completedAt,
        placement: outcome.placement,
      );
    }
  }

  TaskItem fieldsForDate(RecurringTaskOccurrence occurrence, DateTime date) {
    _requirePending(occurrence);
    final shifted = _project(
      identity: occurrence.identityDate,
      date: _day(date),
      details: _detailsAt(occurrence.identityDate),
      rule: occurrence.rule,
    );
    if (shifted.constraintIssue case final issue?) {
      throw RecurringTaskScheduleException(issue);
    }
    return shifted.task;
  }

  RecurringTaskSeries complete(
    RecurringTaskOccurrence occurrence, {
    required DateTime at,
  }) {
    _requireCurrent(occurrence);
    if (occurrence.status == RecurringTaskStatus.completed) return this;
    return _record(occurrence, RecurringTaskStatus.completed, at.toUtc());
  }

  RecurringTaskSeries reopen(RecurringTaskOccurrence occurrence) {
    _requireCurrent(occurrence);
    if (!_outcomes.containsKey(occurrence.identityDate)) return this;
    return _updated(outcomes: {..._outcomes}..remove(occurrence.identityDate));
  }

  RecurringTaskSeries skip(
    RecurringTaskOccurrence occurrence, {
    required InternalOccurrenceScope scope,
  }) {
    if (scope == InternalOccurrenceScope.one) {
      _requireCurrent(occurrence);
      if (occurrence.status == RecurringTaskStatus.skipped) return this;
      return _record(occurrence, RecurringTaskStatus.skipped);
    }
    final slot = _requirePending(occurrence);
    final boundary = scope == InternalOccurrenceScope.future
        ? slot.identityDate
        : _firstIdentity;
    return _updated(
      schedule: _schedule.skip(slot, scope: scope),
      templates: _before(_templates, boundary, keepFirst: true),
      edits: _before(_edits, boundary),
      placements: _before(_placements, boundary),
    );
  }

  /// Edits the template or just this occurrence. Existing completion history
  /// stays attached to the occurrence and retains its confirmed details.
  RecurringTaskSeries edit(
    RecurringTaskOccurrence occurrence, {
    required InternalOccurrenceScope scope,
    required TaskItem task,
    InternalRecurrenceRule? rule,
    DateTime? startDate,
    TaskReminderPreference? reminder,
    bool clearReminder = false,
  }) {
    final slot = _requirePending(occurrence);
    final identity = occurrence.identityDate;
    final date = _day(startDate ?? occurrence.scheduledDate);
    final details = _TaskTemplate.capture(
      task,
      date,
      _clock,
      clearReminder ? null : reminder ?? occurrence.reminder,
    );
    final previousRule = scope == InternalOccurrenceScope.series
        ? _schedule.rule
        : occurrence.rule;
    final changesRule = rule != null && rule != previousRule;
    final changesDate = date != occurrence.scheduledDate;

    if (scope == InternalOccurrenceScope.one) {
      if (rule != null) {
        throw ArgumentError(
          'A single occurrence cannot change the repeat rule.',
        );
      }
      final placement = _placements[identity];
      if (placement != null) _validatePlacement(details, date, placement);
      return _updated(
        schedule: changesDate
            ? _schedule.edit(slot, scope: scope, event: _slotOn(date))
            : _schedule,
        edits: {..._edits, identity: details},
        placements: placement == null
            ? _placements
            : {
                ..._placements,
                identity: _TaskPlacement(
                  date,
                  placement.span,
                  placement.outsideSoftDate,
                ),
              },
      );
    }
    final boundary = scope == InternalOccurrenceScope.future
        ? identity
        : _firstIdentity;
    if (changesDate || changesRule) {
      final affected = _placements.keys.any(
        (day) => !day.isBefore(boundary) && !_outcomes.containsKey(day),
      );
      if (affected) {
        throw StateError(
          'Clear affected manual blocks before changing the repeat dates.',
        );
      }
    }

    final updated = _updated(
      schedule: changesDate || changesRule
          ? _schedule.edit(slot, scope: scope, event: _slotOn(date), rule: rule)
          : _schedule,
      templates: {..._before(_templates, boundary), boundary: details},
      edits: changesRule
          ? _before(_edits, boundary)
          : ({..._edits}..remove(identity)),
    );
    for (final entry in _placements.entries) {
      if (entry.key.isBefore(boundary) || _outcomes.containsKey(entry.key)) {
        continue;
      }
      updated._validatePlacement(
        updated._detailsAt(entry.key),
        entry.value.date,
        entry.value,
      );
    }
    return updated;
  }

  RecurringTaskScheduleIssue? manualScheduleIssue(
    RecurringTaskOccurrence occurrence, {
    required TimeSpan span,
    Iterable<TimeSpan> commitments = const [],
    Iterable<PlanningWindow>? availability,
    Set<String> completedPrerequisiteIds = const {},
    bool allowOutsideSoftDate = false,
  }) {
    _requireCurrent(occurrence);
    if (occurrence.status != RecurringTaskStatus.pending) {
      return RecurringTaskScheduleIssue.inactive;
    }
    final issue = _placementIssue(occurrence, span, allowOutsideSoftDate);
    if (issue != null) return issue;
    if (!completedPrerequisiteIds.containsAll(
      occurrence.task.prerequisiteIds,
    )) {
      return RecurringTaskScheduleIssue.prerequisite;
    }
    if (availability != null &&
        !_insideAvailability(span, availability, occurrence.task.category)) {
      return RecurringTaskScheduleIssue.unavailable;
    }
    if (commitments.any(span.overlaps) ||
        _placements.entries.any(
          (entry) =>
              entry.key != occurrence.identityDate &&
              !_outcomes.containsKey(entry.key) &&
              span.overlaps(entry.value.span),
        )) {
      return RecurringTaskScheduleIssue.commitment;
    }
    return null;
  }

  RecurringTaskSeries scheduleManually(
    RecurringTaskOccurrence occurrence, {
    required TimeSpan span,
    Iterable<TimeSpan> commitments = const [],
    Iterable<PlanningWindow>? availability,
    Set<String> completedPrerequisiteIds = const {},
    bool allowOutsideSoftDate = false,
  }) {
    final issue = manualScheduleIssue(
      occurrence,
      span: span,
      commitments: commitments,
      availability: availability,
      completedPrerequisiteIds: completedPrerequisiteIds,
      allowOutsideSoftDate: allowOutsideSoftDate,
    );
    if (issue != null) throw RecurringTaskScheduleException(issue);
    return _updated(
      placements: {
        ..._placements,
        occurrence.identityDate: _TaskPlacement(
          occurrence.scheduledDate,
          TimeSpan(span.start.toUtc(), span.end.toUtc()),
          allowOutsideSoftDate,
        ),
      },
    );
  }

  RecurringTaskSeries clearManualSchedule(RecurringTaskOccurrence occurrence) {
    _requirePending(occurrence);
    if (!_placements.containsKey(occurrence.identityDate)) return this;
    return _updated(
      placements: {..._placements}..remove(occurrence.identityDate),
    );
  }

  List<InternalEventOccurrence> _slots(DateTime first, DateTime last) =>
      _schedule.occurrences(windowStart: first, windowEnd: last);

  DateTime get _firstIdentity => _templates.keys.reduce(
    (first, next) => first.isBefore(next) ? first : next,
  );

  _TaskTemplate _detailsAt(DateTime identity) {
    final edited = _edits[identity];
    if (edited != null) return edited;
    DateTime? latest;
    for (final boundary in _templates.keys) {
      if (!boundary.isAfter(identity) &&
          (latest == null || boundary.isAfter(latest))) {
        latest = boundary;
      }
    }
    return _templates[latest] ??
        (throw const FormatException('Missing recurring task template.'));
  }

  RecurringTaskOccurrence _pending(InternalEventOccurrence slot) => _project(
    identity: slot.identityDate,
    date: _day(slot.start),
    details: _detailsAt(slot.identityDate),
    rule: slot.rule,
    placement: _placements[slot.identityDate],
    slot: slot,
  );

  RecurringTaskOccurrence _project({
    required DateTime identity,
    required DateTime date,
    required _TaskTemplate details,
    required InternalRecurrenceRule rule,
    RecurringTaskStatus status = RecurringTaskStatus.pending,
    DateTime? completedAt,
    _TaskPlacement? placement,
    InternalEventOccurrence? slot,
  }) {
    final earliest = details.earliest?.resolve(date, _clock);
    final due = details.due?.resolve(date, _clock);
    final missingTime =
        (details.earliest != null && earliest == null) ||
        (details.due != null && due == null);
    final orderInvalid =
        earliest != null && due != null && !due.isAfter(earliest);
    final preferred = details.softDateOffset;
    final softDate = preferred == null ? null : _plus(date, preferred);
    final reminder = details.reminder;
    return RecurringTaskOccurrence._(
      seriesId: id,
      identityDate: identity,
      scheduledDate: date,
      task: details.project(
        _occurrenceId(id, identity),
        softDate: softDate == null
            ? null
            : DateTime(softDate.year, softDate.month, softDate.day),
        earliest: earliest,
        due: due,
        completedAt: completedAt,
      ),
      status: status,
      rule: rule,
      reminder: reminder,
      reminderAt: reminder == null || status != RecurringTaskStatus.pending
          ? null
          : _clock.resolve(
              _plus(date, reminder.dayOffset),
              reminder.minuteOfDay * 60,
            ),
      constraintIssue: missingTime
          ? RecurringTaskScheduleIssue.unavailableClock
          : orderInvalid
          ? RecurringTaskScheduleIssue.timeOrder
          : null,
      manualSchedule: placement?.span,
      revision: revision,
      slot: slot,
    );
  }

  void _validatePlacement(
    _TaskTemplate details,
    DateTime date,
    _TaskPlacement placement,
  ) {
    final projection = _project(
      identity: date,
      date: date,
      details: details,
      rule: _schedule.rule,
    );
    final issue = _placementIssue(
      projection,
      placement.span,
      placement.outsideSoftDate,
    );
    if (issue != null) throw RecurringTaskScheduleException(issue);
  }

  RecurringTaskScheduleIssue? _placementIssue(
    RecurringTaskOccurrence occurrence,
    TimeSpan span,
    bool outsideSoftDate,
  ) {
    final task = occurrence.task;
    if (occurrence.constraintIssue case final issue?) return issue;
    if (task.earliestStart case final earliest?
        when span.start.isBefore(earliest)) {
      return RecurringTaskScheduleIssue.beforeEarliest;
    }
    if (task.dueAt case final due? when span.end.isAfter(due)) {
      return RecurringTaskScheduleIssue.afterDeadline;
    }
    if (task.date case final date? when !outsideSoftDate) {
      final first = _day(_clock.localAt(span.start));
      final last = _day(
        _clock.localAt(span.end.subtract(const Duration(microseconds: 1))),
      );
      if (first != _day(date) || last != _day(date)) {
        return RecurringTaskScheduleIssue.softDate;
      }
    }
    final minimum = task.allowSplit
        ? task.minimumChunkMinutes
        : task.estimatedMinutes;
    return minimum != null && span.length < Duration(minutes: minimum)
        ? RecurringTaskScheduleIssue.shortBlock
        : null;
  }

  RecurringTaskSeries _record(
    RecurringTaskOccurrence occurrence,
    RecurringTaskStatus status, [
    DateTime? at,
  ]) {
    final identity = occurrence.identityDate;
    final previous = _outcomes[identity];
    final outcome = _TaskOutcome(
      date: occurrence.scheduledDate,
      rule: occurrence.rule,
      details: previous?.details ?? _detailsAt(identity),
      status: status,
      completedAt: at,
      placement: previous?.placement ?? _placements[identity],
    );
    return _updated(
      outcomes: {..._outcomes, identity: outcome},
      placements: {..._placements}..remove(identity),
    );
  }

  void _requireCurrent(RecurringTaskOccurrence occurrence) {
    if (occurrence.seriesId != id || occurrence._revision != revision) {
      throw StateError(
        'The repeating task changed. Open the occurrence again.',
      );
    }
  }

  InternalEventOccurrence _requirePending(RecurringTaskOccurrence occurrence) {
    _requireCurrent(occurrence);
    return occurrence._slot ??
        (throw StateError('Reopen this task before editing its schedule.'));
  }

  RecurringTaskSeries _updated({
    InternalRecurringEvent? schedule,
    Map<DateTime, _TaskTemplate>? templates,
    Map<DateTime, _TaskTemplate>? edits,
    Map<DateTime, _TaskOutcome>? outcomes,
    Map<DateTime, _TaskPlacement>? placements,
  }) => RecurringTaskSeries._(
    id: id,
    timeZoneId: timeZoneId,
    clock: _clock,
    revision: revision + 1,
    schedule: schedule ?? _schedule,
    templates: templates ?? _templates,
    edits: edits ?? _edits,
    outcomes: outcomes ?? _outcomes,
    placements: placements ?? _placements,
  );
}

class _TaskTemplate {
  const _TaskTemplate(
    this.task,
    this.softDateOffset,
    this.earliest,
    this.due,
    this.reminder,
  );

  factory _TaskTemplate.capture(
    TaskItem task,
    DateTime date,
    _TaskClock clock,
    TaskReminderPreference? reminder,
  ) {
    final split = taskSplitIssue(
      allowSplit: task.allowSplit,
      minimumChunkMinutes: task.minimumChunkMinutes,
      estimatedMinutes: task.estimatedMinutes,
    );
    if (task.title.trim().isEmpty ||
        (task.estimatedMinutes ?? 1) < 1 ||
        task.prerequisiteIds.any((id) => id.trim().isEmpty) ||
        task.prerequisiteIds.toSet().length != task.prerequisiteIds.length ||
        task.prerequisiteIds.contains(task.id)) {
      throw ArgumentError(
        'Check the task title, category, effort and prerequisites.',
      );
    }
    if (split != null) throw ArgumentError(split);
    final earliest = task.earliestStart;
    final due = task.dueAt;
    if (earliest != null && due != null && !due.isAfter(earliest)) {
      throw ArgumentError(RecurringTaskScheduleIssue.timeOrder.message);
    }
    return _TaskTemplate(
      _taskFields(task),
      task.date == null ? null : _day(task.date!).difference(date).inDays,
      earliest == null ? null : _TaskWallTime.capture(earliest, date, clock),
      due == null ? null : _TaskWallTime.capture(due, date, clock),
      reminder,
    );
  }

  factory _TaskTemplate.fromJson(Map<String, Object?> json) {
    final task = TaskItem(
      id: '',
      title: json['title'] as String,
      category: json['category'] as String,
      parentId: json['parentId'] as String?,
      notes: json['notes'] as String?,
      priority: json['priority'] == null
          ? null
          : TaskPriority.values.byName(json['priority'] as String),
      estimatedMinutes: json['estimatedMinutes'] as int?,
      prerequisiteIds: List.unmodifiable(
        (json['prerequisiteIds'] as List<Object?>? ?? const []).cast<String>(),
      ),
      allowSplit: json['allowSplit'] as bool? ?? false,
      minimumChunkMinutes:
          json['minimumChunkMinutes'] as int? ?? defaultTaskChunkMinutes,
    );
    _TaskTemplate.capture(task, DateTime.utc(2000), _TaskClock(null), null);
    return _TaskTemplate(
      task,
      json['softDateOffset'] as int?,
      json['earliest'] == null
          ? null
          : _TaskWallTime.fromJson(_map(json['earliest'])),
      json['due'] == null ? null : _TaskWallTime.fromJson(_map(json['due'])),
      json['reminder'] == null
          ? null
          : TaskReminderPreference.fromJson(_map(json['reminder'])),
    );
  }

  final TaskItem task;
  final int? softDateOffset;
  final _TaskWallTime? earliest;
  final _TaskWallTime? due;
  final TaskReminderPreference? reminder;

  Map<String, Object?> toJson() => {
    'title': task.title,
    'category': task.category,
    if (task.parentId != null) 'parentId': task.parentId,
    if (task.notes != null) 'notes': task.notes,
    if (task.priority != null) 'priority': task.priority!.name,
    if (task.estimatedMinutes != null)
      'estimatedMinutes': task.estimatedMinutes,
    if (task.prerequisiteIds.isNotEmpty)
      'prerequisiteIds': task.prerequisiteIds,
    if (task.allowSplit) 'allowSplit': true,
    if (task.minimumChunkMinutes != defaultTaskChunkMinutes)
      'minimumChunkMinutes': task.minimumChunkMinutes,
    if (softDateOffset != null) 'softDateOffset': softDateOffset,
    if (earliest != null) 'earliest': earliest!.toJson(),
    if (due != null) 'due': due!.toJson(),
    if (reminder != null) 'reminder': reminder!.toJson(),
  };

  TaskItem project(
    String id, {
    DateTime? softDate,
    DateTime? earliest,
    DateTime? due,
    DateTime? completedAt,
  }) => TaskItem(
    id: id,
    title: task.title,
    category: task.category,
    parentId: task.parentId,
    notes: task.notes,
    estimatedMinutes: task.estimatedMinutes,
    priority: task.priority,
    prerequisiteIds: task.prerequisiteIds,
    allowSplit: task.allowSplit,
    minimumChunkMinutes: task.minimumChunkMinutes,
    date: softDate,
    earliestStart: earliest,
    dueAt: due,
    done: completedAt != null,
    completedAt: completedAt,
  );
}

TaskItem _taskFields(TaskItem task) => TaskItem(
  id: '',
  title: task.title,
  category: task.category,
  parentId: task.parentId,
  notes: task.notes,
  estimatedMinutes: task.estimatedMinutes,
  priority: task.priority,
  prerequisiteIds: List.unmodifiable(task.prerequisiteIds),
  allowSplit: task.allowSplit,
  minimumChunkMinutes: task.minimumChunkMinutes,
);

class _TaskWallTime {
  _TaskWallTime(
    this.offset,
    this.secondOfDay, {
    this.subsecondMicros = 0,
    this.laterFold = false,
  }) {
    if (secondOfDay < 0 ||
        secondOfDay >= Duration.secondsPerDay ||
        subsecondMicros < 0 ||
        subsecondMicros >= Duration.microsecondsPerSecond) {
      throw const FormatException('Invalid task clock time.');
    }
  }

  factory _TaskWallTime.capture(
    DateTime value,
    DateTime date,
    _TaskClock clock,
  ) {
    final local = clock.localAt(value);
    final localDay = _day(local);
    final second = local.hour * 3600 + local.minute * 60 + local.second;
    final fraction = local.millisecond * 1000 + local.microsecond;
    final earlier = clock.resolve(localDay, second, subsecondMicros: fraction);
    return _TaskWallTime(
      localDay.difference(date).inDays,
      second,
      subsecondMicros: fraction,
      laterFold: earlier != null && value.isAfter(earlier),
    );
  }

  factory _TaskWallTime.fromJson(Map<String, Object?> json) => _TaskWallTime(
    json['offset'] as int,
    json['secondOfDay'] as int,
    subsecondMicros: json['subsecondMicros'] as int? ?? 0,
    laterFold: json['laterFold'] as bool? ?? false,
  );

  final int offset;
  final int secondOfDay;
  final int subsecondMicros;
  final bool laterFold;

  DateTime? resolve(DateTime date, _TaskClock clock) => clock.resolve(
    _plus(date, offset),
    secondOfDay,
    subsecondMicros: subsecondMicros,
    laterFold: laterFold,
  );

  Map<String, Object?> toJson() => {
    'offset': offset,
    'secondOfDay': secondOfDay,
    if (subsecondMicros != 0) 'subsecondMicros': subsecondMicros,
    if (laterFold) 'laterFold': true,
  };
}

class _TaskOutcome {
  _TaskOutcome({
    required this.date,
    required this.rule,
    required this.details,
    required this.status,
    this.completedAt,
    this.placement,
  }) {
    if (status == RecurringTaskStatus.pending ||
        (status == RecurringTaskStatus.completed) != (completedAt != null)) {
      throw const FormatException('Invalid repeating task outcome.');
    }
  }

  factory _TaskOutcome.fromJson(Map<String, Object?> json) => _TaskOutcome(
    date: _readDay(json['date']),
    rule: InternalRecurrenceRule.fromJson(_map(json['rule'])),
    details: _TaskTemplate.fromJson(_map(json['details'])),
    status: RecurringTaskStatus.values.byName(json['status'] as String),
    completedAt: json['completedAt'] == null
        ? null
        : _readUtc(json['completedAt']),
    placement: json['placement'] == null
        ? null
        : _TaskPlacement.fromJson(_map(json['placement'])),
  );

  final DateTime date;
  final InternalRecurrenceRule rule;
  final _TaskTemplate details;
  final RecurringTaskStatus status;
  final DateTime? completedAt;
  final _TaskPlacement? placement;

  Map<String, Object?> toJson() => {
    'date': date.toIso8601String(),
    'rule': rule.toJson(),
    'details': details.toJson(),
    'status': status.name,
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (placement != null) 'placement': placement!.toJson(),
  };
}

class _TaskPlacement {
  const _TaskPlacement(this.date, this.span, this.outsideSoftDate);

  factory _TaskPlacement.fromJson(Map<String, Object?> json) => _TaskPlacement(
    _readDay(json['date']),
    TimeSpan(_readUtc(json['start']), _readUtc(json['end'])),
    json['outsideSoftDate'] as bool? ?? false,
  );

  final DateTime date;
  final TimeSpan span;
  final bool outsideSoftDate;

  Map<String, Object?> toJson() => {
    'date': date.toIso8601String(),
    'start': span.start.toIso8601String(),
    'end': span.end.toIso8601String(),
    if (outsideSoftDate) 'outsideSoftDate': true,
  };
}

class _TaskClock {
  _TaskClock(String? name) : location = name == null ? null : _readZone(name);

  final timezone.Location? location;

  static timezone.Location _readZone(String name) {
    if (timezone.timeZoneDatabase.locations.isEmpty) {
      timezone_data.initializeTimeZones();
    }
    return timezone.timeZoneDatabase.locations[name] ??
        (throw ArgumentError('Unknown task time zone $name.'));
  }

  DateTime localAt(DateTime value) {
    final zone = location;
    return zone == null
        ? value.toLocal()
        : timezone.TZDateTime.from(value, zone);
  }

  DateTime? resolve(
    DateTime date,
    int secondOfDay, {
    int subsecondMicros = 0,
    bool laterFold = false,
  }) {
    final wall = date.add(
      Duration(seconds: secondOfDay, microseconds: subsecondMicros),
    );
    final offsets = {
      for (final delta in [-2, 0, 2])
        localAt(_plus(wall, delta)).timeZoneOffset,
    };
    DateTime? match;
    for (final offset in offsets) {
      final candidate = wall.subtract(offset);
      final local = localAt(candidate);
      if (_day(local) == date &&
          local.hour * 3600 + local.minute * 60 + local.second == secondOfDay &&
          (match == null ||
              (laterFold
                  ? candidate.isAfter(match)
                  : candidate.isBefore(match)))) {
        match = candidate;
      }
    }
    return match;
  }
}

bool _insideAvailability(
  TimeSpan span,
  Iterable<PlanningWindow> windows,
  String category,
) {
  final allowed =
      windows
          .where(
            (window) => window.allows(category) && window.span.overlaps(span),
          )
          .map((window) => window.span)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  var through = span.start;
  for (final window in allowed) {
    if (window.start.isAfter(through)) return false;
    if (window.end.isAfter(through)) through = window.end;
    if (!through.isBefore(span.end)) return true;
  }
  return false;
}

InternalEventDraft _slotOn(DateTime date) => InternalEventDraft.fromDates(
  title: 'Task recurrence',
  category: 'task',
  start: date.add(const Duration(hours: 12)),
  end: date.add(const Duration(hours: 12, minutes: 1)),
);

String _occurrenceId(String id, DateTime date) =>
    'recurring-task/${Uri.encodeComponent(id)}/${date.toIso8601String().split('T').first}';

DateTime _day(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
DateTime _plus(DateTime date, int days) => date.add(Duration(days: days));

DateTime _readUtc(Object? value) {
  final date = value is String ? DateTime.tryParse(value) : null;
  if (date == null || !date.isUtc || date.toIso8601String() != value) {
    throw const FormatException('Invalid repeating task date.');
  }
  return date;
}

DateTime _readDay(Object? value) {
  final date = _readUtc(value);
  if (date != _day(date)) {
    throw const FormatException('Expected a civil task date.');
  }
  return date;
}

Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;

Map<DateTime, T> _before<T>(
  Map<DateTime, T> values,
  DateTime date, {
  bool keepFirst = false,
}) => {
  for (final entry in values.entries)
    if (entry.key.isBefore(date) || (keepFirst && entry.key == date))
      entry.key: entry.value,
};

List<Map<String, Object?>> _byDay<T>(
  Map<DateTime, T> values,
  Map<String, Object?> Function(T) encode,
) => [
  for (final entry in values.entries)
    {'date': entry.key.toIso8601String(), 'value': encode(entry.value)},
];

Map<DateTime, T> _readByDay<T>(
  Object? input,
  T Function(Map<String, Object?>) decode,
) {
  final values = <DateTime, T>{};
  for (final row in input as List<Object?>? ?? const []) {
    final json = _map(row);
    final date = _readDay(json['date']);
    if (values.containsKey(date)) {
      throw const FormatException('Duplicate repeating task date.');
    }
    values[date] = decode(_map(json['value']));
  }
  return values;
}
