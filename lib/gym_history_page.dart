import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute, SynchronousFuture;
import 'package:material_ui/material_ui.dart';

import 'gym_progress.dart';
import 'gym_session.dart';
import 'health/health_models.dart';
import 'workout_metrics_ui.dart';
import 'workout_plan.dart';

typedef _HistoryInput = ({
  List<GymSession> sessions,
  List<BodyMeasurement> bodyMeasurements,
});

GymProgressHistory _projectHistory(_HistoryInput input) => GymProgressHistory(
  sessions: input.sessions,
  bodyMeasurements: input.bodyMeasurements,
);

class GymHistoryPage extends StatefulWidget {
  const GymHistoryPage({
    required this.sessions,
    required this.onOpen,
    this.bodyMeasurements = const [],
    super.key,
  });

  final List<GymSession> sessions;
  final ValueChanged<GymSession> onOpen;
  final List<BodyMeasurement> bodyMeasurements;

  @override
  State<GymHistoryPage> createState() => _GymHistoryPageState();
}

class _GymHistoryPageState extends State<GymHistoryPage> {
  late Future<GymProgressHistory> _history = _loadHistory();
  var _progress = false;
  GymProgressKey? _selected;
  GymProgressMetric? _metric;
  var _weightUnit = WorkoutWeightUnit.kilograms;
  var _weightChanged = false;

  Future<GymProgressHistory> _loadHistory() {
    final input = (
      sessions: widget.sessions,
      bodyMeasurements: widget.bodyMeasurements,
    );
    return input.sessions.length + input.bodyMeasurements.length > 256
        ? compute(_projectHistory, input)
        : SynchronousFuture(_projectHistory(input));
  }

  @override
  void initState() {
    super.initState();
    readWorkoutWeightUnit().then((unit) {
      if (mounted && !_weightChanged) setState(() => _weightUnit = unit);
    });
  }

  @override
  void didUpdateWidget(covariant GymHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.sessions, oldWidget.sessions) ||
        !identical(widget.bodyMeasurements, oldWidget.bodyMeasurements)) {
      _history = _loadHistory();
    }
  }

  Future<void> _selectSeries(
    List<GymProgressSeries> available,
    GymProgressSeries selected,
  ) async {
    final choice = await showDialog<GymProgressKey>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 450, maxHeight: 420),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: available.length + 1,
            separatorBuilder: (_, index) => index == 0
                ? const SizedBox.shrink()
                : const Divider(indent: 16, endIndent: 16),
            itemBuilder: (_, index) {
              if (index == 0) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Text(
                    'Choose a record',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                );
              }
              final series = available[index - 1];
              return ListTile(
                title: Text(series.title),
                subtitle: series.context == null ? null : Text(series.context!),
                selected: series.key == selected.key,
                onTap: () => Navigator.of(context).pop(series.key),
              );
            },
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _selected = choice;
      _metric = null;
    });
  }

  Widget _sections(bool showProgress) => Wrap(
    spacing: 7,
    runSpacing: 4,
    children: [
      ChoiceChip(
        label: const Text('Sessions'),
        selected: !showProgress,
        showCheckmark: false,
        onSelected: (_) => setState(() => _progress = false),
      ),
      ChoiceChip(
        label: const Text('Progress'),
        selected: showProgress,
        showCheckmark: false,
        onSelected: (_) => setState(() => _progress = true),
      ),
    ],
  );

  Widget _sessions(GymProgressHistory data) {
    final records = data.sessions;
    if (records.isEmpty) {
      return const Center(child: Text('No workout entries yet.'));
    }
    return ListView.separated(
      key: const PageStorageKey('gym-history-sessions'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
      itemCount: records.length + (data.series.isEmpty ? 0 : 1),
      separatorBuilder: (_, index) => index == 0 && data.series.isNotEmpty
          ? const SizedBox(height: 10)
          : const Divider(),
      itemBuilder: (context, index) {
        if (data.series.isNotEmpty && index == 0) return _sections(false);
        final session = records[index - (data.series.isEmpty ? 0 : 1)];
        final labels = MaterialLocalizations.of(context);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 5,
          ),
          title: Text(
            session.planned || session.exercises.isNotEmpty
                ? session.workoutTitle
                : session.entries.firstOrNull?.title ?? session.workoutTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(labels.formatFullDate(session.startedAt.toLocal())),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => widget.onOpen(session),
        );
      },
    );
  }

  Widget _records(GymProgressHistory data) {
    final available = data.series;
    final selected =
        available.where((item) => item.key == _selected).firstOrNull ??
        available.first;
    final metrics = selected.metrics;
    final metric = metrics.contains(_metric) ? _metric! : metrics.first;
    final trend = selected.trendFor(metric);
    final chooseMetric = trend.canChart && metrics.length > 1;
    final showWeightUnit = metrics.any((item) => item.isWeight);
    final colors = Theme.of(context).colorScheme;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.sessions.isNotEmpty) ...[
          _sections(true),
          const SizedBox(height: 14),
        ],
        if (available.length > 1)
          OutlinedButton(
            onPressed: () => _selectSeries(available, selected),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(selected.title)),
                const SizedBox(width: 6),
                const Icon(Icons.expand_more_rounded, size: 19),
              ],
            ),
          )
        else
          Text(selected.title, style: Theme.of(context).textTheme.titleLarge),
        if (selected.context case final label?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 6),
        if (chooseMetric || showWeightUnit)
          Wrap(
            spacing: 7,
            runSpacing: 3,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (chooseMetric)
                PopupMenuButton<GymProgressMetric>(
                  tooltip: 'Chart measure',
                  initialValue: metric,
                  onSelected: (value) => setState(() => _metric = value),
                  itemBuilder: (_) => [
                    for (final choice in metrics)
                      PopupMenuItem(value: choice, child: Text(choice.label)),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(metric.label)),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more_rounded, size: 17),
                      ],
                    ),
                  ),
                ),
              if (showWeightUnit)
                WorkoutWeightUnitMenu(
                  unit: _weightUnit,
                  onSelected: (unit) {
                    setState(() {
                      _weightChanged = true;
                      _weightUnit = unit;
                    });
                    rememberWorkoutWeightUnit(unit);
                  },
                ),
            ],
          ),
        if (trend.canChart)
          _ProgressChart(trend: trend, metric: metric, weightUnit: _weightUnit),
        const SizedBox(height: 16),
        Text('Records', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 7),
        const Divider(),
      ],
    );
    return ListView.separated(
      key: PageStorageKey(('gym-history-progress', selected.key)),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
      itemCount: selected.records.length + 1,
      itemBuilder: (context, index) => index == 0
          ? header
          : _ProgressRecordTile(
              row: selected.records[index - 1],
              weightUnit: _weightUnit,
              onOpen: widget.onOpen,
            ),
      separatorBuilder: (_, index) =>
          index == 0 ? const SizedBox.shrink() : const Divider(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Workout history', overflow: TextOverflow.ellipsis),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 670),
          child: FutureBuilder<GymProgressHistory>(
            future: _history,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: TextButton(
                    onPressed: () => setState(() => _history = _loadHistory()),
                    child: const Text('Reload workout history'),
                  ),
                );
              }
              final data = snapshot.data;
              if (snapshot.connectionState != ConnectionState.done ||
                  data == null) {
                return const Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Loading workout history',
                  ),
                );
              }
              final progress =
                  data.series.isNotEmpty &&
                  (_progress || data.sessions.isEmpty);
              return progress ? _records(data) : _sessions(data);
            },
          ),
        ),
      ),
    ),
  );
}

class _ProgressRecordTile extends StatelessWidget {
  const _ProgressRecordTile({
    required this.row,
    required this.weightUnit,
    required this.onOpen,
  });

  final GymProgressRecord row;
  final WorkoutWeightUnit weightUnit;
  final ValueChanged<GymSession> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labels = MaterialLocalizations.of(context);
    final date = row.at.toLocal();
    final measurement = row.measurement;
    final cardio = row.confirmedCardio;
    final sets = row.confirmedSets;
    final session = row.session;
    final details = <String>[
      if (row.confirmed == 0)
        if (row.skipped > 0 && row.unconfirmed == 0)
          'Skipped'
        else if (row.skipped == 0)
          'Unconfirmed',
      if (cardio != null) ...[
        '${_decimal(cardio.distanceKm)} km',
        '${cardio.minutes} min',
        '${_decimal(cardio.inclinePercent)}% incline',
      ],
      for (final set in sets.take(3))
        '${_metricText(set.weightKg, GymProgressMetric.heaviestSet, weightUnit)} × ${set.reps}',
      if (sets.length > 3) '+${sets.length - 3} sets',
      if (row.skipped > 0 && (row.confirmed > 0 || row.unconfirmed > 0))
        '${row.skipped} skipped',
      if (row.unconfirmed > 0 && (row.confirmed > 0 || row.skipped > 0))
        '${row.unconfirmed} unconfirmed',
    ];
    final title = measurement == null
        ? labels.formatFullDate(date)
        : _metricText(
            measurement.baseValue,
            GymProgressMetric.bodyWeight,
            weightUnit,
          );
    final subtitle = measurement == null
        ? details.join(' · ')
        : '${labels.formatFullDate(date)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    return InkWell(
      onTap: session == null ? null : () => onOpen(session),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (session != null)
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

String _decimal(num value) {
  if (value is int) return '$value';
  return value.toString().replaceFirst(RegExp(r'\.0$'), '');
}

String _metricText(
  num value,
  GymProgressMetric metric,
  WorkoutWeightUnit unit,
) => switch (metric) {
  GymProgressMetric.heaviestSet ||
  GymProgressMetric.bodyWeight => _weightText(value.toDouble(), unit),
  GymProgressMetric.mostReps => '$value reps',
  GymProgressMetric.distance => '${_decimal(value)} km',
  GymProgressMetric.duration => '$value min',
};

String _weightText(double value, WorkoutWeightUnit unit) {
  final converted = unit.fromKilograms(value);
  if (!converted.isFinite) return '${_decimal(value)} kg';
  final valueText = converted > 0 && converted < 0.005
      ? converted.toStringAsPrecision(3)
      : workoutWeightText(value, unit);
  return '$valueText ${unit.symbol}';
}

class _ProgressChart extends StatelessWidget {
  const _ProgressChart({
    required this.trend,
    required this.metric,
    required this.weightUnit,
  });

  final GymProgressTrend trend;
  final GymProgressMetric metric;
  final WorkoutWeightUnit weightUnit;

  @override
  Widget build(BuildContext context) {
    final points = trend.points;
    final colors = Theme.of(context).colorScheme;
    final labels = MaterialLocalizations.of(context);
    final style = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    var low = points.first.value;
    var high = low;
    for (final point in points.skip(1)) {
      low = math.min(low, point.value);
      high = math.max(high, point.value);
    }
    final first = points.first.at.toLocal();
    final last = points.last.at.toLocal();
    String date(DateTime at) => DateUtils.isSameDay(first, last)
        ? labels.formatTimeOfDay(
            TimeOfDay.fromDateTime(at),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          )
        : labels.formatShortDate(at);
    final firstLabel = date(first);
    final lastLabel = date(last);
    final lowLabel = _metricText(low, metric, weightUnit);
    final highLabel = _metricText(high, metric, weightUnit);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              Text(
                'Latest ${_metricText(points.last.value, metric, weightUnit)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (trend.valueCount > points.length)
                Text(
                  '${points.length} of ${trend.valueCount} values',
                  style: style,
                ),
            ],
          ),
          const SizedBox(height: 7),
          Semantics(
            image: true,
            label:
                '${metric.label} chart. $firstLabel to $lastLabel. Range $lowLabel to $highLabel.',
            child: SizedBox(
              key: const ValueKey('gym-trend-chart'),
              width: double.infinity,
              height: 94,
              child: CustomPaint(
                painter: _TrendPainter(
                  points: points,
                  low: low,
                  high: high,
                  stroke: colors.primary,
                  grid: colors.outlineVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Wrap(
            spacing: 10,
            runSpacing: 2,
            children: [
              Text('$firstLabel – $lastLabel', style: style),
              if (low != high) Text('$lowLabel – $highLabel', style: style),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.points,
    required this.low,
    required this.high,
    required this.stroke,
    required this.grid,
  });

  final List<GymTrendPoint> points;
  final num low;
  final num high;
  final Color stroke;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 4.0;
    final width = math.max(0.0, size.width - inset * 2);
    final height = math.max(0.0, size.height - inset * 2);
    final guide = Paint()..color = grid;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = inset + height * fraction;
      canvas.drawLine(Offset(inset, y), Offset(inset + width, y), guide);
    }
    final pathPaint = Paint()
      ..color = stroke
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()..color = stroke;
    final first = points.first.at;
    final last = points.last.at;
    final useMicros =
        first.millisecondsSinceEpoch == last.millisecondsSinceEpoch;
    int clock(DateTime point) =>
        useMicros ? point.microsecondsSinceEpoch : point.millisecondsSinceEpoch;
    final start = clock(first);
    final range = clock(last) - start;
    Offset? previous;
    for (final point in points) {
      final x = width * ((clock(point.at) - start) / range);
      final y = high == low ? 0.5 : (high - point.value) / (high - low);
      final offset = Offset(inset + x, inset + height * y);
      if (previous != null && !point.startsSegment) {
        canvas.drawLine(previous, offset, pathPaint);
      }
      canvas.drawCircle(offset, 2.7, dotPaint);
      previous = offset;
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points ||
      old.low != low ||
      old.high != high ||
      old.stroke != stroke ||
      old.grid != grid;
}
