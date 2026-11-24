import 'dart:convert';

import 'package:flutter/services.dart' show HapticFeedback, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'gym_rest_timer.dart';
import 'ui_theme.dart';
import 'workout_metrics_ui.dart';
import 'workout_plan.dart';

part 'gym_previous_sets.dart';
part 'gym_workout_capture.dart';

enum GymProgress { pending, done, skipped }

String _progressKey(String exerciseId, [String? setId]) =>
    jsonEncode([exerciseId, ?setId]);

@immutable
class GymLogEntry {
  const GymLogEntry({
    required this.id,
    required this.title,
    required this.loggedAt,
    this.actual,
    this.exerciseId,
    this.afterExerciseId,
    this.captureText,
  });

  final String id;
  final String title;
  final DateTime loggedAt;
  final String? actual;
  final String? exerciseId;
  final String? afterExerciseId;
  final String? captureText;

  GymLogEntry._fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      title = json['title'] as String,
      loggedAt = DateTime.parse(json['loggedAt'] as String),
      actual = json['actual'] as String?,
      exerciseId = json['exerciseId'] as String?,
      afterExerciseId = json['afterExerciseId'] as String?,
      captureText = json['captureText'] as String?;

  Map<String, Object?> _toJson() => {
    'id': id,
    'title': title,
    'loggedAt': loggedAt.toUtc().toIso8601String(),
    'actual': actual,
    'exerciseId': exerciseId,
    'afterExerciseId': ?afterExerciseId,
    'captureText': ?captureText,
  };
}

@immutable
class GymSession {
  GymSession._({
    required this.planned,
    required this.startedAt,
    this.finishedAt,
    this.planId,
    this._planName,
    DateTime? restEndsAt,
    Iterable<GymLogEntry> entries = const [],
    Iterable<WorkoutExercise>? structuredExercises,
    this.plannedExercises,
    Map<String, GymProgress> progress = const {},
  }) : entries = List.unmodifiable(entries),
       _structuredExercises = structuredExercises == null
           ? null
           : List.unmodifiable(structuredExercises),
       restEndsAt = finishedAt == null ? restEndsAt?.toUtc() : null,
       _progress = Map.unmodifiable(progress);

  factory GymSession.start({WorkoutPlan? plan, DateTime? now}) => GymSession._(
    planned: plan != null,
    startedAt: now ?? DateTime.now(),
    planId: plan?.id,
    planName: plan?.name,
    structuredExercises: plan?.exercises ?? const [],
    plannedExercises: plan?.exercises,
  );

  factory GymSession.loggedCapture({
    required DateTime at,
    required GymLogEntry entry,
  }) => GymSession._(
    planned: false,
    startedAt: at,
    finishedAt: at,
    entries: [entry],
    structuredExercises: const [],
  );

  final bool planned;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final DateTime? restEndsAt;
  final List<GymLogEntry> entries;
  final String? planId;
  final String? _planName;
  final List<WorkoutExercise>? _structuredExercises;

  /// Older sessions can have an unknown original plan.
  final List<WorkoutExercise>? plannedExercises;
  final Map<String, GymProgress> _progress;

  late final _plannedById = {
    for (final exercise in plannedExercises ?? const <WorkoutExercise>[])
      exercise.id: exercise,
  };

  bool get finished => finishedAt != null;
  bool get structured => _structuredExercises != null;
  List<WorkoutExercise> get exercises => _structuredExercises ?? const [];

  WorkoutExercise? plannedExercise(String exerciseId) =>
      _plannedById[exerciseId];
  String get workoutTitle =>
      _planName ?? (planned ? 'Planned workout' : 'Freestyle');

  GymProgress progressFor(String exerciseId, {String? setId}) =>
      _progress[_progressKey(exerciseId, setId)] ?? GymProgress.pending;

  List<String> get upcomingExercises {
    if (finished) return const [];
    if (!structured) {
      final logged = entries.map((entry) => entry.exerciseId).toSet();
      return [
        if (planned)
          for (final exercise in _legacyExercises)
            if (!logged.contains(exercise.id)) exercise.title,
      ];
    }
    return [
      for (final exercise in exercises)
        if (switch (exercise.kind) {
          WorkoutExerciseKind.cardio =>
            progressFor(exercise.id) == GymProgress.pending,
          WorkoutExerciseKind.strength =>
            exercise.sets.isEmpty
                ? progressFor(exercise.id) == GymProgress.pending
                : exercise.sets.any(
                    (set) =>
                        progressFor(exercise.id, setId: set.id) ==
                        GymProgress.pending,
                  ),
        })
          exercise.name,
    ];
  }

  factory GymSession.decode(String source) =>
      GymSession._fromJson(jsonDecode(source) as Map<String, dynamic>);

  GymSession._fromJson(Map<String, dynamic> json)
    : this._(
        planned: json['planned'] as bool,
        startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
        finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
        planId: json['planId'] as String?,
        planName: json['planName'] as String?,
        restEndsAt: DateTime.tryParse(json['restEndsAt'] as String? ?? ''),
        entries: (json['entries'] as List<dynamic>).map(
          (entry) => GymLogEntry._fromJson(entry as Map<String, dynamic>),
        ),
        structuredExercises: (json['exercises'] as List<dynamic>?)?.map(
          (exercise) =>
              WorkoutExercise.fromJson(exercise as Map<String, dynamic>),
        ),
        plannedExercises: switch (json['plannedExercises']) {
          null => null,
          final List<dynamic> exercises => List.unmodifiable([
            for (final exercise in exercises)
              WorkoutExercise.fromJson(exercise as Map<String, dynamic>),
          ]),
          _ => throw const FormatException('Invalid saved workout plan.'),
        },
        progress: {
          for (final entry
              in (json['progress'] as Map<String, dynamic>? ?? {}).entries)
            entry.key: GymProgress.values.byName(entry.value as String),
        },
      );

  String encode() => jsonEncode(_toJson());

  Map<String, Object?> _toJson() => {
    'planned': planned,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'entries': entries.map((entry) => entry._toJson()).toList(),
    if (planId != null) 'planId': planId,
    if (_planName != null) 'planName': _planName,
    if (restEndsAt case final deadline?)
      'restEndsAt': deadline.toIso8601String(),
    if (_structuredExercises case final exercises?)
      'exercises': exercises.map((exercise) => exercise.toJson()).toList(),
    if (plannedExercises case final exercises?)
      'plannedExercises': exercises
          .map((exercise) => exercise.toJson())
          .toList(),
    if (_progress.isNotEmpty)
      'progress': _progress.map((key, value) => MapEntry(key, value.name)),
  };

  GymSession _copy({
    DateTime? finishedAt,
    List<GymLogEntry>? entries,
    List<WorkoutExercise>? exercises,
    Map<String, GymProgress>? progress,
    DateTime? restEndsAt,
    bool clearRest = false,
  }) => GymSession._(
    planned: planned,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    planId: planId,
    planName: _planName,
    entries: entries ?? this.entries,
    structuredExercises: exercises ?? _structuredExercises,
    plannedExercises: plannedExercises,
    progress: progress ?? _progress,
    restEndsAt: clearRest ? null : restEndsAt ?? this.restEndsAt,
  );

  GymSession _withEntries(List<GymLogEntry> entries) => _copy(entries: entries);

  GymSession withCapturedEntry(GymLogEntry entry) {
    final index = entries.lastIndexWhere(
      (existing) => !existing.loggedAt.isAfter(entry.loggedAt),
    );
    return _withEntries(entries.toList()..insert(index + 1, entry));
  }

  GymSession startRest(Duration duration, {DateTime? now}) {
    if (finished ||
        !structured ||
        duration <= Duration.zero ||
        duration > const Duration(minutes: 30)) {
      return this;
    }
    final deadline = (now ?? DateTime.now()).toUtc().add(duration);
    return _copy(restEndsAt: deadline);
  }

  GymSession clearRest() => restEndsAt == null ? this : _copy(clearRest: true);

  /// Applies a reviewed skip to pending work in this session snapshot.
  GymSession withSkippedExercises(Iterable<String> exerciseIds) {
    if (finished || !structured) return this;
    final selected = exerciseIds.toSet();
    final progress = {..._progress};
    var changed = false;
    for (final exercise in exercises) {
      if (!selected.contains(exercise.id)) continue;
      final Iterable<String?> sets =
          exercise.kind == WorkoutExerciseKind.strength &&
              exercise.sets.isNotEmpty
          ? exercise.sets.map((set) => set.id)
          : const <String?>[null];
      for (final set in sets) {
        if (progressFor(exercise.id, setId: set) != GymProgress.pending) {
          continue;
        }
        progress[_progressKey(exercise.id, set)] = GymProgress.skipped;
        changed = true;
      }
    }
    return changed ? _copy(progress: progress) : this;
  }

  GymSession _finish(DateTime date) => _copy(finishedAt: date);

  GymSession _withExercises(List<WorkoutExercise> exercises) {
    final keys = {
      for (final exercise in exercises) ...[
        _progressKey(exercise.id),
        for (final set in exercise.sets) _progressKey(exercise.id, set.id),
      ],
    };
    return _copy(
      exercises: exercises,
      progress: {
        for (final entry in _progress.entries)
          if (keys.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  GymSession _withProgress(
    String exerciseId,
    String? setId,
    GymProgress value,
  ) {
    final key = _progressKey(exerciseId, setId);
    final updated = {..._progress};
    if (updated[key] == value) {
      updated.remove(key);
    } else {
      updated[key] = value;
    }
    return _copy(progress: updated);
  }
}

class GymSessionPage extends StatefulWidget {
  const GymSessionPage({
    required this.session,
    required this.onChanged,
    this.previousSessions = const [],
    this.buildCaptureControl,
    super.key,
  });

  final GymSession? session;
  final ValueChanged<GymSession?> onChanged;
  final List<GymSession> previousSessions;

  /// Builds a compact capture control for a live workout. Report a reviewed
  /// session through the callback after the caller has persisted it.
  final Widget Function(ValueChanged<GymSession> onReviewed)?
  buildCaptureControl;

  @override
  State<GymSessionPage> createState() => _GymSessionPageState();
}

typedef _Exercise = ({String id, String title, String target});

const _legacyExercises = <_Exercise>[
  (id: 'treadmill', title: 'Treadmill', target: '0.5 km · 5 min · 2% incline'),
  (id: 'bench', title: 'Bench press', target: '50 kg × 8, 8, 8'),
];

enum _Metric {
  distance('Distance', 'km'),
  incline('Incline', '%'),
  minutes('Duration', 'min', integer: true),
  weight('Weight', 'kg'),
  reps('Reps', 'reps', integer: true);

  const _Metric(this.label, this.unit, {this.integer = false});

  final String label;
  final String unit;
  final bool integer;
}

typedef _MetricTarget = ({
  String exerciseId,
  String? setId,
  _Metric? metric,
  WorkoutMetric? custom,
  WorkoutWeightUnit? weightUnit,
  String label,
  String unit,
});

class _GymSessionPageState extends State<GymSessionPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  late GymSession? _session = widget.session;
  late Map<(String, String), PreviousWorkoutSet> _previousSets =
      _readPreviousSets();
  GymLogEntry? _editingEntry;
  _Exercise? _editingExercise;
  _MetricTarget? _editingMetric;
  String? _metricInitial;
  String _extraDraft = '';
  String? _error;
  WorkoutWeightUnit _weightUnit = WorkoutWeightUnit.kilograms;
  bool _selectedWeightUnit = false;

  bool get _editing =>
      _editingEntry != null ||
      _editingExercise != null ||
      _editingMetric != null;
  bool get _active => _session != null && !_session!.finished;

  @override
  void initState() {
    super.initState();
    _loadWeightUnit();
  }

  Future<void> _loadWeightUnit() async {
    final unit = await readWorkoutWeightUnit();
    if (mounted && !_selectedWeightUnit && unit != _weightUnit) {
      setState(() => _weightUnit = unit);
    }
  }

  void _changeWeightUnit(WorkoutWeightUnit unit) {
    if (unit == _weightUnit) return;
    setState(() {
      _selectedWeightUnit = true;
      _weightUnit = unit;
    });
    rememberWorkoutWeightUnit(unit);
  }

  @override
  void didUpdateWidget(covariant GymSessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) _session = widget.session;
    if (widget.session != oldWidget.session ||
        widget.previousSessions != oldWidget.previousSessions) {
      _previousSets = _readPreviousSets();
    }
  }

  Map<(String, String), PreviousWorkoutSet> _readPreviousSets() {
    final session = _session;
    return session == null ||
            session.finished ||
            widget.previousSessions.isEmpty
        ? const {}
        : previousWorkoutSets(session, widget.previousSessions);
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _update(GymSession session, {bool notify = true}) {
    setState(() {
      final shapeChanged =
          _session?.exercises.length != session.exercises.length;
      _session = session;
      if (shapeChanged) _previousSets = _readPreviousSets();
    });
    if (notify) widget.onChanged(session);
  }

  void _reviewedCapture(GymSession reviewed) {
    final current = _session;
    if (!mounted ||
        current == null ||
        current.finished ||
        reviewed.finished ||
        !current.startedAt.isAtSameMomentAs(reviewed.startedAt) ||
        current.planId != reviewed.planId ||
        current.planned != reviewed.planned) {
      return;
    }
    _update(reviewed, notify: false);
  }

  void _begin(bool planned) {
    _update(
      planned
          ? GymSession._(planned: true, startedAt: DateTime.now())
          : GymSession.start(),
    );
  }

  Future<void> _finish() async {
    final session = _session!;
    final initialEdit =
        _metricInitial ??
        _editingEntry?.actual ??
        _editingEntry?.title ??
        _editingExercise?.target;
    final pending = _input.text.trim();
    if (_extraDraft.isNotEmpty ||
        (pending.isNotEmpty && pending != initialEdit)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard draft and finish?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep logging'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Finish'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    _focus.unfocus();
    _cancelEdit();
    _input.clear();
    _update(session._finish(DateTime.now()));
  }

  void _logExercise(_Exercise exercise, String actual) {
    final existing = _session!.entries
        .where((entry) => entry.exerciseId == exercise.id)
        .firstOrNull;
    if (existing != null) {
      if (existing.actual != actual) _replaceEntry(existing, actual);
      return;
    }
    _append(title: exercise.title, actual: actual, exerciseId: exercise.id);
  }

  void _append({required String title, String? actual, String? exerciseId}) {
    final session = _session!;
    final now = DateTime.now();
    final entry = GymLogEntry(
      id: '${now.microsecondsSinceEpoch}-${session.entries.length}',
      title: title,
      loggedAt: now,
      actual: actual,
      exerciseId: exerciseId,
    );
    _update(session._withEntries([...session.entries, entry]));
  }

  void _edit({GymLogEntry? entry, _Exercise? exercise}) {
    final value = entry?.actual ?? entry?.title ?? exercise!.target;
    setState(() {
      if (!_editing) _extraDraft = _input.text;
      _editingEntry = entry;
      _editingExercise = exercise;
      _editingMetric = null;
      _metricInitial = null;
      _error = null;
      _input.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    });
    _focus.requestFocus();
  }

  void _editMetric(_MetricTarget target, String value) {
    setState(() {
      if (!_editing) _extraDraft = _input.text;
      _editingEntry = null;
      _editingExercise = null;
      _editingMetric = target;
      _metricInitial = value;
      _error = null;
      _input.value = TextEditingValue(
        text: value,
        selection: TextSelection(baseOffset: 0, extentOffset: value.length),
      );
    });
    if (target.metric == null || MediaQuery.sizeOf(context).width >= 720) {
      _focus.requestFocus();
    }
  }

  void _stepMetric(_MetricTarget target, int direction) {
    final value = double.tryParse(_input.text.trim().replaceAll(',', '.'));
    final step = switch (target.metric) {
      _Metric.distance => .1,
      _Metric.incline => .5,
      _Metric.weight =>
        target.weightUnit == WorkoutWeightUnit.pounds ? 1.0 : .5,
      _Metric.minutes || _Metric.reps => 1.0,
      null => 0.0,
    };
    if (step == 0 || value == null || !value.isFinite) return;
    final next = value + direction * step;
    final amount = target.metric != _Metric.incline && next < 0 ? 0.0 : next;
    final text = _number(double.parse(amount.toStringAsFixed(2)));
    if (text == _input.text) return;
    HapticFeedback.selectionClick();
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (_error != null) setState(() => _error = null);
  }

  void _cancelEdit() {
    setState(() {
      _editingEntry = null;
      _editingExercise = null;
      _editingMetric = null;
      _metricInitial = null;
      _error = null;
      _input.value = TextEditingValue(
        text: _extraDraft,
        selection: TextSelection.collapsed(offset: _extraDraft.length),
      );
      _extraDraft = '';
    });
  }

  void _closeEditor() {
    _cancelEdit();
    _focus.unfocus();
  }

  void _submit() {
    if (!_active) return;
    final value = _input.text.trim();
    if (value.isEmpty) {
      setState(() => _error = _editing ? 'Enter a result.' : 'Enter an entry.');
      _focus.requestFocus();
      return;
    }
    if (_editingMetric case final target?) {
      if (!_saveMetric(target, value)) return;
    } else if (_editingEntry case final entry?) {
      _replaceEntry(entry, value);
    } else if (_editingExercise case final exercise?) {
      _logExercise(exercise, value);
    } else {
      _append(title: value);
    }
    if (_editing) {
      _closeEditor();
    } else {
      _input.clear();
    }
  }

  String _number(num value) =>
      value == value.toInt() ? value.toInt().toString() : value.toString();

  bool _saveMetric(_MetricTarget target, String text) {
    if (text == _metricInitial) return true;
    final metric = target.metric;
    final integer = metric?.integer ?? false;
    final value = integer
        ? int.tryParse(text)
        : double.tryParse(text.replaceAll(',', '.'));
    if (value == null ||
        !value.isFinite ||
        (metric != null && metric != _Metric.incline && value < 0)) {
      setState(
        () => _error = integer ? 'Enter a whole number.' : 'Enter a number.',
      );
      _focus.requestFocus();
      return false;
    }
    if (target.custom case final custom?) {
      if (!WorkoutMetric.isValidValue(value)) {
        setState(() => _error = 'Enter a number from −1,000,000 to 1,000,000.');
        _focus.requestFocus();
        return false;
      }
      _changeCustomMetrics(
        target.exerciseId,
        target.setId,
        (metrics) => [
          for (final item in metrics)
            item.id == custom.id
                ? item.copyWith(value: value.toDouble())
                : item,
        ],
      );
      return true;
    }
    final exercise = _session!.exercises
        .where((exercise) => exercise.id == target.exerciseId)
        .firstOrNull;
    if (exercise == null) return true;
    final changed = switch (metric!) {
      _Metric.distance => exercise.copyWith(distanceKm: value.toDouble()),
      _Metric.incline => exercise.copyWith(inclinePercent: value.toDouble()),
      _Metric.minutes => exercise.copyWith(minutes: value.toInt()),
      _Metric.weight || _Metric.reps => exercise.copyWith(
        sets: [
          for (final set in exercise.sets)
            if (set.id != target.setId)
              set
            else if (metric == _Metric.weight)
              set.copyWith(
                weightKg: target.weightUnit!.toKilograms(value.toDouble()),
              )
            else
              set.copyWith(reps: value.toInt()),
        ],
      ),
    };
    _replaceExercise(changed);
    return true;
  }

  void _changeCustomMetrics(
    String exerciseId,
    String? setId,
    List<WorkoutMetric> Function(List<WorkoutMetric>) edit,
  ) {
    final exercise = _session!.exercises
        .where((item) => item.id == exerciseId)
        .firstOrNull;
    if (exercise == null) return;
    if (setId == null) {
      _replaceExercise(exercise.copyWith(metrics: edit(exercise.metrics)));
      return;
    }
    if (!exercise.sets.any((set) => set.id == setId)) return;
    _replaceExercise(
      exercise.copyWith(
        sets: [
          for (final set in exercise.sets)
            set.id == setId ? set.copyWith(metrics: edit(set.metrics)) : set,
        ],
      ),
    );
  }

  Future<void> _editCustomMetric(
    WorkoutExercise exercise, {
    WorkoutSet? set,
    WorkoutMetric? metric,
  }) async {
    _focus.unfocus();
    final edit = await showWorkoutMetricEditor(context, metric: metric);
    if (!mounted || edit == null || !_active) return;
    if (edit.removed) {
      final logged = set == null
          ? _hasExerciseResult(_session!, exercise)
          : _session!.progressFor(exercise.id, setId: set.id) !=
                GymProgress.pending;
      if (logged && !await _confirmRemoval(edit.metric.label)) return;
      if (!mounted || !_active) return;
    }
    final pending = _editingMetric;
    if (pending?.exerciseId == exercise.id &&
        pending?.setId == set?.id &&
        pending?.custom?.id == edit.metric.id) {
      _cancelEdit();
    }
    _changeCustomMetrics(
      exercise.id,
      set?.id,
      (metrics) => applyWorkoutMetricEdit(metrics, edit),
    );
  }

  void _replaceExercise(WorkoutExercise changed) {
    final session = _session!;
    _update(
      session._withExercises([
        for (final exercise in session.exercises)
          exercise.id == changed.id ? changed : exercise,
      ]),
    );
  }

  void _moveStep(String exerciseId, String? setId, int offset) {
    if (!_active) return;
    final session = _session!;
    final exercises = session.exercises.toList();
    final exerciseIndex = exercises.indexWhere((item) => item.id == exerciseId);
    if (exerciseIndex < 0) return;
    if (setId == null) {
      final destination = exerciseIndex + offset;
      if (destination < 0 || destination >= exercises.length) return;
      exercises.insert(destination, exercises.removeAt(exerciseIndex));
    } else {
      final exercise = exercises[exerciseIndex];
      final sets = exercise.sets.toList();
      final index = sets.indexWhere((item) => item.id == setId);
      final destination = index + offset;
      if (index < 0 || destination < 0 || destination >= sets.length) return;
      sets.insert(destination, sets.removeAt(index));
      exercises[exerciseIndex] = exercise.copyWith(sets: sets);
    }
    HapticFeedback.selectionClick();
    _update(session._withExercises(exercises));
  }

  String _metricHeading(_MetricTarget target) {
    final exercise = _session?.exercises
        .where((item) => item.id == target.exerciseId)
        .firstOrNull;
    if (exercise == null) return target.label;
    final index = exercise.sets.indexWhere((item) => item.id == target.setId);
    return '${target.label} · ${exercise.name}${index < 0 ? '' : ', set ${index + 1}'}';
  }

  void _addSet(WorkoutExercise exercise) {
    final previous = exercise.sets.lastOrNull;
    _replaceExercise(
      exercise.copyWith(
        sets: [
          ...exercise.sets,
          previous?.copyWith(id: newWorkoutId()) ??
              WorkoutSet(id: newWorkoutId()),
        ],
      ),
    );
  }

  Future<void> _addExercise() async {
    final result = await showDialog<WorkoutExercise>(
      context: context,
      builder: (_) => const _AddSessionExercise(),
    );
    if (!mounted || result == null || !_active) return;
    final session = _session!;
    _update(session._withExercises([...session.exercises, result]));
  }

  Future<bool> _confirmRemoval(String label) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $label?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return mounted && result == true;
  }

  Future<void> _removeSet(
    WorkoutExercise exercise,
    WorkoutSet set,
    int index,
  ) async {
    final progress = _session!.progressFor(exercise.id, setId: set.id);
    if (progress != GymProgress.pending &&
        !await _confirmRemoval('set ${index + 1}')) {
      return;
    }
    if (!_active) return;
    if (_editingMetric?.setId == set.id) _cancelEdit();
    final current = _session!.exercises
        .where((item) => item.id == exercise.id)
        .firstOrNull;
    if (current == null) return;
    _replaceExercise(
      current.copyWith(
        sets: current.sets.where((item) => item.id != set.id).toList(),
      ),
    );
  }

  Future<void> _removeExercise(WorkoutExercise exercise) async {
    final session = _session!;
    if (_hasExerciseResult(session, exercise) &&
        !await _confirmRemoval(exercise.name)) {
      return;
    }
    if (!_active) return;
    if (_editingMetric?.exerciseId == exercise.id) _cancelEdit();
    final current = _session!;
    _update(
      current._withExercises(
        current.exercises.where((item) => item.id != exercise.id).toList(),
      ),
    );
  }

  bool _hasExerciseResult(GymSession session, WorkoutExercise exercise) =>
      session.progressFor(exercise.id) != GymProgress.pending ||
      exercise.sets.any(
        (set) =>
            session.progressFor(exercise.id, setId: set.id) !=
            GymProgress.pending,
      );

  void _replaceEntry(GymLogEntry entry, String value) {
    final session = _session!;
    final updated = GymLogEntry(
      id: entry.id,
      title: entry.exerciseId == null ? value : entry.title,
      loggedAt: entry.loggedAt,
      actual: entry.exerciseId == null ? null : value,
      exerciseId: entry.exerciseId,
      afterExerciseId: entry.afterExerciseId,
      captureText: entry.captureText,
    );
    _update(
      session._withEntries([
        for (final existing in session.entries)
          existing.id == entry.id ? updated : existing,
      ]),
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    ),
  );

  Widget _choice({
    required String title,
    required String detail,
    required IconData icon,
    required bool planned,
  }) {
    return Material(
      color: raisedPaper,
      shape: RoundedRectangleBorder(
        borderRadius: contentSurfaceRadius,
        side: const BorderSide(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        leading: Icon(icon, color: accent),
        title: Text(title, style: contentTitleStyle),
        subtitle: Text(detail, style: contentMetadataStyle),
        trailing: const Icon(Icons.chevron_right_rounded, color: muted),
        onTap: () => _begin(planned),
      ),
    );
  }

  Widget _planRow(_Exercise exercise) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 6, 11),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 285 ||
              MediaQuery.textScalerOf(context).scale(14) > 18;
          final detail = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                exercise.title,
                style: const TextStyle(
                  color: ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(exercise.target, style: const TextStyle(color: muted)),
            ],
          );
          final actions = Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: 'Log ${exercise.title} as planned',
                child: TextButton(
                  onPressed: () => _logExercise(exercise, exercise.target),
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    backgroundColor: softAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(44, 44),
                  ),
                  child: const Text('Log as planned'),
                ),
              ),
              IconButton(
                tooltip: 'Enter actual for ${exercise.title}',
                onPressed: () => _edit(exercise: exercise),
                icon: const Icon(Icons.edit_outlined, color: muted, size: 18),
              ),
            ],
          );
          return compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [detail, const SizedBox(height: 6), actions],
                )
              : Row(
                  children: [
                    Expanded(child: detail),
                    const SizedBox(width: 6),
                    actions,
                  ],
                );
        },
      ),
    );
  }

  Widget _plan(List<_Exercise> pending) {
    return Material(
      color: raisedPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: line),
      ),
      child: Column(
        children: [
          for (var index = 0; index < pending.length; index++) ...[
            if (index != 0) const Divider(height: 1),
            _planRow(pending[index]),
          ],
        ],
      ),
    );
  }

  Widget _metric(
    WorkoutExercise exercise,
    _Metric metric,
    num value, {
    WorkoutSet? set,
    int? index,
  }) {
    final weightUnit = metric == _Metric.weight ? _weightUnit : null;
    final numeral = weightUnit == null
        ? _number(value)
        : workoutWeightText(value.toDouble(), weightUnit);
    final unit = weightUnit?.symbol ?? metric.unit;
    final display = metric == _Metric.incline ? '$numeral%' : '$numeral $unit';
    final target = index == null
        ? exercise.name
        : '${exercise.name}, set ${index + 1}';
    return _metricButton(
      display,
      tooltip: 'Edit ${metric.label.toLowerCase()} for $target',
      edit: () => _editMetric((
        exerciseId: exercise.id,
        setId: set?.id,
        metric: metric,
        custom: null,
        weightUnit: weightUnit,
        label: weightUnit == null
            ? metric.label
            : '${metric.label} (${weightUnit.symbol})',
        unit: unit,
      ), numeral),
    );
  }

  Widget? _plannedValues(WorkoutExercise exercise, [WorkoutSet? set]) {
    final baseline = _session!.plannedExercise(exercise.id);
    if (baseline == null || baseline.kind != exercise.kind) return null;
    final targetSet = set == null
        ? null
        : baseline.sets.where((item) => item.id == set.id).firstOrNull;
    if (set != null && targetSet == null) return null;
    final targets = set == null ? baseline.metrics : targetSet!.metrics;
    final current = {
      for (final item in set?.metrics ?? exercise.metrics) item.id: item,
    };
    final difference = [
      if (set == null && exercise.kind == WorkoutExerciseKind.cardio) ...[
        if (baseline.distanceKm != exercise.distanceKm)
          '${_number(baseline.distanceKm)} km',
        if (baseline.inclinePercent != exercise.inclinePercent)
          '${_number(baseline.inclinePercent)}% incline',
        if (baseline.minutes != exercise.minutes) '${baseline.minutes} min',
      ],
      if (set != null && targetSet != null) ...[
        if (targetSet.weightKg != set.weightKg)
          '${workoutWeightText(targetSet.weightKg, _weightUnit)} ${_weightUnit.symbol}',
        if (targetSet.reps != set.reps) '${targetSet.reps} reps',
      ],
      for (final metric in targets)
        if (current[metric.id]?.value != metric.value ||
            current[metric.id]?.unit != metric.unit ||
            current[metric.id]?.label != metric.label)
          '${metric.label} ${workoutMetricValueText(metric)}',
    ];
    if (difference.isEmpty) return null;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 7, 5),
      child: Text(
        'Planned · ${difference.join(' · ')}',
        style: contentMetadataStyle.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget? _lastSet(WorkoutExercise exercise, WorkoutSet set) {
    final previous = _previousSets[(exercise.id, set.id)];
    if (!_active || previous == null) return null;
    final weight = workoutWeightText(previous.weightKg, _weightUnit);
    if (previous.reps == set.reps &&
        weight == workoutWeightText(set.weightKg, _weightUnit)) {
      return null;
    }
    final labels = MaterialLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 7, 5),
      child: Tooltip(
        message: labels.formatFullDate(previous.sessionDate.toLocal()),
        child: Text(
          'Last workout · $weight ${_weightUnit.symbol} × ${previous.reps}',
          style: contentMetadataStyle,
        ),
      ),
    );
  }

  Widget _customMetricValues(
    WorkoutExercise exercise, {
    WorkoutSet? set,
    int? index,
  }) {
    final target = index == null
        ? exercise.name
        : '${exercise.name}, set ${index + 1}';
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4, top: 3, bottom: 3),
      child: Wrap(
        spacing: 5,
        runSpacing: 4,
        children: [
          for (final metric in set?.metrics ?? exercise.metrics)
            _metricButton(
              '${metric.label} · ${workoutMetricValueText(metric)}',
              tooltip: 'Edit ${metric.label} for $target',
              edit: () => _editMetric((
                exerciseId: exercise.id,
                setId: set?.id,
                metric: null,
                custom: metric,
                weightUnit: null,
                label: metric.label,
                unit: metric.unit,
              ), _number(metric.value)),
              editDefinition: () =>
                  _editCustomMetric(exercise, set: set, metric: metric),
            ),
        ],
      ),
    );
  }

  Widget _metricButton(
    String display, {
    required String tooltip,
    required VoidCallback edit,
    VoidCallback? editDefinition,
  }) {
    if (!_active) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          display,
          style: contentMetadataStyle.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(45, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          foregroundColor: ink,
          backgroundColor: paper,
          side: const BorderSide(color: line),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        onPressed: edit,
        onLongPress: editDefinition,
        child: Semantics(
          value: display,
          excludeSemantics: true,
          child: Text(display, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  List<PopupMenuEntry<VoidCallback>> _metricOptions(
    WorkoutExercise exercise, {
    WorkoutSet? set,
    required int index,
    required int count,
    required VoidCallback remove,
  }) {
    final metrics = set?.metrics ?? exercise.metrics;
    final step = set == null ? 'exercise' : 'set';
    return [
      if (index > 0)
        PopupMenuItem(
          value: () => _moveStep(exercise.id, set?.id, -1),
          child: Text('Move $step up'),
        ),
      if (index + 1 < count)
        PopupMenuItem(
          value: () => _moveStep(exercise.id, set?.id, 1),
          child: Text('Move $step down'),
        ),
      if (count > 1) const PopupMenuDivider(),
      if (metrics.length < WorkoutMetric.maxPerItem)
        PopupMenuItem(
          value: () => _editCustomMetric(exercise, set: set),
          child: const Text('Add metric'),
        ),
      for (final metric in metrics)
        PopupMenuItem(
          value: () => _editCustomMetric(exercise, set: set, metric: metric),
          child: Text(
            'Edit ${metric.label}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: remove,
        child: Text(set == null ? 'Remove exercise' : 'Remove set'),
      ),
    ];
  }

  Widget _progressControls(String label, String exerciseId, [String? setId]) {
    final session = _session!;
    final progress = session.progressFor(exerciseId, setId: setId);
    const doneColor = Color(0xff365f43);
    const skipColor = Color(0xff8f4438);
    if (!_active) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Text(
          switch (progress) {
            GymProgress.pending => 'Pending',
            GymProgress.done => 'Done',
            GymProgress.skipped => 'Skipped',
          },
          style: contentMetadataStyle.copyWith(
            color: switch (progress) {
              GymProgress.pending => muted,
              GymProgress.done => doneColor,
              GymProgress.skipped => skipColor,
            },
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (action, title, icon, color) in [
          (
            GymProgress.done,
            'Mark $label done',
            Icons.check_rounded,
            doneColor,
          ),
          (GymProgress.skipped, 'Skip $label', Icons.close_rounded, skipColor),
        ])
          IconButton(
            isSelected: progress == action,
            tooltip: progress == action
                ? 'Clear ${action.name} for $label'
                : title,
            onPressed: () {
              HapticFeedback.selectionClick();
              _update(_session!._withProgress(exerciseId, setId, action));
            },
            style: IconButton.styleFrom(
              minimumSize: const Size.square(44),
              foregroundColor: progress == action || action == GymProgress.done
                  ? color
                  : muted,
              backgroundColor: progress != action
                  ? null
                  : action == GymProgress.done
                  ? softAccent
                  : const Color(0xfff4e4df),
              shape: contentControlShape,
            ),
            icon: Icon(icon, size: 19),
          ),
      ],
    );
  }

  Widget _metricLine({
    Widget? leading,
    required List<Widget> values,
    required Widget progress,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final valuesRow = Wrap(
          spacing: 5,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: values,
        );
        if (constraints.maxWidth < 246 ||
            MediaQuery.textScalerOf(context).scale(14) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ?leading,
                  Expanded(child: valuesRow),
                ],
              ),
              Align(alignment: AlignmentDirectional.centerEnd, child: progress),
            ],
          );
        }
        return Row(
          children: [
            ?leading,
            Expanded(child: valuesRow),
            progress,
          ],
        );
      },
    );
  }

  Widget _structuredExercise(WorkoutExercise exercise, int index) {
    final cardio = exercise.kind == WorkoutExerciseKind.cardio;
    return Padding(
      key: ValueKey(exercise.id),
      padding: const EdgeInsets.only(bottom: 13),
      child: Material(
        color: raisedPaper,
        surfaceTintColor: Colors.transparent,
        elevation: .5,
        shadowColor: const Color(0x24373b2f),
        shape: const RoundedRectangleBorder(
          borderRadius: contentSurfaceRadius,
          side: BorderSide(color: line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 3, 5, 3),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          exercise.name,
                          style: contentTitleStyle.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (_active)
                      PopupMenuButton<VoidCallback>(
                        tooltip: 'Options for ${exercise.name}',
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          color: muted,
                          size: 20,
                        ),
                        onSelected: (action) => action(),
                        itemBuilder: (_) => _metricOptions(
                          exercise,
                          index: index,
                          count: _session!.exercises.length,
                          remove: () => _removeExercise(exercise),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(indent: 13, endIndent: 13),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 6, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (cardio)
                    _metricLine(
                      values: [
                        _metric(
                          exercise,
                          _Metric.distance,
                          exercise.distanceKm,
                        ),
                        _metric(
                          exercise,
                          _Metric.incline,
                          exercise.inclinePercent,
                        ),
                        _metric(exercise, _Metric.minutes, exercise.minutes),
                      ],
                      progress: _progressControls(exercise.name, exercise.id),
                    ),
                  if (exercise.metrics.isNotEmpty)
                    _customMetricValues(exercise),
                  ?_plannedValues(exercise),
                  if (!cardio) ...[
                    if (exercise.sets.isEmpty)
                      _progressControls(exercise.name, exercise.id),
                    for (final (index, _) in exercise.sets.indexed) ...[
                      if (index > 0) const Divider(indent: 3, endIndent: 7),
                      _setLine(exercise, index),
                    ],
                    if (_active)
                      TextButton.icon(
                        onPressed: () => _addSet(exercise),
                        icon: const Icon(Icons.add_rounded, size: 17),
                        label: const Text('Add set'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsetsDirectional.only(
                            start: 4,
                            end: 12,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setLine(WorkoutExercise exercise, int index) {
    final number = index + 1;
    final set = exercise.sets[index];
    final setLabel = _active
        ? PopupMenuButton<VoidCallback>(
            tooltip: 'Set $number options for ${exercise.name}',
            padding: EdgeInsets.zero,
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Set $number',
                  style: contentMetadataStyle.copyWith(
                    color: ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 3),
                const Icon(Icons.more_horiz_rounded, size: 13, color: muted),
              ],
            ),
            onSelected: (action) => action(),
            itemBuilder: (_) => _metricOptions(
              exercise,
              set: set,
              index: index,
              count: exercise.sets.length,
              remove: () => _removeSet(exercise, set, index),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('Set $number', style: contentMetadataStyle),
          );
    return Padding(
      key: ValueKey(set.id),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricLine(
            leading: setLabel,
            values: [
              _metric(
                exercise,
                _Metric.weight,
                set.weightKg,
                set: set,
                index: index,
              ),
              _metric(exercise, _Metric.reps, set.reps, set: set, index: index),
            ],
            progress: _progressControls(
              '${exercise.name} set $number',
              exercise.id,
              set.id,
            ),
          ),
          if (set.metrics.isNotEmpty)
            _customMetricValues(exercise, set: set, index: index),
          ?_plannedValues(exercise, set),
          ?_lastSet(exercise, set),
        ],
      ),
    );
  }

  Widget _entryRow(GymLogEntry entry, {required bool editable}) {
    final after = entry.afterExerciseId;
    final reference = after == null
        ? null
        : _session?.exercises.where((item) => item.id == after).firstOrNull ??
              _session?.plannedExercise(after);
    final detail = [
      if (reference != null) 'After ${reference.name}',
      ?entry.actual,
    ];
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 13, end: 7),
      title: Text(entry.title, style: contentTitleStyle),
      subtitle: detail.isEmpty
          ? null
          : Text(detail.join(' · '), style: contentMetadataStyle),
      trailing: editable
          ? IconButton(
              tooltip: 'Edit ${entry.title}',
              onPressed: () => _edit(entry: entry),
              icon: const Icon(Icons.edit_outlined, color: muted, size: 18),
            )
          : null,
    );
  }

  Widget _entries(GymSession session, {required bool editable}) {
    if (session.entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 7),
        child: Text('No entries yet.', style: contentMetadataStyle),
      );
    }
    return Material(
      color: raisedPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: contentSurfaceRadius,
        side: BorderSide(color: line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (index, entry) in session.entries.indexed) ...[
            if (index > 0) const Divider(indent: 13, endIndent: 13),
            _entryRow(entry, editable: editable),
          ],
        ],
      ),
    );
  }

  Widget _inputBar(double side) {
    final metric = _editingMetric;
    final exercise =
        _editingExercise?.title ??
        (_editingEntry?.exerciseId == null ? null : _editingEntry?.title);
    const radius = BorderRadius.all(Radius.circular(12));
    final addSteppers =
        metric?.metric != null && MediaQuery.sizeOf(context).width < 720;
    final showRest = !_editing && (_session?.exercises.isNotEmpty ?? false);
    final capture = _active && !_editing
        ? widget.buildCaptureControl?.call(_reviewedCapture)
        : null;
    final separateControls =
        capture != null &&
        showRest &&
        MediaQuery.sizeOf(context).width < 360 &&
        MediaQuery.textScalerOf(context).scale(14) >= 20;
    final controls = showRest || capture != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showRest)
                GymRestTimer(
                  endsAt: _session?.restEndsAt,
                  onStart: (duration) => _update(_session!.startRest(duration)),
                  onClear: () => _update(_session!.clearRest()),
                ),
              if (showRest && capture != null) const SizedBox(width: 8),
              if (capture != null)
                SizedBox.square(dimension: 48, child: capture),
            ],
          )
        : null;
    final bar = DecoratedBox(
      decoration: const BoxDecoration(
        color: paper,
        border: Border(top: BorderSide(color: line)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 8, side, 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_editing)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      metric == null
                          ? (exercise == null
                                ? 'Edit entry'
                                : 'Actual · $exercise')
                          : _metricHeading(metric),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: contentTitleStyle,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel edit',
                    onPressed: _closeEditor,
                    icon: const Icon(
                      Icons.close_rounded,
                      color: muted,
                      size: 18,
                    ),
                  ),
                ],
              ),
            if (separateControls)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: controls,
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: metric == null
                        ? TextInputType.text
                        : TextInputType.numberWithOptions(
                            decimal: !(metric.metric?.integer ?? false),
                            signed:
                                metric.custom != null ||
                                metric.metric == _Metric.incline,
                          ),
                    textInputAction: TextInputAction.done,
                    onEditingComplete: () {},
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    style: contentTitleStyle.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: metric == null
                          ? _editing
                                ? 'Enter actual'
                                : _session?.structured == true
                                ? 'Add a note or extra'
                                : 'Add an exercise or note'
                          : metric.unit,
                      errorText: _error,
                      errorMaxLines: 3,
                      hintStyle: contentMetadataStyle.copyWith(fontSize: 14),
                      filled: true,
                      fillColor: raisedPaper,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                      ),
                      border: OutlineInputBorder(borderRadius: radius),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: radius,
                        borderSide: const BorderSide(color: line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: radius,
                        borderSide: const BorderSide(color: accent, width: 1.5),
                      ),
                      prefixIcon: addSteppers
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final (direction, label, icon) in [
                                  (-1, 'Decrease', Icons.remove_rounded),
                                  (1, 'Increase', Icons.add_rounded),
                                ])
                                  IconButton(
                                    tooltip:
                                        '$label ${metric!.metric!.label.toLowerCase()}',
                                    onPressed: () =>
                                        _stepMetric(metric, direction),
                                    style: IconButton.styleFrom(
                                      minimumSize: const Size.square(44),
                                      foregroundColor: ink,
                                    ),
                                    icon: Icon(icon, size: 18),
                                  ),
                              ],
                            )
                          : null,
                      suffixIcon: Padding(
                        padding: const EdgeInsets.all(4),
                        child: IconButton.filled(
                          tooltip: metric != null
                              ? 'Save value'
                              : _editing
                              ? 'Save entry'
                              : 'Log entry',
                          onPressed: _submit,
                          icon: Icon(
                            _editing
                                ? Icons.check_rounded
                                : Icons.arrow_upward_rounded,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!separateControls && controls != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 8, top: 2),
                    child: controls,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        if (_editing)
          const SingleActivator(LogicalKeyboardKey.escape): _closeEditor,
      },
      child: bar,
    );
  }

  Widget _sessionList(GymSession? session, double side) {
    final exercises = session?.exercises ?? const <WorkoutExercise>[];
    final heading = session?.finished == true ? 1 : 0;
    var pending = const <_Exercise>[];
    if (session != null && !session.structured && session.planned && _active) {
      final logged = session.entries.map((entry) => entry.exerciseId).toSet();
      pending = _legacyExercises
          .where((exercise) => !logged.contains(exercise.id))
          .toList();
    }
    final trailing = <Widget>[
      if (session != null) ...[
        if (session.structured) ...[
          if (_active)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addExercise,
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('Add exercise'),
              ),
            ),
          if (session.entries.isNotEmpty) ...[
            const SizedBox(height: 15),
            _heading('Session log'),
            Builder(builder: (_) => _entries(session, editable: _active)),
          ],
        ] else if (session.finished) ...[
          Builder(builder: (_) => _entries(session, editable: false)),
          const SizedBox(height: 24),
        ] else ...[
          if (pending.isNotEmpty) ...[
            _heading('Plan'),
            _plan(pending),
            const SizedBox(height: 23),
          ],
          _heading('Session log'),
          Builder(builder: (_) => _entries(session, editable: true)),
        ],
      ],
      if (!_active && session?.structured != true) ...[
        if (session != null) _heading('Start another session'),
        _choice(
          title: 'Planned session',
          detail: 'Treadmill and bench press',
          icon: Icons.checklist_rounded,
          planned: true,
        ),
        const SizedBox(height: 8),
        _choice(
          title: 'Freestyle',
          detail: 'Log exercises as you go',
          icon: Icons.notes_rounded,
          planned: false,
        ),
      ],
    ];
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(side, 12, side, 22),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: heading + exercises.length + trailing.length,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = exercises.indexWhere(
          (exercise) => exercise.id == key.value,
        );
        return index < 0 ? null : heading + index;
      },
      itemBuilder: (context, index) {
        if (index < heading) return _heading('Session complete');
        final exerciseIndex = index - heading;
        if (exerciseIndex < exercises.length) {
          return _structuredExercise(exercises[exerciseIndex], exerciseIndex);
        }
        return trailing[exerciseIndex - exercises.length];
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 360 ? 16.0 : (width < 600 ? 20.0 : 30.0);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          session?.structured == true ? session!.workoutTitle : 'Gym session',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        titleTextStyle: contentTitleStyle.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        titleSpacing: 2,
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        actions: [
          if (session?.exercises.any(
                (exercise) => exercise.kind == WorkoutExerciseKind.strength,
              ) ??
              false)
            WorkoutWeightUnitMenu(
              unit: _weightUnit,
              onSelected: _changeWeightUnit,
            ),
          if (_active)
            Padding(
              padding: EdgeInsetsDirectional.only(end: side - 6),
              child: TextButton(
                onPressed: _finish,
                style: TextButton.styleFrom(
                  minimumSize: const Size(58, 44),
                  backgroundColor: softAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Finish'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                Expanded(child: _sessionList(session, side)),
                if (_active) _inputBar(side),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddSessionExercise extends StatefulWidget {
  const _AddSessionExercise();

  @override
  State<_AddSessionExercise> createState() => _AddSessionExerciseState();
}

class _AddSessionExerciseState extends State<_AddSessionExercise> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  WorkoutExerciseKind _kind = WorkoutExerciseKind.strength;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      WorkoutExercise(
        id: newWorkoutId(),
        name: _name.text.trim(),
        kind: _kind,
        sets: [
          if (_kind == WorkoutExerciseKind.strength)
            WorkoutSet(id: newWorkoutId()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Add exercise'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _save(),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter an exercise name.'
                  : null,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: [
                for (final (kind, label) in [
                  (WorkoutExerciseKind.strength, 'Strength'),
                  (WorkoutExerciseKind.cardio, 'Cardio'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() => _kind = kind),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Add')),
      ],
    );
  }
}
