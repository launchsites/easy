import 'package:material_ui/material_ui.dart';

import 'gym_mode_ui.dart';
import 'ui_theme.dart';
import 'workout_plan.dart';

class WorkoutPlansPage extends StatefulWidget {
  const WorkoutPlansPage({
    required this.plans,
    required this.onChanged,
    this.initialPlan,
    super.key,
  });

  final List<WorkoutPlan> plans;
  final ValueChanged<List<WorkoutPlan>> onChanged;
  final WorkoutPlan? initialPlan;

  @override
  State<WorkoutPlansPage> createState() => _WorkoutPlansPageState();
}

typedef _PlanEdit = ({WorkoutPlan plan, bool removed});
typedef _ExerciseEdit = ({WorkoutExercise exercise, bool removed});

class _WorkoutPlansPageState extends State<WorkoutPlansPage> {
  late List<WorkoutPlan> _plans = widget.plans;

  @override
  void didUpdateWidget(covariant WorkoutPlansPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.plans != oldWidget.plans) _plans = widget.plans;
  }

  void _apply(_PlanEdit edit) {
    final plans = _plans.toList();
    final index = plans.indexWhere((plan) => plan.id == edit.plan.id);
    if (edit.removed) {
      if (index == -1) return;
      plans.removeAt(index);
    } else if (index == -1) {
      plans.add(edit.plan);
    } else {
      plans[index] = edit.plan;
    }
    final snapshot = List<WorkoutPlan>.unmodifiable(plans);
    setState(() => _plans = snapshot);
    widget.onChanged(snapshot);
  }

  Future<void> _edit([WorkoutPlan? plan]) async {
    final edit = await Navigator.of(context).push<_PlanEdit>(
      MaterialPageRoute(
        builder: (context) => MobileModeFrame(
          mode: 'gym',
          child: _WorkoutPlanEditor(
            plan: plan,
            onComplete: (edit) => Navigator.pop(context, edit),
          ),
        ),
      ),
    );
    if (mounted && edit != null) _apply(edit);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initialPlan case final plan?) {
      return _WorkoutPlanEditor(
        plan: plan,
        onComplete: (edit) {
          _apply(edit);
          Navigator.pop(context);
        },
      );
    }

    return _PlanPage(
      title: 'Workout plans',
      action: FilledButton(onPressed: _edit, child: const Text('New workout')),
      children: [
        if (_plans.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 7),
            child: Text(
              'No workout plans yet.',
              style: TextStyle(color: muted),
            ),
          ),
        for (final plan in _plans) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.fitness_center_outlined, color: accent),
            trailing: const Icon(Icons.chevron_right_rounded, color: muted),
            title: Text(plan.name, style: _rowTitle),
            subtitle: Text(
              _scheduleLabel(context, plan.schedule),
              style: const TextStyle(color: muted),
            ),
            onTap: () => _edit(plan),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

const _scheduleKinds = {
  WorkoutScheduleKind.once: 'Once',
  WorkoutScheduleKind.weekdays: 'Weekdays',
  WorkoutScheduleKind.interval: 'Every N days',
};

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const _weekdayLabels = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _exerciseKinds = {
  WorkoutExerciseKind.cardio: 'Cardio',
  WorkoutExerciseKind.strength: 'Strength',
};

const _rowTitle = TextStyle(color: ink, fontWeight: FontWeight.w600);

String _scheduleLabel(BuildContext context, WorkoutSchedule schedule) {
  final date = MaterialLocalizations.of(context)
      .formatShortDate(schedule.startDate);
  return switch (schedule.kind) {
    WorkoutScheduleKind.once => date,
    WorkoutScheduleKind.weekdays =>
      '${schedule.weekdays.map((index) => _weekdays[index - 1]).join(', ')} · Starts $date',
    WorkoutScheduleKind.interval =>
      '${schedule.intervalDays == 1 ? 'Daily' : 'Every ${schedule.intervalDays} days'} · Starts $date',
  };
}

class _WorkoutPlanEditor extends StatefulWidget {
  const _WorkoutPlanEditor({required this.plan, required this.onComplete});

  final WorkoutPlan? plan;
  final ValueChanged<_PlanEdit> onComplete;

  @override
  State<_WorkoutPlanEditor> createState() => _WorkoutPlanEditorState();
}

class _WorkoutPlanEditorState extends State<_WorkoutPlanEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.plan?.id ?? newWorkoutId();
  late String _name = widget.plan?.name ?? '';
  late WorkoutScheduleKind _kind =
      widget.plan?.schedule.kind ?? WorkoutScheduleKind.once;
  late DateTime _start =
      widget.plan?.schedule.startDate ?? DateUtils.dateOnly(DateTime.now());
  late String _interval = (widget.plan?.schedule.intervalDays ?? 2).toString();
  late final Set<int> _selectedDays = {...?widget.plan?.schedule.weekdays};
  late final List<WorkoutExercise> _exercises = [...?widget.plan?.exercises];
  bool _dirty = false;
  bool _noWeekdays = false;

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(_start.year < 1900 ? _start.year : 1900),
      lastDate: DateTime(_start.year > 2200 ? _start.year : 2200, 12, 31),
      helpText: _kind == WorkoutScheduleKind.once
          ? 'Choose workout date'
          : 'Choose start date',
    );
    if (!mounted || picked == null || DateUtils.isSameDay(picked, _start)) {
      return;
    }
    setState(() {
      _start = picked;
      _dirty = true;
    });
  }

  Future<void> _editExercise([WorkoutExercise? exercise]) async {
    final edit = await Navigator.of(context).push<_ExerciseEdit>(
      MaterialPageRoute(
        builder: (_) => MobileModeFrame(
          mode: 'gym',
          child: _WorkoutExerciseEditor(exercise: exercise),
        ),
      ),
    );
    if (!mounted || edit == null) return;
    final index = _exercises.indexWhere((item) => item.id == edit.exercise.id);
    setState(() {
      _dirty = true;
      if (edit.removed) {
        if (index >= 0) _exercises.removeAt(index);
      } else if (index < 0) {
        _exercises.add(edit.exercise);
      } else {
        _exercises[index] = edit.exercise;
      }
    });
  }

  void _save() {
    final noWeekdays =
        _kind == WorkoutScheduleKind.weekdays && _selectedDays.isEmpty;
    setState(() => _noWeekdays = noWeekdays);
    if (!_validateForm(_form) || noWeekdays) return;

    final plan = WorkoutPlan(
      id: _id,
      name: _name.trim(),
      schedule: WorkoutSchedule(
        kind: _kind,
        startDate: _start,
        weekdays: _kind == WorkoutScheduleKind.weekdays
            ? (_selectedDays.toList()..sort())
            : const [],
        intervalDays: _kind == WorkoutScheduleKind.interval
            ? int.parse(_interval.trim())
            : 1,
      ),
      exercises: List.unmodifiable(_exercises),
    );
    widget.onComplete((plan: plan, removed: false));
  }

  Future<void> _delete() async {
    final confirmed = await _confirm(context, 'Delete workout plan?', 'Delete');
    if (!mounted || !confirmed) return;
    widget.onComplete((plan: widget.plan!, removed: true));
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final date = MaterialLocalizations.of(context).formatShortDate(_start);
    return PopScope<_PlanEdit>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;
        if (await _confirm(context, 'Discard changes?', 'Discard') &&
            context.mounted) {
          Navigator.pop(context);
        }
      },
      child: _PlanPage(
        title: plan == null ? 'New workout' : 'Edit workout',
        action: FilledButton(
          onPressed: _save,
          child: const Text('Save workout'),
        ),
        form: _form,
        children: [
          TextFormField(
            initialValue: _name,
            decoration: _field('Workout name'),
            textCapitalization: TextCapitalization.sentences,
            validator: _requiredName,
            onChanged: (name) {
              _name = name;
              _markDirty();
            },
          ),
          const SizedBox(height: 23),
          const _Heading('Schedule'),
          _Choices(
            options: _scheduleKinds,
            selected: _kind,
            onSelected: (kind) {
              if (_kind == kind) return;
              setState(() {
                _kind = kind;
                if (kind == WorkoutScheduleKind.weekdays &&
                    _selectedDays.isEmpty) {
                  _selectedDays.add(_start.weekday);
                }
                _noWeekdays = false;
                _dirty = true;
              });
            },
          ),
          const SizedBox(height: 5),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.calendar_today_outlined,
              color: accent,
              size: 20,
            ),
            title: Text(
              _kind == WorkoutScheduleKind.once ? 'Date' : 'Start date',
              style: _rowTitle,
            ),
            subtitle: Text(date, style: const TextStyle(color: muted)),
            trailing: const Icon(Icons.chevron_right_rounded, color: muted),
            onTap: _pickDate,
          ),
          if (_kind == WorkoutScheduleKind.weekdays) ...[
            Wrap(
              spacing: 7,
              runSpacing: 4,
              children: [
                for (var index = 0; index < _weekdays.length; index++)
                  FilterChip(
                    label: Text(
                      _weekdays[index],
                      semanticsLabel: _weekdayLabels[index],
                    ),
                    selected: _selectedDays.contains(index + 1),
                    showCheckmark: false,
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selectedDays.add(index + 1);
                      } else {
                        _selectedDays.remove(index + 1);
                      }
                      _noWeekdays = false;
                      _dirty = true;
                    }),
                  ),
              ],
            ),
            if (_noWeekdays)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Choose one or more weekdays.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
          if (_kind == WorkoutScheduleKind.interval) ...[
            const SizedBox(height: 7),
            _NumberField(
              label: 'Repeat every (days)',
              value: _interval,
              integer: true,
              minimum: 1,
              isRequired: true,
              onChanged: (interval) {
                _interval = interval;
                _markDirty();
              },
            ),
          ],
          const SizedBox(height: 24),
          const _Heading('Exercises'),
          for (final exercise in _exercises) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(exercise.name, style: _rowTitle),
              subtitle: Text(
                _exerciseLabel(exercise),
                style: const TextStyle(color: muted),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: muted),
              onTap: () => _editExercise(exercise),
            ),
            const Divider(),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _editExercise,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Add exercise'),
            ),
          ),
          if (plan != null) ...[
            const SizedBox(height: 18),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: _delete,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Delete workout plan'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _exerciseLabel(WorkoutExercise exercise) => switch (exercise.kind) {
  WorkoutExerciseKind.cardio =>
    '${_decimalText(exercise.distanceKm)} km · ${_decimalText(exercise.inclinePercent)}% incline · ${exercise.minutes} min',
  WorkoutExerciseKind.strength =>
    '${exercise.sets.length} ${exercise.sets.length == 1 ? 'set' : 'sets'}',
};

class _WorkoutExerciseEditor extends StatefulWidget {
  const _WorkoutExerciseEditor({required this.exercise});

  final WorkoutExercise? exercise;

  @override
  State<_WorkoutExerciseEditor> createState() => _WorkoutExerciseEditorState();
}

class _WorkoutExerciseEditorState extends State<_WorkoutExerciseEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.exercise?.id ?? newWorkoutId();
  late String _name = widget.exercise?.name ?? '';
  late WorkoutExerciseKind _kind =
      widget.exercise?.kind ?? WorkoutExerciseKind.strength;
  late String _km = _decimalText(widget.exercise?.distanceKm ?? 0);
  late String _incline = _decimalText(widget.exercise?.inclinePercent ?? 0);
  late String _minutes = (widget.exercise?.minutes ?? 0).toString();
  late final List<_SetDraft> _sets = [
    for (final set in widget.exercise?.sets ?? const <WorkoutSet>[])
      _SetDraft(set),
  ];
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    if (widget.exercise == null && _kind == WorkoutExerciseKind.strength) {
      _sets.add(_SetDraft(WorkoutSet(id: newWorkoutId())));
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _save() {
    if (!_validateForm(_form)) return;
    final cardio = _kind == WorkoutExerciseKind.cardio;
    final exercise = WorkoutExercise(
      id: _id,
      name: _name.trim(),
      kind: _kind,
      distanceKm: cardio ? _parseDecimal(_km) ?? 0 : 0,
      inclinePercent: cardio ? _parseDecimal(_incline) ?? 0 : 0,
      minutes: cardio ? int.tryParse(_minutes.trim()) ?? 0 : 0,
      sets: cardio ? const [] : [for (final draft in _sets) draft.toSet()],
    );
    Navigator.pop<_ExerciseEdit>(context, (exercise: exercise, removed: false));
  }

  @override
  Widget build(BuildContext context) {
    final exercise = widget.exercise;
    return PopScope<_ExerciseEdit>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_dirty) return;
        if (await _confirm(context, 'Discard changes?', 'Discard') &&
            context.mounted) {
          Navigator.pop(context);
        }
      },
      child: _PlanPage(
        title: exercise == null ? 'Add exercise' : 'Edit exercise',
        action: FilledButton(
          onPressed: _save,
          child: const Text('Save exercise'),
        ),
        form: _form,
        children: [
          TextFormField(
            initialValue: _name,
            decoration: _field('Exercise name'),
            textCapitalization: TextCapitalization.sentences,
            validator: _requiredName,
            onChanged: (name) {
              _name = name;
              _markDirty();
            },
          ),
          const SizedBox(height: 22),
          const _Heading('Type'),
          _Choices(
            options: _exerciseKinds,
            selected: _kind,
            onSelected: (kind) {
              if (kind == _kind) return;
              setState(() {
                _kind = kind;
                _dirty = true;
                if (kind == WorkoutExerciseKind.strength && _sets.isEmpty) {
                  _sets.add(_SetDraft(WorkoutSet(id: newWorkoutId())));
                }
              });
            },
          ),
          const SizedBox(height: 12),
          if (_kind == WorkoutExerciseKind.cardio)
            Column(
              spacing: 9,
              children: [
                _NumberField(
                  label: 'Distance (km)',
                  value: _km,
                  onChanged: (value) {
                    _km = value;
                    _markDirty();
                  },
                ),
                _NumberField(
                  label: 'Incline (%)',
                  value: _incline,
                  minimum: null,
                  onChanged: (value) {
                    _incline = value;
                    _markDirty();
                  },
                ),
                _NumberField(
                  label: 'Minutes',
                  value: _minutes,
                  integer: true,
                  onChanged: (value) {
                    _minutes = value;
                    _markDirty();
                  },
                ),
              ],
            )
          else ...[
            const _Heading('Sets'),
            for (final (index, draft) in _sets.indexed) ...[
              _StrengthSetFields(
                key: ValueKey(draft.id),
                index: index,
                draft: draft,
                onChange: _markDirty,
                onRemove: () => setState(() {
                  _sets.removeAt(index);
                  _dirty = true;
                }),
              ),
              const SizedBox(height: 10),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _sets.add(_SetDraft(WorkoutSet(id: newWorkoutId())));
                  _dirty = true;
                }),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Add set'),
              ),
            ),
          ],
          if (exercise != null) ...[
            const SizedBox(height: 18),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => Navigator.pop<_ExerciseEdit>(context, (
                  exercise: exercise,
                  removed: true,
                )),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Remove exercise'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SetDraft {
  _SetDraft(WorkoutSet set)
    : id = set.id,
      weight = _decimalText(set.weightKg),
      reps = set.reps.toString();

  final String id;
  String weight;
  String reps;

  WorkoutSet toSet() => WorkoutSet(
    id: id,
    weightKg: _parseDecimal(weight) ?? 0,
    reps: int.parse(reps.trim()),
  );
}

class _StrengthSetFields extends StatelessWidget {
  const _StrengthSetFields({
    required this.index,
    required this.draft,
    required this.onChange,
    required this.onRemove,
    super.key,
  });

  final int index;
  final _SetDraft draft;
  final VoidCallback onChange;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final number = index + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Set $number', style: _rowTitle)),
            IconButton(
              tooltip: 'Remove set $number',
              icon: const Icon(Icons.close_rounded, size: 19, color: muted),
              onPressed: onRemove,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _NumberField(
                label: 'Weight (kg)',
                value: draft.weight,
                onChanged: (value) {
                  draft.weight = value;
                  onChange();
                },
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: _NumberField(
                label: 'Reps',
                value: draft.reps,
                integer: true,
                isRequired: true,
                onChanged: (value) {
                  draft.reps = value;
                  onChange();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.integer = false,
    this.minimum = 0,
    this.isRequired = false,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool integer;
  final int? minimum;
  final bool isRequired;

  String? _validate(String? source) {
    final text = source?.trim() ?? '';
    if (text.isEmpty) return isRequired ? 'Enter a value.' : null;
    final number = integer ? int.tryParse(text) : _parseDecimal(text);
    if (number == null || !number.isFinite) {
      return integer ? 'Use a whole number.' : 'Enter a number.';
    }
    if (minimum case final minimum? when number < minimum) {
      return 'Use $minimum or more.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: value,
    decoration: _field(label),
    keyboardType: TextInputType.numberWithOptions(
      signed: minimum == null,
      decimal: !integer,
    ),
    textInputAction: TextInputAction.next,
    onChanged: onChanged,
    validator: _validate,
  );
}

String _decimalText(double number) =>
    number.toString().replaceFirst(RegExp(r'\.0$'), '');

double? _parseDecimal(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

String? _requiredName(String? value) =>
    (value?.trim().isEmpty ?? true) ? 'Enter a name.' : null;

bool _validateForm(GlobalKey<FormState> form) {
  final firstError = form.currentState!.validateGranularly().firstOrNull;
  if (firstError == null) return true;
  Scrollable.ensureVisible(firstError.context);
  return false;
}

InputDecoration _field(String label) {
  final radius = BorderRadius.circular(9);
  return InputDecoration(
    labelText: label,
    filled: true,
    fillColor: raisedPaper,
    border: OutlineInputBorder(borderRadius: radius),
    enabledBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: line),
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String action) async {
  return await showDialog<bool>(
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
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 7,
    runSpacing: 4,
    children: [
      for (final option in options.entries)
        ChoiceChip(
          label: Text(option.value),
          selected: option.key == selected,
          showCheckmark: false,
          onSelected: (_) => onSelected(option.key),
        ),
    ],
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      header: true,
      child: Text(label, style: sectionHeadingStyle),
    ),
  );
}

class _PlanPage extends StatelessWidget {
  const _PlanPage({
    required this.title,
    required this.action,
    required this.children,
    this.form,
  });

  final String title;
  final Widget action;
  final List<Widget> children;
  final GlobalKey<FormState>? form;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.sizeOf(context).width < 600 ? 20.0 : 36.0;
    final padding = EdgeInsets.fromLTRB(inset, 15, inset, 20);
    final scrolling = form == null
        ? ListView(padding: padding, children: children)
        : Form(
            key: form,
            child: SingleChildScrollView(
              padding: padding,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              children: [
                Expanded(child: scrolling),
                const Divider(),
                Padding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: action,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
