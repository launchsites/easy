part of 'health_page.dart';

DateTime _localDay(DateTime date) => DateTime(date.year, date.month, date.day);

Future<DateTime?> _chooseHealthDay(
  BuildContext context,
  DateTime initial, {
  required String title,
  DateTime? firstDay,
}) {
  final day = _localDay(initial);
  return showDatePicker(
    context: context,
    initialDate: day,
    firstDate: firstDay == null
        ? DateTime(math.min(1900, day.year))
        : _localDay(firstDay),
    lastDate: DateTime(math.max(2200, day.year), 12, 31),
    helpText: title,
  );
}

typedef _SaveMeasurement = Future<bool> Function(
  MeasurementKind kind,
  MeasurementUnit unit,
  double? value,
  DateTime when,
);

class _MeasurementForm extends StatefulWidget {
  const _MeasurementForm({
    required this.initialKind,
    required this.initialUnit,
    required this.initialTime,
    required this.initialValue,
    required this.goal,
    required this.onSave,
  });

  final MeasurementKind initialKind;
  final MeasurementUnit initialUnit;
  final DateTime initialTime;
  final double? initialValue;
  final bool goal;
  final _SaveMeasurement onSave;

  @override
  State<_MeasurementForm> createState() => _MeasurementFormState();
}

class _MeasurementFormState extends State<_MeasurementForm> {
  late MeasurementKind _kind = widget.initialKind;
  late MeasurementUnit _unit = widget.initialUnit;
  late DateTime _when = widget.initialTime;
  late final _value = TextEditingController(
    text: widget.initialValue?.toString(),
  );
  bool _saving = false;
  String? _issue;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final day = await _chooseHealthDay(
      context,
      _when,
      title: 'Measurement date',
    );
    if (mounted && day != null) {
      setState(
        () => _when = DateTime(
          day.year,
          day.month,
          day.day,
          _when.hour,
          _when.minute,
        ),
      );
    }
  }

  Future<void> _save({bool clear = false}) async {
    if (_saving) return;
    final value = clear ? null : double.tryParse(_value.text.trim());
    if (!clear && (value == null || !value.isFinite || value <= 0)) {
      setState(() => _issue = 'Enter a positive measurement.');
      return;
    }
    setState(() {
      _issue = null;
      _saving = true;
    });
    FocusScope.of(context).unfocus();
    try {
      final saved = await widget.onSave(_kind, _unit, value, _when);
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _issue = 'The measurement could not be saved.');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _issue = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _issue = 'The measurement could not be saved.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(
        widget.goal
            ? '${_kind.label} target'
            : (widget.initialValue == null
                  ? 'Log measurement'
                  : 'Edit measurement'),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.goal)
              DropdownButtonFormField<MeasurementKind>(
                initialValue: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final kind in MeasurementKind.values)
                    DropdownMenuItem(value: kind, child: Text(kind.label)),
                ],
                onChanged: _saving
                    ? null
                    : (kind) => setState(() {
                        if (kind != null) {
                          _kind = kind;
                          if (!_kind.units.contains(_unit)) {
                            _unit = _kind.units.first;
                          }
                        }
                      }),
              ),
            TextField(
              controller: _value,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: widget.goal ? 'Target' : 'Value',
              ),
            ),
            DropdownButtonFormField<MeasurementUnit>(
              key: ValueKey(_kind.units.first),
              initialValue: _unit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: [
                for (final unit in _kind.units)
                  DropdownMenuItem(value: unit, child: Text(unit.label)),
              ],
              onChanged: _saving
                  ? null
                  : (unit) => setState(() => _unit = unit ?? _unit),
            ),
            if (!widget.goal)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined, size: 18),
                title: Text(
                  MaterialLocalizations.of(context).formatMediumDate(_when),
                ),
                subtitle: const Text('Recorded on'),
                onTap: _saving ? null : _pickDay,
              ),
            if (_issue case final issue?)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  issue,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.goal && widget.initialValue != null)
          TextButton(
            onPressed: _saving ? null : () => _save(clear: true),
            child: const Text('Remove target'),
          ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}

typedef _LimitationDraft = ({
  String title,
  String note,
  DateTime reportedOn,
  DateTime? reviewOn,
  bool allWorkouts,
  List<HealthExerciseTarget> exercises,
});

class _LimitationForm extends StatefulWidget {
  const _LimitationForm({
    required this.when,
    required this.choices,
    required this.onSave,
  });

  final DateTime when;
  final List<HealthExerciseTarget> choices;
  final Future<bool> Function(_LimitationDraft draft) onSave;

  @override
  State<_LimitationForm> createState() => _LimitationFormState();
}

class _LimitationFormState extends State<_LimitationForm> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  late DateTime _reportedOn = _localDay(widget.when);
  DateTime? _reviewOn;
  var _all = false;
  var _saving = false;
  String? _issue;
  List<HealthExerciseTarget> _selected = const [];

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _date({required bool review}) async {
    final initial = review ? _reviewOn ?? _localDay(widget.when) : _reportedOn;
    final choice = await _chooseHealthDay(
      context,
      review && initial.isBefore(_reportedOn) ? _reportedOn : initial,
      firstDay: review ? _reportedOn : null,
      title: review ? 'Review date' : 'Report date',
    );
    if (!mounted || choice == null) return;
    setState(() {
      if (review) {
        _reviewOn = choice;
      } else {
        _reportedOn = choice;
        if (_reviewOn?.isBefore(choice) ?? false) _reviewOn = null;
      }
    });
  }

  Future<void> _scope() async {
    final selected = await showDialog<List<HealthExerciseTarget>>(
      context: context,
      builder: (_) =>
          _ExerciseScope(choices: widget.choices, initial: _selected),
    );
    if (mounted && selected != null) setState(() => _selected = selected);
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _issue = 'Enter a note title.');
      return;
    }
    setState(() {
      _issue = null;
      _saving = true;
    });
    FocusScope.of(context).unfocus();
    try {
      final saved = await widget.onSave((
        title: _title.text.trim(),
        note: _note.text,
        reportedOn: _reportedOn,
        reviewOn: _reviewOn,
        allWorkouts: _all,
        exercises: _all ? const [] : _selected,
      ));
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _issue = 'The note could not be saved.');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _issue = error.message);
    } catch (_) {
      if (mounted) setState(() => _issue = 'The note could not be saved.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = MaterialLocalizations.of(context);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        title: const Text('New workout note'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Title'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _note,
                enabled: !_saving,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Note'),
                textCapitalization: TextCapitalization.sentences,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Reported on'),
                subtitle: Text(locals.formatMediumDate(_reportedOn)),
                onTap: _saving ? null : () => _date(review: false),
              ),
              _HealthReviewDate(
                value: _reviewOn,
                onChoose: _saving ? null : () => _date(review: true),
                onClear: _saving
                    ? null
                    : () => setState(() => _reviewOn = null),
              ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show before all workouts'),
                value: _all,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _all = value),
              ),
              if (!_all && widget.choices.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Select exercises'),
                  subtitle: _selected.isEmpty
                      ? null
                      : Text('${_selected.length} selected'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _saving ? null : _scope,
                ),
              if (_issue case final issue?)
                Text(
                  issue,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save note'),
          ),
        ],
      ),
    );
  }
}

class _ExerciseScope extends StatefulWidget {
  const _ExerciseScope({required this.choices, required this.initial});

  final List<HealthExerciseTarget> choices;
  final List<HealthExerciseTarget> initial;

  @override
  State<_ExerciseScope> createState() => _ExerciseScopeState();
}

class _ExerciseScopeState extends State<_ExerciseScope> {
  late final _checked = {for (final exercise in widget.initial) exercise.key};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Select exercises'),
    content: SizedBox(
      width: 440,
      height: math.min(310, MediaQuery.sizeOf(context).height * .44),
      child: ListView.builder(
        itemCount: widget.choices.length,
        itemBuilder: (context, index) {
          final exercise = widget.choices[index];
          return CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(exercise.name),
            subtitle: Text(exercise.planName),
            value: _checked.contains(exercise.key),
            onChanged: (checked) => setState(() {
              if (checked == true) {
                _checked.add(exercise.key);
              } else {
                _checked.remove(exercise.key);
              }
            }),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, [
          for (final exercise in widget.choices)
            if (_checked.contains(exercise.key)) exercise,
        ]),
        child: const Text('Use selection'),
      ),
    ],
  );
}

class _ReviewLimitationForm extends StatefulWidget {
  const _ReviewLimitationForm({required this.when, required this.onSave});

  final DateTime when;
  final Future<bool> Function(HealthLimitationReview entry) onSave;

  @override
  State<_ReviewLimitationForm> createState() => _ReviewLimitationFormState();
}

class _ReviewLimitationFormState extends State<_ReviewLimitationForm> {
  final _note = TextEditingController();
  DateTime? _next;
  var _resolved = false;
  var _saving = false;
  String? _issue;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _setDate() async {
    final choice = await _chooseHealthDay(
      context,
      _next ?? widget.when,
      firstDay: widget.when,
      title: 'Next review date',
    );
    if (mounted && choice != null) setState(() => _next = choice);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _issue = null;
      _saving = true;
    });
    FocusScope.of(context).unfocus();
    try {
      final saved = await widget.onSave(
        HealthLimitationReview(
          reviewedAt: widget.when,
          outcome: _resolved
              ? HealthReviewOutcome.resolved
              : HealthReviewOutcome.remainsOpen,
          nextReviewOn: _resolved ? null : _next,
          note: _note.text,
        ),
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _issue = 'The review could not be saved.');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _issue = error.message);
    } catch (_) {
      if (mounted) setState(() => _issue = 'The review could not be saved.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Review workout note'),
      content: SizedBox(
        width: 410,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              textCapitalization: TextCapitalization.sentences,
              controller: _note,
              minLines: 2,
              maxLines: 5,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Review note'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Resolve note'),
              value: _resolved,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _resolved = value),
            ),
            if (!_resolved)
              _HealthReviewDate(
                value: _next,
                onChoose: _saving ? null : _setDate,
                onClear: _saving ? null : () => setState(() => _next = null),
              ),
            if (_issue case final issue?)
              Text(
                issue,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save review'),
        ),
      ],
    ),
  );
}

class _HealthReviewDate extends StatelessWidget {
  const _HealthReviewDate({
    required this.value,
    required this.onChoose,
    required this.onClear,
  });

  final DateTime? value;
  final VoidCallback? onChoose;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final when = value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Review date'),
      subtitle: Text(
        when == null
            ? 'Optional'
            : MaterialLocalizations.of(context).formatMediumDate(when),
      ),
      trailing: when == null || onClear == null
          ? null
          : IconButton(
              onPressed: onClear,
              tooltip: 'Clear review date',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
      onTap: onChoose,
    );
  }
}
