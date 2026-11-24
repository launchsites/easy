import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_theme.dart';
import 'workout_plan.dart';

const _weightUnitKey = 'easy.gym.weight-unit.v1';
Future<void>? _weightUnitWrites;

Future<WorkoutWeightUnit> readWorkoutWeightUnit() async {
  if (_weightUnitWrites case final pending?) await pending;
  try {
    final value = await SharedPreferencesAsync().getString(_weightUnitKey);
    if (value == WorkoutWeightUnit.pounds.symbol) {
      return WorkoutWeightUnit.pounds;
    }
  } catch (_) {
    // The default remains available when the preference service is unavailable.
  }
  return WorkoutWeightUnit.kilograms;
}

void rememberWorkoutWeightUnit(WorkoutWeightUnit unit) {
  final prior = _weightUnitWrites;
  final pending = () async {
    if (prior != null) await prior;
    try {
      await SharedPreferencesAsync().setString(_weightUnitKey, unit.symbol);
    } catch (_) {
      // The selected unit still applies for the current screen.
    }
  }();
  _weightUnitWrites = pending;
  pending.whenComplete(() {
    if (identical(_weightUnitWrites, pending)) _weightUnitWrites = null;
  });
}

String workoutWeightText(double kilograms, WorkoutWeightUnit unit) {
  final value = unit.fromKilograms(kilograms);
  final text = value.toStringAsFixed(2);
  return text.contains('.') && !text.contains('e')
      ? text.replaceFirst(RegExp(r'\.?0+$'), '')
      : text;
}

String workoutMetricValueText(WorkoutMetric metric) {
  final value = metric.value.toString().replaceFirst(RegExp(r'\.0$'), '');
  return metric.unit.isEmpty ? value : '$value ${metric.unit}';
}

class WorkoutWeightUnitMenu extends StatelessWidget {
  const WorkoutWeightUnitMenu({
    required this.unit,
    required this.onSelected,
    super.key,
  });

  final WorkoutWeightUnit unit;
  final ValueChanged<WorkoutWeightUnit> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<WorkoutWeightUnit>(
    tooltip: 'Weight unit',
    initialValue: unit,
    onSelected: onSelected,
    icon: Text(
      unit.symbol,
      style: contentMetadataStyle.copyWith(
        color: ink,
        fontWeight: FontWeight.w600,
      ),
    ),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: WorkoutWeightUnit.kilograms,
        child: Text('Kilograms (kg)'),
      ),
      PopupMenuItem(
        value: WorkoutWeightUnit.pounds,
        child: Text('Pounds (lb)'),
      ),
    ],
  );
}

typedef WorkoutMetricEdit = ({WorkoutMetric metric, bool removed});

List<WorkoutMetric> applyWorkoutMetricEdit(
  List<WorkoutMetric> metrics,
  WorkoutMetricEdit edit,
) => [
  for (final existing in metrics)
    if (existing.id != edit.metric.id)
      existing
    else if (!edit.removed)
      edit.metric,
  if (!edit.removed && !metrics.any((metric) => metric.id == edit.metric.id))
    edit.metric,
];

Future<WorkoutMetricEdit?> showWorkoutMetricEditor(
  BuildContext context, {
  WorkoutMetric? metric,
}) => showDialog<WorkoutMetricEdit>(
  context: context,
  builder: (_) => _MetricForm(metric: metric),
);

class _MetricForm extends StatefulWidget {
  const _MetricForm({required this.metric});

  final WorkoutMetric? metric;

  @override
  State<_MetricForm> createState() => _MetricFormState();
}

class _MetricFormState extends State<_MetricForm> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.metric?.label);
  late final _unit = TextEditingController(text: widget.metric?.unit);
  late final _value = TextEditingController(
    text: widget.metric?.value.toString(),
  );

  @override
  void dispose() {
    _label.dispose();
    _unit.dispose();
    _value.dispose();
    super.dispose();
  }

  double? _parse(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop<WorkoutMetricEdit>(context, (
      metric: WorkoutMetric(
        id: widget.metric?.id ?? newWorkoutId(),
        label: _label.text,
        unit: _unit.text,
        value: _parse(_value.text)!,
      ),
      removed: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final metric = widget.metric;
    return AlertDialog(
      scrollable: true,
      title: Text(metric == null ? 'Add metric' : 'Edit metric'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            TextFormField(
              controller: _label,
              autofocus: metric == null,
              maxLength: WorkoutMetric.maxLabelLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Label',
                counterText: '',
              ),
              validator: (value) => WorkoutMetric.isValidLabel(value ?? '')
                  ? null
                  : 'Use 1–${WorkoutMetric.maxLabelLength} characters.',
            ),
            TextFormField(
              controller: _unit,
              maxLength: WorkoutMetric.maxUnitLength,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Unit (optional)',
                counterText: '',
              ),
              validator: (value) => WorkoutMetric.isValidUnit(value ?? '')
                  ? null
                  : 'Use up to ${WorkoutMetric.maxUnitLength} characters.',
            ),
            TextFormField(
              controller: _value,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Value'),
              onFieldSubmitted: (_) => _save(),
              validator: (input) {
                final number = _parse(input ?? '');
                if (number != null && WorkoutMetric.isValidValue(number)) {
                  return null;
                }
                return 'Enter a number from −1,000,000 to 1,000,000.';
              },
            ),
          ],
        ),
      ),
      actions: [
        if (metric != null)
          TextButton(
            onPressed: () => Navigator.pop<WorkoutMetricEdit>(context, (
              metric: metric,
              removed: true,
            )),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save metric')),
      ],
    );
  }
}
