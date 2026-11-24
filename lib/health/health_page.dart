import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'health_models.dart';

part 'health_forms.dart';

class HealthPage extends StatefulWidget {
  const HealthPage({
    required this.data,
    required this.onChanged,
    this.exerciseTargets = const [],
    this.clock,
    super.key,
  });

  final HealthData data;
  final Future<void> Function(HealthData data) onChanged;
  final List<HealthExerciseTarget> exerciseTargets;
  final DateTime Function()? clock;

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  late HealthData _health = widget.data;
  MeasurementKind _kind = MeasurementKind.bodyWeight;
  MeasurementUnit _unit = MeasurementUnit.kilograms;
  var _showNotes = false;
  var _saving = false;

  DateTime get _now => (widget.clock ?? DateTime.now)().toLocal();

  @override
  void didUpdateWidget(covariant HealthPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_saving && !identical(oldWidget.data, widget.data)) {
      _health = widget.data;
    }
  }

  Future<bool> _persist(HealthData value) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      await widget.onChanged(value);
      if (mounted) setState(() => _health = value);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _saveFailed() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The change could not be saved. Try again.'),
        ),
      );
    }
  }

  Future<void> _measurement([BodyMeasurement? old]) async {
    final now = _now;
    await showDialog<void>(
      context: context,
      builder: (context) => _MeasurementForm(
        initialKind: old?.kind ?? _kind,
        initialUnit: old?.unit ?? _unit,
        initialValue: old?.value,
        initialTime: old?.recordedAt.toLocal() ?? now,
        goal: false,
        onSave: (kind, unit, value, timestamp) async {
          final saved = await _persist(
            _health.withMeasurement(
              BodyMeasurement(
                id:
                    old?.id ??
                    'measurement-${now.microsecondsSinceEpoch}-${_health.measurements.length}',
                kind: kind,
                unit: unit,
                value: value!,
                recordedAt: timestamp,
              ),
            ),
          );
          if (saved && mounted) {
            setState(() {
              _kind = kind;
              _unit = unit;
            });
          }
          return saved;
        },
      ),
    );
  }

  Future<void> _goal(MeasurementGoal? old) async {
    final kind = _kind;
    await showDialog<void>(
      context: context,
      builder: (context) => _MeasurementForm(
        initialKind: kind,
        initialUnit: old?.unit ?? _unit,
        initialValue: old?.value,
        initialTime: _now,
        goal: true,
        onSave: (_, unit, value, _) => _persist(
          _health.withGoal(
            kind,
            value == null
                ? null
                : MeasurementGoal(kind: kind, unit: unit, value: value),
          ),
        ),
      ),
    );
  }

  Future<void> _removeMeasurement(BodyMeasurement measurement) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove measurement?'),
        content: Text(
          '${measurement.kind.label} · ${_display(measurement.value, measurement.unit)}',
        ),
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
    if (confirmed == true &&
        mounted &&
        !await _persist(_health.withoutMeasurement(measurement.id))) {
      _saveFailed();
    }
  }

  Future<void> _limitation() async {
    final now = _now;
    await showDialog<void>(
      context: context,
      builder: (context) => _LimitationForm(
        when: now,
        choices: widget.exerciseTargets,
        onSave: (draft) => _persist(
          _health.withLimitation(
            HealthLimitation(
              id: 'health-note-${now.microsecondsSinceEpoch}-${_health.limitations.length}',
              title: draft.title,
              reportedOn: draft.reportedOn,
              note: draft.note,
              reviewOn: draft.reviewOn,
              allWorkouts: draft.allWorkouts,
              exercises: draft.exercises,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reviewLimitation(HealthLimitation limitation) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ReviewLimitationForm(
        when: _now,
        onSave: (review) =>
            _persist(_health.withLimitation(limitation.withReview(review))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Health log')),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 5,
                children: [
                  ChoiceChip(
                    label: const Text('Measurements'),
                    selected: !_showNotes,
                    onSelected: _saving
                        ? null
                        : (_) => setState(() => _showNotes = false),
                  ),
                  ChoiceChip(
                    label: const Text('Workout notes'),
                    selected: _showNotes,
                    onSelected: _saving
                        ? null
                        : (_) => setState(() => _showNotes = true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_showNotes) ..._notes() else ..._measurements(),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _measurements() {
    final labels = MaterialLocalizations.of(context);
    final records =
        _health.measurements.where((item) => item.kind == _kind).toList()
          ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final goal = _health.goals.where((item) => item.kind == _kind).firstOrNull;
    return [
      _HealthHeading(
        title: _kind.label,
        action: FilledButton.icon(
          onPressed: _saving ? null : _measurement,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Log measurement'),
        ),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          PopupMenuButton<MeasurementKind>(
            tooltip: 'Measurement type',
            initialValue: _kind,
            onSelected: (value) => setState(() {
              _kind = value;
              _unit = value.units.first;
            }),
            itemBuilder: (_) => [
              for (final kind in MeasurementKind.values)
                PopupMenuItem(value: kind, child: Text(kind.label)),
            ],
            child: const _HealthPickerLabel('Measurement type'),
          ),
          PopupMenuButton<MeasurementUnit>(
            tooltip: 'Display unit',
            initialValue: _unit,
            onSelected: (value) => setState(() => _unit = value),
            itemBuilder: (_) => [
              for (final unit in _kind.units)
                PopupMenuItem(value: unit, child: Text(unit.label)),
            ],
            child: _HealthPickerLabel(_unit.label),
          ),
          TextButton(
            onPressed: _saving ? null : () => _goal(goal),
            child: Text(goal == null ? 'Set target' : 'Edit target'),
          ),
        ],
      ),
      if (goal != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text(
            'Target ${_display(_unit.fromBase(goal.baseValue), _unit)}',
            style: contentMetadataStyle,
          ),
        ),
      if (records.length >= 2)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Semantics(
            label: 'Recorded ${_kind.label.toLowerCase()} trend',
            child: SizedBox(
              height: 99,
              child: CustomPaint(
                painter: _MeasurementChart(
                  readings: records.reversed.toList(),
                  target: goal?.baseValue,
                ),
              ),
            ),
          ),
        ),
      if (records.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No measurements recorded.', style: contentMetadataStyle),
        )
      else
        _HealthRows(
          key: ValueKey(_kind),
          length: records.length,
          row: (index) {
            final item = records[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _display(item.inUnit(_unit), _unit),
                style: contentTitleStyle,
              ),
              subtitle: Text(
                labels.formatFullDate(item.recordedAt.toLocal()),
                style: contentMetadataStyle,
              ),
              trailing: PopupMenuButton<bool>(
                tooltip: 'Manage measurement',
                enabled: !_saving,
                onSelected: (remove) =>
                    remove ? _removeMeasurement(item) : _measurement(item),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: false, child: Text('Edit')),
                  PopupMenuItem(value: true, child: Text('Remove')),
                ],
              ),
            );
          },
        ),
    ];
  }

  List<Widget> _notes() {
    final records = _health.limitations.toList()
      ..sort((first, second) {
        if (first.open != second.open) return first.open ? -1 : 1;
        return second.reportedOn.compareTo(first.reportedOn);
      });
    return [
      _HealthHeading(
        title: 'Workout notes',
        action: FilledButton.icon(
          onPressed: _saving ? null : _limitation,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New note'),
        ),
      ),
      if (records.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 11),
          child: Text(
            'No workout notes recorded.',
            style: contentMetadataStyle,
          ),
        )
      else
        _HealthRows(
          key: const ValueKey('health-notes'),
          length: records.length,
          row: (index) => _noteRow(records[index]),
        ),
    ];
  }

  Widget _noteRow(HealthLimitation note) {
    final labels = MaterialLocalizations.of(context);
    final reviewDate = note.nextReviewOn;
    final status = switch ((note.open, reviewDate)) {
      (false, _) => 'Resolved',
      (true, final date?) =>
        '${note.reviewIsDue(_now) ? 'Review due' : 'Review'} ${labels.formatMediumDate(date)}',
      _ => 'Open',
    };
    return ExpansionTile(
      key: PageStorageKey(('limitation', note.id)),
      tilePadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      title: Text(note.title, style: contentTitleStyle),
      subtitle: Text(status, style: contentMetadataStyle),
      children: [
        Text(
          'Reported ${labels.formatFullDate(note.reportedOn)}',
          style: contentMetadataStyle,
        ),
        if (note.note.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectionArea(child: Text(note.note)),
          ),
        Text(
          note.allWorkouts
              ? 'All workouts'
              : note.exercises.isEmpty
              ? 'Health log only'
              : note.exercises
                    .map((item) => '${item.name} · ${item.planName}')
                    .join('\n'),
          style: contentMetadataStyle,
        ),
        for (final review in note.reviews.reversed)
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${labels.formatMediumDate(review.reviewedOn)} · ${review.outcome == HealthReviewOutcome.resolved ? 'Resolved' : 'Reviewed'}',
                  style: contentMetadataStyle,
                ),
                if (review.note.trim().isNotEmpty)
                  SelectionArea(child: Text(review.note)),
              ],
            ),
          ),
        if (note.open)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _saving ? null : () => _reviewLimitation(note),
              child: const Text('Add review'),
            ),
          ),
      ],
    );
  }
}

String _display(double value, MeasurementUnit unit) {
  final number = value.abs() < .01 || value.abs() >= 1e21
      ? value.toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return '$number ${unit.label}';
}

class _HealthHeading extends StatelessWidget {
  const _HealthHeading({required this.title, required this.action});

  final String title;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final heading = Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    );
    final stacked =
        MediaQuery.sizeOf(context).width < 380 ||
        MediaQuery.textScalerOf(context).scale(16) > 21;
    return stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 7), action],
          )
        : Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: 10),
              action,
            ],
          );
  }
}

class _HealthPickerLabel extends StatelessWidget {
  const _HealthPickerLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        const Icon(Icons.expand_more_rounded, size: 18),
      ],
    ),
  );
}

class _HealthRows extends StatefulWidget {
  const _HealthRows({required this.length, required this.row, super.key});

  final int length;
  final Widget Function(int) row;

  @override
  State<_HealthRows> createState() => _HealthRowsState();
}

class _HealthRowsState extends State<_HealthRows> {
  var _count = 10;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var index = 0; index < math.min(_count, widget.length); index++) ...[
        widget.row(index),
        if (index + 1 < widget.length) const Divider(),
      ],
      if (_count < widget.length)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => setState(() => _count += 12),
            child: const Text('Show more'),
          ),
        ),
    ],
  );
}

class _MeasurementChart extends CustomPainter {
  const _MeasurementChart({required this.readings, required this.target});

  final List<BodyMeasurement> readings;
  final double? target;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      7,
      7,
      math.max(0, size.width - 14),
      math.max(0, size.height - 14),
    );
    final values = [for (final item in readings) item.baseValue];
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    final first = readings.first.recordedAt;
    final elapsed = readings.last.recordedAt.difference(first).inMicroseconds;
    double y(double value) => max == min
        ? plot.center.dy
        : plot.bottom - plot.height * ((value - min) / (max - min));
    final guide = target;
    if (guide != null && guide >= min && guide <= max) {
      canvas.drawLine(
        Offset(plot.left, y(guide)),
        Offset(plot.right, y(guide)),
        Paint()
          ..color = line
          ..strokeWidth = 2,
      );
    }
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = accent;
    Offset? previous;
    for (final (index, item) in readings.indexed) {
      final share = elapsed == 0
          ? index / (readings.length - 1)
          : item.recordedAt.difference(first).inMicroseconds / elapsed;
      final point = Offset(plot.left + plot.width * share, y(item.baseValue));
      if (previous != null) canvas.drawLine(previous, point, paint);
      canvas.drawCircle(point, 3.2, paint);
      previous = point;
    }
  }

  @override
  bool shouldRepaint(covariant _MeasurementChart oldDelegate) =>
      target != oldDelegate.target ||
      !listEquals(readings, oldDelegate.readings);
}
