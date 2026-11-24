import 'package:material_ui/material_ui.dart';

import 'recurring_task.dart';

class TaskRepeatSettings {
  const TaskRepeatSettings({
    required this.startDate,
    required this.rule,
    this.reminder,
  });

  final DateTime startDate;
  final InternalRecurrenceRule rule;
  final TaskReminderPreference? reminder;
}

Future<TaskRepeatSettings?> showTaskRepeatEditor(
  BuildContext context, {
  required DateTime startDate,
  InternalRecurrenceRule? initialRule,
  TaskReminderPreference? initialReminder,
}) => showDialog<TaskRepeatSettings>(
  context: context,
  builder: (context) => _TaskRepeatEditor(
    startDate: startDate,
    initialRule: initialRule,
    initialReminder: initialReminder,
  ),
);

Future<InternalOccurrenceScope?> showTaskOccurrenceScopeDialog(
  BuildContext context, {
  required bool skipping,
  bool allowSingle = true,
}) => showDialog<InternalOccurrenceScope>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: Text(skipping ? 'Skip repeating task' : 'Edit repeating task'),
    content: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final scope in InternalOccurrenceScope.values)
            if (allowSingle || scope != InternalOccurrenceScope.one)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(switch (scope) {
                  InternalOccurrenceScope.one => 'This occurrence',
                  InternalOccurrenceScope.future =>
                    'This and following occurrences',
                  InternalOccurrenceScope.series => 'Entire series',
                }),
                onTap: () => Navigator.pop(context, scope),
              ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

enum _RepeatEnd { never, count, date }

class _TaskRepeatEditor extends StatefulWidget {
  const _TaskRepeatEditor({
    required this.startDate,
    this.initialRule,
    this.initialReminder,
  });

  final DateTime startDate;
  final InternalRecurrenceRule? initialRule;
  final TaskReminderPreference? initialReminder;

  @override
  State<_TaskRepeatEditor> createState() => _TaskRepeatEditorState();
}

class _TaskRepeatEditorState extends State<_TaskRepeatEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late final Set<int> _weekdays;
  late InternalRecurrenceFrequency _frequency;
  late _RepeatEnd _end;
  late DateTime _start;
  DateTime? _until;
  TaskReminderPreference? _reminder;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rule = widget.initialRule;
    _start = DateUtils.dateOnly(widget.startDate);
    _frequency = rule?.frequency ?? InternalRecurrenceFrequency.weekly;
    _weekdays = {...?rule?.weekdays};
    _interval = TextEditingController(text: '${rule?.interval ?? 1}');
    _count = TextEditingController(text: '${rule?.count ?? 10}');
    _until = rule?.until == null ? null : DateUtils.dateOnly(rule!.until!);
    _end = rule?.count != null
        ? _RepeatEnd.count
        : _until != null
        ? _RepeatEnd.date
        : _RepeatEnd.never;
    _reminder = widget.initialReminder;
  }

  @override
  void dispose() {
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool ending}) async {
    final first = ending ? _start : DateTime(_start.year - 100);
    final last = DateTime(_start.year + 100, 12, 31);
    final until = _until;
    final selected = await showDatePicker(
      context: context,
      initialDate:
          ending &&
              until != null &&
              !until.isBefore(first) &&
              !until.isAfter(last)
          ? until
          : _start,
      firstDate: first,
      lastDate: last,
      helpText: ending ? 'Final repeat date' : 'First occurrence',
    );
    if (!mounted || selected == null) return;
    setState(() {
      _error = null;
      if (ending) {
        _until = selected;
      } else {
        _start = selected;
      }
    });
  }

  Future<void> _pickReminder() async {
    final reminder = _reminder;
    if (reminder == null) return;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: reminder.minuteOfDay ~/ 60,
        minute: reminder.minuteOfDay % 60,
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _reminder = TaskReminderPreference(
        minuteOfDay: selected.hour * 60 + selected.minute,
        dayOffset: reminder.dayOffset,
      );
    });
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final until = _end == _RepeatEnd.date ? _until : null;
    if (_end == _RepeatEnd.date && (until == null || until.isBefore(_start))) {
      setState(
        () => _error = 'Choose a final date on or after the first occurrence.',
      );
      return;
    }
    try {
      final rule = InternalRecurrenceRule(
        frequency: _frequency,
        interval: int.parse(_interval.text.trim()),
        weekdays: _frequency == InternalRecurrenceFrequency.weekly
            ? _weekdays
            : const [],
        count: _end == _RepeatEnd.count ? int.parse(_count.text.trim()) : null,
        until: until,
      );
      Navigator.pop(
        context,
        TaskRepeatSettings(startDate: _start, rule: rule, reminder: _reminder),
      );
    } on ArgumentError catch (error) {
      setState(
        () =>
            _error = error.message?.toString() ?? 'Choose a valid repeat rule.',
      );
    }
  }

  String? _positiveNumber(String? input) {
    final number = int.tryParse(input?.trim() ?? '');
    return number == null || number < 1
        ? 'Enter a positive whole number.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final reminder = _reminder;
    return AlertDialog(
      scrollable: true,
      title: const Text('Repeat task'),
      content: SizedBox(
        width: 390,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('First occurrence'),
                subtitle: Text(localizations.formatMediumDate(_start)),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () => _pickDate(ending: false),
              ),
              DropdownButtonFormField<InternalRecurrenceFrequency>(
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: [
                  for (final frequency in InternalRecurrenceFrequency.values)
                    DropdownMenuItem(
                      value: frequency,
                      child: Text(switch (frequency) {
                        InternalRecurrenceFrequency.daily => 'Daily',
                        InternalRecurrenceFrequency.weekly => 'Weekly',
                        InternalRecurrenceFrequency.monthly => 'Monthly',
                        InternalRecurrenceFrequency.yearly => 'Yearly',
                      }),
                    ),
                ],
                onChanged: (value) => setState(() => _frequency = value!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _interval,
                keyboardType: TextInputType.number,
                validator: _positiveNumber,
                decoration: InputDecoration(
                  labelText: 'Every',
                  suffixText: switch (_frequency) {
                    InternalRecurrenceFrequency.daily => 'days',
                    InternalRecurrenceFrequency.weekly => 'weeks',
                    InternalRecurrenceFrequency.monthly => 'months',
                    InternalRecurrenceFrequency.yearly => 'years',
                  },
                ),
              ),
              if (_frequency == InternalRecurrenceFrequency.weekly) ...[
                const SizedBox(height: 12),
                const Text('Repeat on'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final (index, label) in const [
                      'Mon',
                      'Tue',
                      'Wed',
                      'Thu',
                      'Fri',
                      'Sat',
                      'Sun',
                    ].indexed)
                      FilterChip(
                        label: Text(label),
                        selected: _weekdays.contains(index + 1),
                        onSelected: (value) => setState(() {
                          if (value) {
                            _weekdays.add(index + 1);
                          } else {
                            _weekdays.remove(index + 1);
                          }
                        }),
                      ),
                  ],
                ),
                if (_weekdays.isEmpty)
                  const Text('Uses the first occurrence’s weekday.'),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<_RepeatEnd>(
                initialValue: _end,
                decoration: const InputDecoration(labelText: 'Ends'),
                items: const [
                  DropdownMenuItem(
                    value: _RepeatEnd.never,
                    child: Text('Never'),
                  ),
                  DropdownMenuItem(
                    value: _RepeatEnd.count,
                    child: Text('After a set number'),
                  ),
                  DropdownMenuItem(
                    value: _RepeatEnd.date,
                    child: Text('On a date'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _end = value!;
                  _error = null;
                }),
              ),
              if (_end == _RepeatEnd.count)
                TextFormField(
                  controller: _count,
                  keyboardType: TextInputType.number,
                  validator: _positiveNumber,
                  decoration: const InputDecoration(labelText: 'Occurrences'),
                ),
              if (_end == _RepeatEnd.date)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _until == null
                        ? 'Choose final date'
                        : localizations.formatMediumDate(_until!),
                  ),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: () => _pickDate(ending: true),
                ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: reminder != null,
                title: const Text('Reminder preference'),
                onChanged: (selected) => setState(() {
                  _reminder = selected
                      ? TaskReminderPreference(minuteOfDay: 9 * 60)
                      : null;
                }),
              ),
              if (reminder != null) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    TimeOfDay(
                      hour: reminder.minuteOfDay ~/ 60,
                      minute: reminder.minuteOfDay % 60,
                    ).format(context),
                  ),
                  subtitle: Text(switch (reminder.dayOffset) {
                    0 => 'On the task date',
                    -1 => 'One day before',
                    final offset => '${-offset} days before',
                  }),
                  trailing: const Icon(Icons.schedule),
                  onTap: _pickReminder,
                ),
                const Text(
                  'Delivery depends on this device’s reminder settings.',
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save repeat settings'),
        ),
      ],
    );
  }
}
