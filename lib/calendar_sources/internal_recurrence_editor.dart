import 'package:material_ui/material_ui.dart';

import 'internal_recurrence.dart';

Future<InternalOccurrenceScope?> showInternalOccurrenceScopeDialog(
  BuildContext context, {
  required bool skipping,
}) => showDialog<InternalOccurrenceScope>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    scrollable: true,
    title: Text(skipping ? 'Skip recurring event' : 'Edit recurring event'),
    contentPadding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final scope in InternalOccurrenceScope.values)
            ListTile(
              title: Text(switch (scope) {
                InternalOccurrenceScope.one => 'This occurrence',
                InternalOccurrenceScope.future =>
                  'This and following occurrences',
                InternalOccurrenceScope.series => 'Entire series',
              }),
              onTap: () => Navigator.pop(dialogContext, scope),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Cancel'),
      ),
    ],
  ),
);

Future<InternalRecurrenceRule?> showInternalRecurrenceRuleEditor(
  BuildContext context, {
  InternalRecurrenceRule? initialRule,
  DateTime? startDate,
}) => showDialog<InternalRecurrenceRule>(
  context: context,
  builder: (dialogContext) => InternalRecurrenceRuleEditor(
    initialRule:
        initialRule ??
        InternalRecurrenceRule(frequency: InternalRecurrenceFrequency.weekly),
    startDate: startDate,
    onSave: (rule) => Navigator.pop(dialogContext, rule),
    onCancel: () => Navigator.pop(dialogContext),
  ),
);

class InternalRecurrenceRuleEditor extends StatefulWidget {
  const InternalRecurrenceRuleEditor({
    required this.initialRule,
    required this.onSave,
    required this.onCancel,
    this.startDate,
    super.key,
  });

  final InternalRecurrenceRule initialRule;
  final ValueChanged<InternalRecurrenceRule> onSave;
  final VoidCallback onCancel;
  final DateTime? startDate;

  @override
  State<InternalRecurrenceRuleEditor> createState() =>
      _InternalRecurrenceRuleEditorState();
}

enum _Ends { never, count, date }

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _InternalRecurrenceRuleEditorState
    extends State<InternalRecurrenceRuleEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _interval;
  late final TextEditingController _count;
  late final Set<int> _weekdaysSelected;
  late InternalRecurrenceFrequency _frequency;
  late _Ends _ends;
  DateTime? _until;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rule = widget.initialRule;
    _interval = TextEditingController(text: '${rule.interval}');
    _count = TextEditingController(text: '${rule.count ?? 10}');
    _frequency = rule.frequency;
    _weekdaysSelected = rule.weekdays.toSet();
    _until = rule.until;
    _ends = rule.count != null
        ? _Ends.count
        : rule.until != null
        ? _Ends.date
        : _Ends.never;
  }

  @override
  void dispose() {
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_ends == _Ends.date && _until == null) {
      setState(() => _error = 'Choose the final date.');
      return;
    }
    try {
      widget.onSave(
        InternalRecurrenceRule(
          frequency: _frequency,
          interval: int.parse(_interval.text.trim()),
          weekdays: _frequency == InternalRecurrenceFrequency.weekly
              ? _weekdaysSelected
              : const [],
          count: _ends == _Ends.count ? int.parse(_count.text.trim()) : null,
          until: _ends == _Ends.date ? _until : null,
        ),
      );
    } on ArgumentError catch (error) {
      setState(
        () =>
            _error = error.message?.toString() ?? 'Choose a valid repeat rule.',
      );
    }
  }

  Future<void> _pickDate() async {
    final start = DateUtils.dateOnly(widget.startDate ?? DateTime.now());
    final until = _until == null ? null : DateUtils.dateOnly(_until!);
    final first = widget.startDate == null ? DateTime(start.year - 100) : start;
    final last = DateTime(start.year + 100, 12, 31);
    final selected = await showDatePicker(
      context: context,
      initialDate:
          until != null && !until.isBefore(first) && !until.isAfter(last)
          ? until
          : start,
      firstDate: first,
      lastDate: last,
      helpText: 'Final repeat date',
    );
    if (mounted && selected != null) {
      setState(() {
        _until = DateTime.utc(selected.year, selected.month, selected.day);
        _error = null;
      });
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
    return AlertDialog(
      scrollable: true,
      title: const Text('Repeat event'),
      content: SizedBox(
        width: 390,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<InternalRecurrenceFrequency>(
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: const [
                  DropdownMenuItem(
                    value: InternalRecurrenceFrequency.daily,
                    child: Text('Daily'),
                  ),
                  DropdownMenuItem(
                    value: InternalRecurrenceFrequency.weekly,
                    child: Text('Weekly'),
                  ),
                  DropdownMenuItem(
                    value: InternalRecurrenceFrequency.monthly,
                    child: Text('Monthly'),
                  ),
                  DropdownMenuItem(
                    value: InternalRecurrenceFrequency.yearly,
                    child: Text('Yearly'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  _frequency = value!;
                  _error = null;
                }),
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
                const SizedBox(height: 14),
                const Text('Repeat on'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  children: [
                    for (var day = 1; day <= _weekdays.length; day++)
                      FilterChip(
                        label: Text(_weekdays[day - 1]),
                        selected: _weekdaysSelected.contains(day),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _weekdaysSelected.add(day);
                          } else {
                            _weekdaysSelected.remove(day);
                          }
                        }),
                      ),
                  ],
                ),
                if (_weekdaysSelected.isEmpty)
                  Text(
                    'Uses the first occurrence’s weekday.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<_Ends>(
                initialValue: _ends,
                decoration: const InputDecoration(labelText: 'Ends'),
                items: const [
                  DropdownMenuItem(value: _Ends.never, child: Text('Never')),
                  DropdownMenuItem(
                    value: _Ends.count,
                    child: Text('After a set number'),
                  ),
                  DropdownMenuItem(value: _Ends.date, child: Text('On a date')),
                ],
                onChanged: (value) => setState(() {
                  _ends = value!;
                  _error = null;
                }),
              ),
              if (_ends == _Ends.count) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _count,
                  keyboardType: TextInputType.number,
                  validator: _positiveNumber,
                  decoration: const InputDecoration(labelText: 'Occurrences'),
                ),
              ],
              if (_ends == _Ends.date)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _pickDate,
                    child: Text(
                      _until == null
                          ? 'Choose final date'
                          : localizations.formatMediumDate(_until!),
                    ),
                  ),
                ),
              if (_error case final message?)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save repeat rule')),
      ],
    );
  }
}
