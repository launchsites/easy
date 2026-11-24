import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import '../workout_plan.dart';
import '../workspace_data.dart' show spaceColors, spaceName;
import 'activity_model.dart';

class ActivitiesPage extends StatefulWidget {
  const ActivitiesPage({
    required this.data,
    required this.onChanged,
    this.targets = const [],
    this.clock,
    super.key,
  });

  final ActivityData data;
  final Future<void> Function(ActivityData) onChanged;
  final List<ActivityTarget> targets;
  final DateTime Function()? clock;

  @override
  State<ActivitiesPage> createState() => _ActivitiesPageState();
}

typedef _ActivityChange = ActivityData Function(ActivityData);
typedef _PersistActivity = Future<String?> Function(_ActivityChange);

class _ActivitiesPageState extends State<ActivitiesPage> {
  late ActivityData _data = widget.data;
  late final _activeClock = _ActivityClock(_wallNow());
  bool _saving = false;

  DateTime _wallNow() => (widget.clock ?? DateTime.now)().toLocal();

  DateTime _now() => _data.active?.status == ActivityStatus.running
      ? _activeClock.reconcile(_wallNow())
      : _wallNow();

  @override
  void didUpdateWidget(covariant ActivitiesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data && !_saving) _data = widget.data;
  }

  Future<String?> _persist(_ActivityChange change) async {
    if (_saving) return 'Another change is still saving.';
    final ActivityData next;
    try {
      next = change(_data);
    } on FormatException catch (error) {
      return error.message;
    } on StateError catch (error) {
      return error.message;
    }
    final wasRunning = _data.active?.status == ActivityStatus.running;
    setState(() => _saving = true);
    try {
      await widget.onChanged(next);
      if (mounted) {
        setState(() => _data = next);
        if (!wasRunning && next.active?.status == ActivityStatus.running) {
          _activeClock.reset(_wallNow());
        }
      }
      return null;
    } catch (_) {
      return 'Could not save this activity change. Try again.';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _apply(_ActivityChange change) async {
    final error = await _persist(change);
    if (mounted && error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _edit(_EditorKind kind, [ActivityRecord? record]) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (editorContext) => _ActivityEditor(
          kind: kind,
          record: record,
          targets: widget.targets,
          clock: _wallNow,
          persist: _persist,
          onLogActual: kind == _EditorKind.plan && record != null
              ? () {
                  Navigator.pop(editorContext);
                  _edit(_EditorKind.actual, record);
                }
              : null,
        ),
      ),
    );
  }

  void _openRoutines() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _RoutineLibrary(
        data: () => _data,
        persist: _persist,
        clock: _wallNow,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final active = _data.active;
    final upcoming =
        _data.records
            .where((record) => record.status == ActivityStatus.planned)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final history =
        _data.records
            .where((record) => record.status == ActivityStatus.finished)
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
    return _ActivityScreen(
      title: 'Activities',
      actions: [
        TextButton(onPressed: _openRoutines, child: const Text('Routines')),
      ],
      children: [
        if (active != null) ...[
          _ActiveActivity(
            record: active,
            clock: _now,
            saving: _saving,
            onPauseResume: () => _apply(
              (data) => active.status == ActivityStatus.running
                  ? data.pause(_now())
                  : data.resume(_now()),
            ),
            onFinish: () => _apply((data) => data.finish(_now())),
            onStep: (step, checked) =>
                _apply((data) => data.setStep(active.id, step, checked)),
          ),
          const SizedBox(height: 18),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (active == null)
              FilledButton.icon(
                onPressed: _saving ? null : () => _edit(_EditorKind.start),
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: const Text('Start activity'),
              ),
            OutlinedButton(
              onPressed: () => _edit(_EditorKind.plan),
              child: const Text('Plan activity'),
            ),
            TextButton(
              onPressed: () => _edit(_EditorKind.actual),
              child: const Text('Log past time'),
            ),
          ],
        ),
        if (upcoming.isNotEmpty) ...[
          const SizedBox(height: 24),
          const _Heading('Planned'),
          for (final record in upcoming) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(record.title, style: contentTitleStyle),
              subtitle: Text(
                _windowLabel(context, record.plan!),
                style: contentMetadataStyle,
              ),
              trailing: TextButton(
                onPressed: active != null || _saving
                    ? null
                    : () => _apply(
                        (data) => data.beginPlan(record.id, _wallNow()),
                      ),
                child: Text('Start', semanticsLabel: 'Start ${record.title}'),
              ),
              onTap: () => _edit(_EditorKind.plan, record),
            ),
            const Divider(),
          ],
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 24),
          const _Heading('Actual history'),
          for (final record in history) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(record.title, style: contentTitleStyle),
              subtitle: Text(
                '${MaterialLocalizations.of(context).formatMediumDate(record.time.toLocal())}'
                ' · ${_duration(record.elapsedAt(_wallNow()))} actual'
                '${record.plan == null ? '' : ' · ${_duration(record.plan!.length)} planned'}',
                style: contentMetadataStyle,
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: muted),
              onTap: () => _edit(_EditorKind.actual, record),
            ),
            const Divider(),
          ],
        ],
        if (_data.records.isEmpty) ...[
          const SizedBox(height: 20),
          const Text('No activities recorded.', style: contentMetadataStyle),
        ],
      ],
    );
  }
}

class _ActivityClock {
  _ActivityClock(this._anchor);

  DateTime _anchor;
  final _elapsed = Stopwatch()..start();

  void reset(DateTime wall) {
    _anchor = wall;
    _elapsed.reset();
  }

  DateTime reconcile(DateTime wall) {
    final monotonic = _anchor.add(_elapsed.elapsed);
    if (wall.isAfter(monotonic)) {
      reset(wall);
      return wall;
    }
    return monotonic;
  }
}

class _ActiveActivity extends StatelessWidget {
  const _ActiveActivity({
    required this.record,
    required this.clock,
    required this.saving,
    required this.onPauseResume,
    required this.onFinish,
    required this.onStep,
  });

  final ActivityRecord record;
  final DateTime Function() clock;
  final bool saving;
  final VoidCallback onPauseResume;
  final VoidCallback onFinish;
  final void Function(String id, bool checked) onStep;

  @override
  Widget build(BuildContext context) => Material(
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            record.status == ActivityStatus.paused ? 'Paused' : 'In progress',
            style: contentMetadataStyle,
          ),
          const SizedBox(height: 5),
          Text(record.title, style: sectionHeadingStyle),
          const SizedBox(height: 7),
          _Elapsed(record: record, clock: clock),
          if (record.plan case final plan?)
            Text(
              'Planned ${_windowLabel(context, plan)}',
              style: contentMetadataStyle,
            ),
          if (record.steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final step in record.steps)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(step.title, style: contentTitleStyle),
                controlAffinity: ListTileControlAffinity.leading,
                value: record.checkedStepIds.contains(step.id),
                onChanged: saving
                    ? null
                    : (value) => onStep(step.id, value == true),
              ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton(
                onPressed: saving ? null : onPauseResume,
                child: Text(
                  record.status == ActivityStatus.running ? 'Pause' : 'Resume',
                ),
              ),
              FilledButton(
                onPressed: saving ? null : onFinish,
                child: const Text('Finish'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.record, required this.clock});

  final ActivityRecord record;
  final DateTime Function() clock;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> with WidgetsBindingObserver {
  Timer? _timer;
  bool _visible = false;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _resumed =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _Elapsed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.record.status != oldWidget.record.status) _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _syncTimer();
    if (_resumed) setState(() {});
  }

  void _syncTimer() {
    final shouldTick =
        _visible && _resumed && widget.record.status == ActivityStatus.running;
    if (shouldTick) {
      _timer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    _duration(widget.record.elapsedAt(widget.clock()), seconds: true),
    style: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 34,
      height: 1.1,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );
}

String _duration(Duration value, {bool seconds = false}) {
  final hours = value.inHours;
  final minutes = value.inMinutes % 60;
  if (seconds) {
    final tail = (value.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$tail'
        : '$minutes:$tail';
  }
  if (hours == 0) {
    return value.inMinutes == 0 ? '<1 min' : '${value.inMinutes} min';
  }
  return minutes == 0 ? '$hours hr' : '$hours hr $minutes min';
}

String _time(BuildContext context, DateTime date) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(date.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

String _windowLabel(BuildContext context, ActivityWindow window) {
  final date = MaterialLocalizations.of(context)
      .formatMediumDate(window.start.toLocal());
  final end = DateUtils.isSameDay(window.start.toLocal(), window.end.toLocal())
      ? _time(context, window.end)
      : '${MaterialLocalizations.of(context).formatMediumDate(window.end.toLocal())} ${_time(context, window.end)}';
  return '$date · ${_time(context, window.start)}–$end';
}

enum _EditorKind { start, plan, actual }

typedef _SpanDraft = ({DateTime start, DateTime end});

class _ActivityEditor extends StatefulWidget {
  const _ActivityEditor({
    required this.kind,
    required this.record,
    required this.targets,
    required this.clock,
    required this.persist,
    this.onLogActual,
  });

  final _EditorKind kind;
  final ActivityRecord? record;
  final List<ActivityTarget> targets;
  final DateTime Function() clock;
  final _PersistActivity persist;
  final VoidCallback? onLogActual;

  @override
  State<_ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<_ActivityEditor> {
  late final _title = TextEditingController(text: widget.record?.title);
  late String _category = widget.record?.category ?? 'personal';
  late ActivityTarget? _target = widget.record?.target;
  late final List<_SpanDraft> _spans = _initialSpans();
  bool _saving = false;
  String? _error;

  List<_SpanDraft> _initialSpans() {
    final now = widget.clock();
    final record = widget.record;
    final plan = record?.plan;
    if (widget.kind == _EditorKind.plan) {
      return [
        plan == null
            ? (
                start: now.add(const Duration(minutes: 30)),
                end: now.add(const Duration(hours: 1)),
              )
            : (start: plan.start.toLocal(), end: plan.end.toLocal()),
      ];
    }
    if (record?.spans.isNotEmpty ?? false) {
      return [
        for (final span in record!.spans)
          (start: span.start.toLocal(), end: span.end!.toLocal()),
      ];
    }
    if (plan != null && !plan.end.isAfter(now)) {
      return [(start: plan.start.toLocal(), end: plan.end.toLocal())];
    }
    return [(start: now.subtract(const Duration(minutes: 30)), end: now)];
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _selectTarget(ActivityTarget? target) => setState(() {
    if (target != null) {
      if (_title.text.trim().isEmpty || _title.text == _target?.title) {
        _title.text = target.title;
      }
      _category = target.category;
      if (target.plan case final plan? when widget.kind == _EditorKind.plan) {
        _spans[0] = (start: plan.start.toLocal(), end: plan.end.toLocal());
      }
    }
    _target = target;
  });

  Future<void> _changeSpan(int index, bool start, bool date) async {
    final span = _spans[index];
    final current = start ? span.start : span.end;
    final picked = date
        ? await _datePicker(context, current)
        : await _timePicker(context, current);
    if (!mounted || picked == null) return;
    setState(() {
      _spans[index] = start
          ? (start: picked, end: span.end)
          : (start: span.start, end: picked);
      _error = null;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Enter an activity name.');
      return;
    }
    final record = widget.record;
    final now = widget.clock();
    final _ActivityChange change;
    switch (widget.kind) {
      case _EditorKind.start:
        change = (data) => data.begin(
          now: now,
          title: title,
          category: _category,
          target: _target,
        );
      case _EditorKind.plan:
        final time = _spans.single;
        change = (data) => data.plan(
          id: record?.id,
          title: title,
          category: _category,
          target: _target,
          window: ActivityWindow(time.start, time.end),
        );
      case _EditorKind.actual:
        if (_spans.any((span) => span.end.isAfter(now))) {
          setState(() => _error = 'Actual time cannot end in the future.');
          return;
        }
        change = (data) => data.logActual(
          id: record?.id,
          title: title,
          category: _category,
          target: _target,
          spans: [
            for (final span in _spans)
              ActivitySpan(start: span.start, end: span.end),
          ],
        );
    }
    await _commit(change);
  }

  Future<void> _commit(_ActivityChange change) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.persist(change);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final actual = widget.kind == _EditorKind.actual;
    final title = switch (widget.kind) {
      _EditorKind.start => 'Start activity',
      _EditorKind.plan => record == null ? 'Plan activity' : 'Edit plan',
      _EditorKind.actual =>
        record == null ? 'Log past time' : 'Edit actual time',
    };
    final action = switch (widget.kind) {
      _EditorKind.start => 'Start timer',
      _EditorKind.plan => 'Save plan',
      _EditorKind.actual => 'Save actual time',
    };
    return _ActivityScreen(
      title: title,
      error: _error,
      footer: FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving…' : action),
      ),
      children: [
        TextField(
          controller: _title,
          decoration: _decoration('Activity name'),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 10),
        _CategoryField(
          value: _category,
          onChanged: (value) => setState(() => _category = value),
        ),
        if (widget.targets.isNotEmpty && !(actual && record != null)) ...[
          const SizedBox(height: 10),
          _TargetField(
            target: _target,
            targets: widget.targets,
            onChanged: _selectTarget,
          ),
        ] else if (record?.target case final target?)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Linked to ${target.title}',
              style: contentMetadataStyle,
            ),
          ),
        if (actual && record?.plan != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Planned ${_windowLabel(context, record!.plan!)}',
              style: contentMetadataStyle,
            ),
          ),
        if (widget.kind != _EditorKind.start) ...[
          const SizedBox(height: 18),
          for (final (index, span) in _spans.indexed) ...[
            if (actual && _spans.length > 1)
              Row(
                children: [
                  Expanded(child: _Heading('Segment ${index + 1}')),
                  IconButton(
                    tooltip: 'Remove segment ${index + 1}',
                    onPressed: _saving
                        ? null
                        : () => setState(() => _spans.removeAt(index)),
                    icon: const Icon(Icons.close_rounded, color: muted),
                  ),
                ],
              ),
            _TimeFields(
              label: 'Start',
              time: span.start,
              onDate: () => _changeSpan(index, true, true),
              onTime: () => _changeSpan(index, true, false),
            ),
            _TimeFields(
              label: 'End',
              time: span.end,
              onDate: () => _changeSpan(index, false, true),
              onTime: () => _changeSpan(index, false, false),
            ),
            const SizedBox(height: 8),
          ],
          if (actual)
            _MinorAction(
              'Add segment',
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      final end = _spans.last.end;
                      _spans.add((start: end, end: end));
                    }),
            ),
        ],
        if (widget.onLogActual != null)
          _MinorAction(
            'Log actual time',
            onPressed: _saving ? null : widget.onLogActual,
          ),
        if (record != null)
          _MinorAction(
            'Remove activity',
            destructive: true,
            onPressed: _saving
                ? null
                : () async {
                    if (await _confirmRemove(
                          context,
                          'Remove this activity?',
                        ) &&
                        mounted) {
                      await _commit((data) => data.removeRecord(record.id));
                    }
                  },
          ),
      ],
    );
  }
}

class _TargetField extends StatelessWidget {
  const _TargetField({
    required this.target,
    required this.targets,
    required this.onChanged,
  });

  final ActivityTarget? target;
  final List<ActivityTarget> targets;
  final ValueChanged<ActivityTarget?> onChanged;

  String _key(ActivityTarget item) => '${item.kind.name}:${item.id}';

  @override
  Widget build(BuildContext context) {
    final options = {for (final item in targets) _key(item): item};
    if (target case final current?) {
      options.putIfAbsent(_key(current), () => current);
    }
    return DropdownButtonFormField<String>(
      decoration: _decoration('Link (optional)'),
      initialValue: target == null ? '' : _key(target!),
      isExpanded: true,
      items: [
        const DropdownMenuItem(value: '', child: Text('No link')),
        for (final entry in options.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value.title, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (key) => onChanged(options[key]),
    );
  }
}

class _CategoryField extends StatelessWidget {
  const _CategoryField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: ValueKey(value),
    decoration: _decoration('Space'),
    initialValue: value,
    isExpanded: true,
    items: [
      for (final name in {...spaceColors.keys, value})
        DropdownMenuItem(
          value: name,
          child: Text(spaceName(name), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (value) {
      if (value != null) onChanged(value);
    },
  );
}

class _TimeFields extends StatelessWidget {
  const _TimeFields({
    required this.label,
    required this.time,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final DateTime time;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: contentMetadataStyle),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: onDate,
            child: Text(
              MaterialLocalizations.of(context).formatMediumDate(time),
              semanticsLabel:
                  '$label date ${MaterialLocalizations.of(context).formatMediumDate(time)}',
            ),
          ),
          OutlinedButton(
            onPressed: onTime,
            child: Text(
              _time(context, time),
              semanticsLabel: '$label time ${_time(context, time)}',
            ),
          ),
        ],
      ),
    ],
  );
}

class _RoutineLibrary extends StatefulWidget {
  const _RoutineLibrary({
    required this.data,
    required this.persist,
    required this.clock,
  });

  final ActivityData Function() data;
  final _PersistActivity persist;
  final DateTime Function() clock;

  @override
  State<_RoutineLibrary> createState() => _RoutineLibraryState();
}

class _RoutineLibraryState extends State<_RoutineLibrary> {
  bool _saving = false;
  String? _error;

  Future<void> _edit([RoutineTemplate? routine]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _RoutineEditor(
          routine: routine,
          persist: widget.persist,
          clock: widget.clock,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _start(RoutineTemplate routine) async {
    setState(() => _saving = true);
    final error = await widget.persist(
      (data) => data.beginRoutine(routine.id, widget.clock()),
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _error = error;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data();
    final today = widget.clock();
    final locale = MaterialLocalizations.of(context);
    final routines = data.routines.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return _ActivityScreen(
      title: 'Routines',
      error: _error,
      footer: FilledButton(
        onPressed: _saving ? null : _edit,
        child: const Text('New routine'),
      ),
      children: [
        if (routines.isEmpty)
          const Text('No routines saved.', style: contentMetadataStyle),
        for (final routine in routines) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(routine.title, style: contentTitleStyle),
            subtitle: Text(
              routine.schedule == null
                  ? 'Manual'
                  : switch (routine.schedule!.nextOnOrAfter(today)) {
                      null => 'No upcoming date',
                      final day when DateUtils.isSameDay(day, today) =>
                        'Due today',
                      final day => 'Next ${locale.formatMediumDate(day)}',
                    },
              style: contentMetadataStyle,
            ),
            trailing: TextButton(
              onPressed: _saving || data.active != null
                  ? null
                  : () => _start(routine),
              child: Text('Start', semanticsLabel: 'Start ${routine.title}'),
            ),
            onTap: () => _edit(routine),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

class _RoutineEditor extends StatefulWidget {
  const _RoutineEditor({
    required this.routine,
    required this.persist,
    required this.clock,
  });

  final RoutineTemplate? routine;
  final _PersistActivity persist;
  final DateTime Function() clock;

  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

enum _StepEdit { up, down, remove }

class _StepDraft {
  _StepDraft(this.id, this.title);
  final String id;
  String title;
}

class _RoutineEditorState extends State<_RoutineEditor> {
  static const _repeats = {
    'manual': 'Manual',
    'once': 'Once',
    'weekdays': 'Weekdays',
    'interval': 'Every N days',
  };
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  late final _title = TextEditingController(text: widget.routine?.title);
  late final _interval = TextEditingController(
    text: (widget.routine?.schedule?.intervalDays ?? 1).toString(),
  );
  late String _category = widget.routine?.category ?? 'personal';
  late String _repeat = widget.routine?.schedule?.kind.name ?? 'manual';
  late final _daysSelected = {...?widget.routine?.schedule?.weekdays};
  late DateTime _start =
      widget.routine?.schedule?.startDate ?? DateUtils.dateOnly(widget.clock());
  late final List<_StepDraft> _steps = [
    for (final step in widget.routine?.steps ?? const <RoutineStep>[])
      _StepDraft(step.id, step.title),
  ];
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final interval = int.tryParse(_interval.text.trim());
    if (_repeat == 'interval' && (interval == null || interval < 1)) {
      setState(() => _error = 'Use a whole number of days greater than zero.');
      return;
    }
    await _commit(
      (data) => data.saveRoutine(
        RoutineTemplate(
          id: widget.routine?.id ?? newActivityId(),
          title: _title.text.trim(),
          category: _category,
          steps: [
            for (final step in _steps)
              RoutineStep(id: step.id, title: step.title.trim()),
          ],
          schedule: _repeat == 'manual'
              ? null
              : WorkoutSchedule(
                  kind: WorkoutScheduleKind.values.byName(_repeat),
                  startDate: _start,
                  weekdays: _daysSelected.toList(),
                  intervalDays: _repeat == 'interval' ? interval! : 1,
                ),
        ),
      ),
    );
  }

  Future<void> _commit(_ActivityChange change) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.persist(change);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  Future<void> _chooseStart() async {
    final picked = await _datePicker(context, _start);
    if (mounted && picked != null) {
      setState(() => _start = DateUtils.dateOnly(picked));
    }
  }

  void _editStep(int index, _StepEdit edit) => setState(() {
    final step = _steps.removeAt(index);
    switch (edit) {
      case _StepEdit.up:
        _steps.insert(index - 1, step);
      case _StepEdit.down:
        _steps.insert(index + 1, step);
      case _StepEdit.remove:
        break;
    }
  });

  @override
  Widget build(BuildContext context) => _ActivityScreen(
    title: widget.routine == null ? 'New routine' : 'Edit routine',
    error: _error,
    footer: FilledButton(
      onPressed: _saving ? null : _save,
      child: Text(_saving ? 'Saving…' : 'Save routine'),
    ),
    children: [
      TextField(
        controller: _title,
        decoration: _decoration('Routine name'),
        textCapitalization: TextCapitalization.sentences,
      ),
      const SizedBox(height: 10),
      _CategoryField(
        value: _category,
        onChanged: (value) => setState(() => _category = value),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        decoration: _decoration('Repeat'),
        initialValue: _repeat,
        items: [
          for (final entry in _repeats.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: (repeat) {
          if (repeat == null) return;
          setState(() {
            _repeat = repeat;
            if (repeat == 'weekdays' && _daysSelected.isEmpty) {
              _daysSelected.add(_start.weekday);
            }
          });
        },
      ),
      if (_repeat != 'manual')
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            _repeat == 'once' ? 'Date' : 'Start date',
            style: contentTitleStyle,
          ),
          subtitle: Text(
            MaterialLocalizations.of(context).formatMediumDate(_start),
            style: contentMetadataStyle,
          ),
          trailing: const Icon(
            Icons.calendar_today_outlined,
            color: muted,
            size: 19,
          ),
          onTap: _chooseStart,
        ),
      if (_repeat == 'weekdays')
        Wrap(
          spacing: 7,
          children: [
            for (final (index, label) in _days.indexed)
              FilterChip(
                label: Text(label),
                selected: _daysSelected.contains(index + 1),
                onSelected: (selected) => setState(() {
                  if (selected) {
                    _daysSelected.add(index + 1);
                  } else {
                    _daysSelected.remove(index + 1);
                  }
                }),
              ),
          ],
        ),
      if (_repeat == 'interval')
        TextField(
          controller: _interval,
          keyboardType: TextInputType.number,
          decoration: _decoration('Repeat every (days)'),
        ),
      const SizedBox(height: 18),
      const _Heading('Checklist'),
      for (final (index, step) in _steps.indexed)
        Padding(
          key: ValueKey(step.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: step.title,
                  decoration: _decoration('Step ${index + 1}'),
                  onChanged: (value) => step.title = value,
                ),
              ),
              PopupMenuButton<_StepEdit>(
                tooltip: 'Step ${index + 1} options',
                onSelected: (edit) => _editStep(index, edit),
                itemBuilder: (_) => [
                  if (index > 0)
                    const PopupMenuItem(
                      value: _StepEdit.up,
                      child: Text('Move up'),
                    ),
                  if (index < _steps.length - 1)
                    const PopupMenuItem(
                      value: _StepEdit.down,
                      child: Text('Move down'),
                    ),
                  const PopupMenuItem(
                    value: _StepEdit.remove,
                    child: Text('Remove step'),
                  ),
                ],
              ),
            ],
          ),
        ),
      _MinorAction(
        'Add step',
        onPressed: _saving
            ? null
            : () => setState(() => _steps.add(_StepDraft(newActivityId(), ''))),
      ),
      if (widget.routine case final routine?)
        _MinorAction(
          'Remove routine',
          destructive: true,
          onPressed: _saving
              ? null
              : () async {
                  if (await _confirmRemove(context, 'Remove this routine?') &&
                      mounted) {
                    await _commit((data) => data.removeRoutine(routine.id));
                  }
                },
        ),
    ],
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    ),
  );
}

class _MinorAction extends StatelessWidget {
  const _MinorAction(
    this.label, {
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton(
      onPressed: onPressed,
      style: destructive
          ? TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            )
          : null,
      child: Text(label),
    ),
  );
}

class _ActivityScreen extends StatelessWidget {
  const _ActivityScreen({
    required this.title,
    required this.children,
    this.actions = const [],
    this.footer,
    this.error,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Widget? footer;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      actions: actions,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final controls = Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (error case final text?) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        text,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  ?footer,
                ],
              );
              final compact =
                  constraints.maxHeight <
                  MediaQuery.textScalerOf(context).scale(150);
              final list = ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  ...children,
                  if (compact && footer != null) ...[
                    const SizedBox(height: 10),
                    controls,
                  ],
                ],
              );
              if (compact || footer == null) return list;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 13),
                    child: controls,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

InputDecoration _decoration(String label) => InputDecoration(
  labelText: label,
  filled: true,
  fillColor: raisedPaper,
  border: const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(9)),
  ),
  enabledBorder: const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(9)),
    borderSide: BorderSide(color: line),
  ),
);

Future<DateTime?> _datePicker(BuildContext context, DateTime date) async {
  final picked = await showDatePicker(
    context: context,
    initialDate: date,
    firstDate: DateTime(date.year < 1900 ? date.year : 1900),
    lastDate: DateTime(date.year > 2200 ? date.year : 2200, 12, 31),
  );
  return picked == null
      ? null
      : DateTime(picked.year, picked.month, picked.day, date.hour, date.minute);
}

Future<DateTime?> _timePicker(BuildContext context, DateTime date) async {
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(date),
  );
  return time == null
      ? null
      : DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

Future<bool> _confirmRemove(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
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
    ) ??
    false;
