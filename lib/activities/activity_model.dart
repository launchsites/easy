import 'dart:convert';

import '../workout_plan.dart';

enum ActivityStatus { planned, running, paused, finished }

enum ActivityTargetKind { task, event }

enum ActivityTimeSource { timer, manual, confirmedSchedule }

class ActivityWindow {
  ActivityWindow(this.start, this.end) {
    if (!end.isAfter(start)) {
      throw const FormatException('End time must be after start time.');
    }
  }

  factory ActivityWindow.fromJson(Map<String, dynamic> json) =>
      ActivityWindow(_date(json['start']), _date(json['end']));

  final DateTime start;
  final DateTime end;

  Duration get length => end.difference(start);

  Map<String, Object?> toJson() => {
    'start': _timestamp(start),
    'end': _timestamp(end),
  };
}

class ActivityTarget {
  const ActivityTarget({
    required this.id,
    required this.title,
    required this.category,
    required this.kind,
    this.plan,
  });

  factory ActivityTarget.fromJson(Map<String, dynamic> json) => ActivityTarget(
    id: json['id'] as String,
    title: json['title'] as String,
    category: json['category'] as String,
    kind: ActivityTargetKind.values.byName(json['kind'] as String),
    plan: _optionalObject(json['plan'], ActivityWindow.fromJson),
  );

  final String id;
  final String title;
  final String category;
  final ActivityTargetKind kind;
  final ActivityWindow? plan;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'category': category,
    'kind': kind.name,
    if (plan != null) 'plan': plan!.toJson(),
  };
}

class ActivitySpan {
  ActivitySpan({required this.start, this.end}) {
    if (end?.isBefore(start) ?? false) {
      throw const FormatException(
        'An activity segment cannot end before it starts.',
      );
    }
  }

  factory ActivitySpan.fromJson(Map<String, dynamic> json) => ActivitySpan(
    start: _date(json['start']),
    end: _optionalDate(json['end']),
  );

  final DateTime start;
  final DateTime? end;

  Duration elapsedAt(DateTime now) =>
      _latest(end ?? now, start).difference(start);

  Map<String, Object?> toJson() => {
    'start': _timestamp(start),
    if (end != null) 'end': _timestamp(end!),
  };
}

class RoutineStep {
  const RoutineStep({required this.id, required this.title});

  factory RoutineStep.fromJson(Map<String, dynamic> json) =>
      RoutineStep(id: json['id'] as String, title: json['title'] as String);

  final String id;
  final String title;

  Map<String, Object?> toJson() => {'id': id, 'title': title};
}

class RoutineTemplate {
  RoutineTemplate({
    required this.id,
    required this.title,
    required this.category,
    this.schedule,
    List<RoutineStep> steps = const [],
  }) : steps = List.unmodifiable(steps) {
    _label(id, 'Routine ID');
    _label(title, 'Routine name');
    _validateSteps(steps);
    if (schedule?.kind == WorkoutScheduleKind.weekdays &&
        schedule!.weekdays.isEmpty) {
      throw const FormatException('Choose one or more weekdays.');
    }
  }

  factory RoutineTemplate.fromJson(Map<String, dynamic> json) =>
      RoutineTemplate(
        id: json['id'] as String,
        title: json['title'] as String,
        category: json['category'] as String,
        schedule: _optionalObject(json['schedule'], WorkoutSchedule.fromJson),
        steps: _objects(json['steps']).map(RoutineStep.fromJson).toList(),
      );

  final String id;
  final String title;
  final String category;
  final WorkoutSchedule? schedule;
  final List<RoutineStep> steps;

  bool occursOn(DateTime day) => schedule?.occursOn(day) ?? true;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'category': category,
    if (schedule != null) 'schedule': schedule!.toJson(),
    'steps': [for (final step in steps) step.toJson()],
  };
}

class ActivityRecord {
  ActivityRecord({
    required this.id,
    required this.title,
    required this.category,
    this.plan,
    this.target,
    this.routineId,
    List<ActivitySpan> spans = const [],
    List<RoutineStep> steps = const [],
    Set<String> checkedStepIds = const {},
    this.finishedAt,
    this.timeSource,
  }) : spans = List.unmodifiable(spans),
       steps = List.unmodifiable(steps),
       checkedStepIds = Set.unmodifiable(checkedStepIds) {
    _label(id, 'Activity ID');
    _label(title, 'Activity name');
    _validateSteps(steps);
    if (!{for (final step in steps) step.id}.containsAll(checkedStepIds)) {
      throw const FormatException(
        'An activity checklist contains an unknown step.',
      );
    }
    if (spans.isEmpty && (plan == null || finishedAt != null)) {
      throw const FormatException('An activity needs a plan or actual time.');
    }
    DateTime? previousEnd;
    for (final (index, span) in spans.indexed) {
      if ((previousEnd != null && span.start.isBefore(previousEnd)) ||
          (span.end == null &&
              (index != spans.length - 1 || finishedAt != null))) {
        throw const FormatException(
          'Activity segments must be ordered and cannot overlap.',
        );
      }
      previousEnd = span.end;
    }
    if (finishedAt != null &&
        previousEnd != null &&
        finishedAt!.isBefore(previousEnd)) {
      throw const FormatException(
        'An activity cannot finish before its last segment ends.',
      );
    }
  }

  factory ActivityRecord.fromJson(Map<String, dynamic> json) => ActivityRecord(
    id: json['id'] as String,
    title: json['title'] as String,
    category: json['category'] as String,
    plan: _optionalObject(json['plan'], ActivityWindow.fromJson),
    target: _optionalObject(json['target'], ActivityTarget.fromJson),
    routineId: json['routineId'] as String?,
    spans: _objects(json['spans']).map(ActivitySpan.fromJson).toList(),
    steps: _objects(json['steps']).map(RoutineStep.fromJson).toList(),
    checkedStepIds: (json['checkedStepIds'] as List<dynamic>)
        .cast<String>()
        .toSet(),
    finishedAt: _optionalDate(json['finishedAt']),
    timeSource: ActivityTimeSource.values.asNameMap()[json['timeSource']],
  );

  final String id;
  final String title;
  final String category;
  final ActivityWindow? plan;
  final ActivityTarget? target;
  final String? routineId;
  final List<ActivitySpan> spans;
  final List<RoutineStep> steps;
  final Set<String> checkedStepIds;
  final DateTime? finishedAt;
  final ActivityTimeSource? timeSource;

  ActivityStatus get status {
    if (finishedAt != null) return ActivityStatus.finished;
    if (spans.isEmpty) return ActivityStatus.planned;
    return spans.last.end == null
        ? ActivityStatus.running
        : ActivityStatus.paused;
  }

  DateTime get time => spans.firstOrNull?.start ?? plan!.start;

  Duration elapsedAt(DateTime now) => spans.fold(
    Duration.zero,
    (elapsed, span) => elapsed + span.elapsedAt(now),
  );

  ActivityRecord _change({
    String? title,
    String? category,
    List<ActivitySpan>? spans,
    Set<String>? checkedStepIds,
    DateTime? finishedAt,
    ActivityTimeSource? timeSource,
  }) => ActivityRecord(
    id: id,
    title: title ?? this.title,
    category: category ?? this.category,
    plan: plan,
    target: target,
    routineId: routineId,
    spans: spans ?? this.spans,
    steps: steps,
    checkedStepIds: checkedStepIds ?? this.checkedStepIds,
    finishedAt: finishedAt ?? this.finishedAt,
    timeSource: timeSource ?? this.timeSource,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'category': category,
    if (plan != null) 'plan': plan!.toJson(),
    if (target != null) 'target': target!.toJson(),
    if (routineId != null) 'routineId': routineId,
    'spans': [for (final span in spans) span.toJson()],
    'steps': [for (final step in steps) step.toJson()],
    'checkedStepIds': checkedStepIds.toList()..sort(),
    if (finishedAt != null) 'finishedAt': _timestamp(finishedAt!),
    if (timeSource != null) 'timeSource': timeSource!.name,
  };
}

class ActivityData {
  ActivityData({
    List<ActivityRecord> records = const [],
    List<RoutineTemplate> routines = const [],
  }) : records = List.unmodifiable(records),
       routines = List.unmodifiable(routines) {
    if ({for (final record in records) record.id}.length != records.length ||
        {for (final routine in routines) routine.id}.length !=
            routines.length) {
      throw const FormatException('Duplicate activity record.');
    }
    if (records.where(_unfinished).length > 1) {
      throw const FormatException('Only one activity can be in progress.');
    }
    _checkOverlap(records);
  }

  factory ActivityData.decode(String encoded) =>
      ActivityData.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

  factory ActivityData.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported activity version.');
    }
    return ActivityData(
      records: _objects(json['records']).map(ActivityRecord.fromJson).toList(),
      routines: _objects(json['routines'])
          .map(RoutineTemplate.fromJson)
          .toList(),
    );
  }

  final List<ActivityRecord> records;
  final List<RoutineTemplate> routines;

  ActivityRecord? get active => records.where(_unfinished).firstOrNull;

  ActivityData begin({
    required DateTime now,
    required String title,
    required String category,
    ActivityTarget? target,
  }) {
    _assertCanStart();
    return _saveRecord(
      ActivityRecord(
        id: newActivityId(),
        title: title,
        category: category,
        plan: target?.plan,
        target: target,
        spans: [ActivitySpan(start: now)],
        timeSource: ActivityTimeSource.timer,
      ),
    );
  }

  ActivityData plan({
    String? id,
    required String title,
    required String category,
    required ActivityWindow window,
    ActivityTarget? target,
  }) {
    if (id != null && _record(id).status != ActivityStatus.planned) {
      throw StateError(
        'The original plan is retained after an activity starts.',
      );
    }
    return _saveRecord(
      ActivityRecord(
        id: id ?? newActivityId(),
        title: title,
        category: category,
        plan: window,
        target: target,
      ),
    );
  }

  ActivityData beginPlan(String id, DateTime now) {
    _assertCanStart();
    final record = _record(id);
    if (record.status != ActivityStatus.planned) {
      throw StateError('This plan has already started.');
    }
    return _saveRecord(
      record._change(
        spans: [ActivitySpan(start: now)],
        timeSource: ActivityTimeSource.timer,
      ),
    );
  }

  ActivityData beginRoutine(String id, DateTime now) {
    _assertCanStart();
    final routine = routines.where((routine) => routine.id == id).firstOrNull;
    if (routine == null) throw StateError('This routine is unavailable.');
    return _saveRecord(
      ActivityRecord(
        id: newActivityId(),
        title: routine.title,
        category: routine.category,
        routineId: id,
        spans: [ActivitySpan(start: now)],
        steps: routine.steps,
        timeSource: ActivityTimeSource.timer,
      ),
    );
  }

  ActivityData pause(DateTime now) {
    final record = active;
    if (record == null || record.status != ActivityStatus.running) {
      throw StateError('There is no running activity to pause.');
    }
    return _saveRecord(record._change(spans: _closed(record, now)));
  }

  ActivityData resume(DateTime now) {
    final record = active;
    if (record == null || record.status != ActivityStatus.paused) {
      throw StateError('There is no paused activity to resume.');
    }
    final start = _latest(now, record.spans.last.end!);
    return _saveRecord(
      record._change(
        spans: [
          ...record.spans,
          ActivitySpan(start: start),
        ],
      ),
    );
  }

  ActivityData finish(DateTime now) {
    final record = active;
    if (record == null) throw StateError('There is no activity to finish.');
    final spans = _closed(record, now);
    return _saveRecord(
      record._change(spans: spans, finishedAt: _latest(now, spans.last.end!)),
    );
  }

  ActivityData setStep(String id, String stepId, bool checked) {
    final record = _record(id);
    if (!record.steps.any((step) => step.id == stepId)) {
      throw StateError('This checklist step is unavailable.');
    }
    final stepIds = record.checkedStepIds.toSet();
    if (checked) {
      stepIds.add(stepId);
    } else {
      stepIds.remove(stepId);
    }
    return _saveRecord(record._change(checkedStepIds: stepIds));
  }

  ActivityData logActual({
    String? id,
    required String title,
    required String category,
    required List<ActivitySpan> spans,
    ActivityTarget? target,
    ActivityTimeSource timeSource = ActivityTimeSource.manual,
  }) {
    if (spans.isEmpty || spans.any((span) => span.end == null)) {
      throw const FormatException(
        'Enter a start and end for each actual segment.',
      );
    }
    final previous = id == null ? null : _record(id);
    if (previous != null && _unfinished(previous)) {
      throw StateError('Finish this activity before editing its actual time.');
    }
    return _saveRecord(
      previous?._change(
            title: title,
            category: category,
            spans: spans,
            finishedAt: spans.last.end,
            timeSource: timeSource,
          ) ??
          ActivityRecord(
            id: newActivityId(),
            title: title,
            category: category,
            target: target,
            plan: target?.plan,
            spans: spans,
            finishedAt: spans.last.end,
            timeSource: timeSource,
          ),
    );
  }

  ActivityData saveRoutine(RoutineTemplate routine) => ActivityData(
    records: records,
    routines: [
      for (final old in routines)
        if (old.id != routine.id) old,
      routine,
    ],
  );

  ActivityData removeRoutine(String id) => ActivityData(
    records: records,
    routines: routines.where((routine) => routine.id != id).toList(),
  );

  ActivityData removeRecord(String id) {
    if (_unfinished(_record(id))) {
      throw StateError('Finish this activity before removing it.');
    }
    return ActivityData(
      records: records.where((record) => record.id != id).toList(),
      routines: routines,
    );
  }

  ActivityData _saveRecord(ActivityRecord record) => ActivityData(
    records: [
      for (final old in records)
        if (old.id != record.id) old,
      record,
    ],
    routines: routines,
  );

  ActivityRecord _record(String id) => records.firstWhere(
    (record) => record.id == id,
    orElse: () => throw StateError('This activity is unavailable.'),
  );

  void _assertCanStart() {
    if (active != null) {
      throw StateError('Finish the current activity before starting another.');
    }
  }

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {
    'version': 1,
    'records': [for (final record in records) record.toJson()],
    'routines': [for (final routine in routines) routine.toJson()],
  };
}

bool _unfinished(ActivityRecord record) =>
    record.status == ActivityStatus.running ||
    record.status == ActivityStatus.paused;

List<ActivitySpan> _closed(ActivityRecord record, DateTime now) {
  final last = record.spans.last;
  if (last.end != null) return record.spans;
  return [
    ...record.spans.take(record.spans.length - 1),
    ActivitySpan(start: last.start, end: _latest(now, last.start)),
  ];
}

void _checkOverlap(List<ActivityRecord> records) {
  final spans = [
    for (final record in records)
      for (final span in record.spans)
        if (span.end?.isAfter(span.start) ?? true) span,
  ]..sort((a, b) => a.start.compareTo(b.start));
  ActivitySpan? previous;
  for (final span in spans) {
    if (previous != null &&
        (previous.end == null || span.start.isBefore(previous.end!))) {
      throw const FormatException(
        'Actual times cannot overlap another activity.',
      );
    }
    previous = span;
  }
}

void _validateSteps(List<RoutineStep> steps) {
  if (steps.map((step) => step.id).toSet().length != steps.length) {
    throw const FormatException('Checklist steps must have unique IDs.');
  }
  for (final step in steps) {
    _label(step.id, 'Step ID');
    _label(step.title, 'Step name');
  }
}

void _label(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label is required.');
}

DateTime _latest(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

String _timestamp(DateTime value) => value.toUtc().toIso8601String();
DateTime _date(Object? value) => DateTime.parse(value as String);
DateTime? _optionalDate(Object? value) => value == null ? null : _date(value);
T? _optionalObject<T>(
  Object? value,
  T Function(Map<String, dynamic>) fromJson,
) => value == null ? null : fromJson(value as Map<String, dynamic>);
Iterable<Map<String, dynamic>> _objects(Object? value) =>
    (value as List<dynamic>).cast<Map<String, dynamic>>();

var _serial = 0;
String newActivityId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
