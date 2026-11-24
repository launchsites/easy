import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import '../workspace_data.dart' show spaceName;
import 'duration_learning.dart';
import 'insight_models.dart';
import 'insight_report.dart';

typedef InsightExport = Future<bool> Function(
  String suggestedName,
  String data,
);

class InsightsPage extends StatefulWidget {
  const InsightsPage({
    required this.activities,
    required this.tasks,
    this.plans = const [],
    this.onExportJson,
    this.initialDay,
    this.clock,
    super.key,
  });

  final List<InsightActivity> activities;
  final List<InsightTask> tasks;
  final List<InsightPlan> plans;
  final InsightExport? onExportJson;
  final DateTime? initialDay;
  final DateTime Function()? clock;

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

enum _Period {
  month(30, '30 days'),
  quarter(90, '90 days'),
  year(365, '1 year');

  const _Period(this.days, this.label);
  final int days;
  final String label;
}

typedef _InsightRequest = ({
  InsightRange range,
  List<InsightActivity> activities,
  List<InsightTask> tasks,
  List<InsightPlan> plans,
  String? category,
});

InsightReport _report(_InsightRequest request) => buildInsightReport(
  range: request.range,
  activities: request.activities,
  tasks: request.tasks,
  plans: request.plans,
  category: request.category,
);

class _InsightsPageState extends State<InsightsPage> {
  late DateTime _last = insightDay(
    widget.initialDay ?? (widget.clock ?? DateTime.now)().toLocal(),
  );
  late DateTime _selected = _last;
  var _period = _Period.quarter;
  String? _scope;
  late Future<InsightReport> _pending = _load();
  late List<String> _categories = _discoverCategories();
  int _request = 0;
  Future<void> _worker = Future.value();

  InsightRange get _range => InsightRange(
    shiftInsightDay(_last, 1 - _period.days),
    shiftInsightDay(_last, 1),
  );

  Future<InsightReport> _load() {
    final generation = ++_request;
    final request = (
      range: _range,
      activities: widget.activities,
      tasks: widget.tasks,
      plans: widget.plans,
      category: _scope,
    );
    if (widget.activities.length + widget.tasks.length + widget.plans.length <
        128) {
      return Future.sync(() => _report(request));
    }
    final pending = _worker.then((_) {
      if (!mounted || generation != _request) {
        throw StateError('The selected insight period has changed.');
      }
      return compute(_report, request, debugLabel: 'Workspace insights');
    });
    _worker = pending.then<void>((_) {}, onError: (Object _) {});
    return pending;
  }

  @override
  void didUpdateWidget(covariant InsightsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.activities, widget.activities) ||
        !listEquals(oldWidget.tasks, widget.tasks) ||
        !listEquals(oldWidget.plans, widget.plans)) {
      _categories = _discoverCategories();
      _pending = _load();
    }
  }

  List<String> _discoverCategories() => {
    ...widget.activities.map((entry) => entry.category),
    ...widget.tasks.map((entry) => entry.category),
    ...widget.plans.map((entry) => entry.category),
  }.toList()..sort();

  void _changePeriod(_Period value) => setState(() {
    _period = value;
    if (!_range.contains(_selected)) _selected = _range.start;
    _pending = _load();
  });

  void _changeScope(String? category) => setState(() {
    _scope = category;
    _pending = _load();
  });

  Future<void> _chooseDate({required bool period}) async {
    final scope = _range;
    final picked = await showDatePicker(
      context: context,
      initialDate: period ? _last : _selected,
      firstDate: period
          ? DateTime(_last.year < 1900 ? _last.year : 1900)
          : scope.start,
      lastDate: period
          ? DateTime(_last.year > 2200 ? _last.year : 2200, 12, 31)
          : _last,
      helpText: period ? 'Choose last day' : 'Choose a day',
    );
    if (!mounted || picked == null) return;
    setState(() {
      _selected = insightDay(picked);
      if (period) {
        _last = _selected;
        _pending = _load();
      }
    });
  }

  Future<void> _export(InsightReport report) async {
    final callback = widget.onExportJson;
    if (callback == null) return;
    try {
      if (await callback(
            'Easy Insights ${insightDayKey(_last)}.json',
            const JsonEncoder.withIndent('  ').convert(report.toJson()),
          ) &&
          mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Insights exported.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Insights could not be exported.')),
        );
      }
    }
  }

  Future<void> _openLearning() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _DurationDialog(
        tasks: [
          for (final task in widget.tasks)
            if (_scope == null || task.category == _scope) task,
        ],
        activities: widget.activities,
        onExportJson: widget.onExportJson,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InsightReport>(
      future: _pending,
      builder: (context, state) {
        final report = state.connectionState == ConnectionState.done
            ? state.data
            : null;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Insights'),
            actions: [
              if (widget.onExportJson != null)
                IconButton(
                  tooltip: 'Export insights JSON',
                  onPressed: report == null ? null : () => _export(report),
                  icon: const Icon(Icons.file_download_outlined),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(22, 6, 22, 30),
                  children: [
                    _controls(context, _categories),
                    if (state.hasError)
                      const Padding(
                        padding: EdgeInsets.only(top: 14),
                        child: Text('Insights could not be calculated.'),
                      )
                    else if (report == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 20),
                        child: LinearProgressIndicator(minHeight: 2),
                      )
                    else ...[
                      _ActivityChart(
                        report: report,
                        selected: _selected,
                        onSelect: (day) => setState(() => _selected = day),
                      ),
                      _dayDetails(report),
                      _metrics(report),
                    ],
                    if (widget.tasks.isNotEmpty)
                      _InsightsSection(
                        title: 'Duration evidence',
                        children: [
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: OutlinedButton(
                              onPressed: _openLearning,
                              child: const Text('Find a comparable task'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _controls(BuildContext context, List<String> categories) {
    final labels = MaterialLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 7,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PopupMenuButton<_Period>(
          tooltip: 'Change insight period',
          initialValue: _period,
          onSelected: _changePeriod,
          itemBuilder: (_) => [
            for (final period in _Period.values)
              PopupMenuItem(value: period, child: Text(period.label)),
          ],
          child: _FilterLabel(_period.label),
        ),
        if (categories.isNotEmpty)
          PopupMenuButton<({String? category})>(
            tooltip: 'Filter insights by category',
            initialValue: (category: _scope),
            onSelected: (choice) => _changeScope(choice.category),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: (category: null),
                child: Text('All categories'),
              ),
              for (final category in categories)
                PopupMenuItem(
                  value: (category: category),
                  child: Text(
                    spaceName(category),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            child: _FilterLabel(
              _scope == null ? 'All categories' : spaceName(_scope!),
            ),
          ),
        TextButton.icon(
          onPressed: () => _chooseDate(period: true),
          icon: const Icon(Icons.calendar_today_outlined, size: 16),
          label: Text('To ${labels.formatMediumDate(_last)}'),
        ),
      ],
    );
  }

  Widget _dayDetails(InsightReport report) {
    final localizations = MaterialLocalizations.of(context);
    final day = report.days[insightDayKey(_selected)];
    final start = shiftInsightDay(
      _selected,
      DateTime.monday - _selected.weekday,
    );
    final categoryTimes = day?.byCategory.entries.toList()
      ?..sort((first, second) => second.value.compareTo(first.value));
    return _InsightsSection(
      title: 'Recorded activity',
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => _chooseDate(period: false),
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(localizations.formatFullDate(_selected)),
          ),
        ),
        if (day == null)
          const Text(
            'No activity logged for this date.',
            style: contentMetadataStyle,
          )
        else ...[
          Text(
            '${_timeLabel(day.actual)} logged · ${day.activityCount} ${day.activityCount == 1 ? 'activity' : 'activities'}',
            style: contentMetadataStyle,
          ),
          for (final entry in categoryTimes!)
            _InsightRow(
              label: spaceName(entry.key),
              value: _timeLabel(entry.value),
            ),
        ],
        ExpansionTile(
          key: PageStorageKey(('activity-week', insightDayKey(start))),
          tilePadding: EdgeInsets.zero,
          title: const Text('Week around this date', style: contentTitleStyle),
          children: [
            for (var offset = 0; offset < 7; offset++)
              if (shiftInsightDay(start, offset) case final date
                  when report.range.contains(date))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(localizations.formatMediumDate(date)),
                  trailing: Text(switch (report.days[insightDayKey(date)]) {
                    final active? => _timeLabel(active.actual),
                    null => 'No log',
                  }, style: contentMetadataStyle),
                  onTap: () => setState(() => _selected = date),
                ),
          ],
        ),
      ],
    );
  }

  Widget _metrics(InsightReport report) => _InsightsSection(
    title: 'Task and plan history',
    children: [
      _InsightRow(
        label: 'Confirmed task completions',
        value: report.completedTasks.toString(),
      ),
      if (report.finishedOnTime.comparable > 0)
        _InsightRow(
          label: 'Completed by deadline',
          value:
              '${report.finishedOnTime.count} of ${report.finishedOnTime.comparable}',
        ),
      if (report.rescheduled.comparable > 0)
        _InsightRow(
          label: 'Plans moved',
          value:
              '${report.rescheduled.count} of ${report.rescheduled.comparable}',
        ),
      if (report.skipped.comparable > 0)
        _InsightRow(
          label: 'Plans marked skipped',
          value: '${report.skipped.count} of ${report.skipped.comparable}',
        ),
      if (report.durationForecastError.median case final error?)
        _InsightRow(
          label: 'Median duration forecast error',
          value:
              '${_timeLabel(error)} · ${_samples(report.durationForecastError.sampleSize)}',
        ),
      if (report.initialStartDelay.median case final delay?)
        _InsightRow(
          label: 'Median start vs initial plan',
          value:
              '${_difference(delay, positive: 'later', negative: 'earlier')} · ${_samples(report.initialStartDelay.sampleSize)}',
        ),
      if (report.acceptedDurationDelta.median case final delta?)
        _InsightRow(
          label: 'Median duration vs accepted plan',
          value:
              '${_difference(delta, positive: 'more', negative: 'less')} · ${_samples(report.acceptedDurationDelta.sampleSize)}',
        ),
      if (report.adherence.value case final fraction?)
        _InsightRow(
          label: 'Accepted time used',
          value:
              '${(fraction * 100).round()}% · ${_samples(report.adherence.sampleSize)}',
        ),
    ],
  );
}

String _difference(
  Duration duration, {
  required String positive,
  required String negative,
}) {
  if (duration == Duration.zero) return 'As planned';
  return '${_timeLabel(duration.abs())} ${duration.isNegative ? negative : positive}';
}

String _samples(int count) => '$count ${count == 1 ? 'sample' : 'samples'}';

String _timeLabel(Duration time) {
  if (time.inMinutes == 0) return time == Duration.zero ? '0 min' : '<1 min';
  final minutes = time.inMinutes % 60;
  if (time.inHours == 0) return '$minutes min';
  return minutes == 0 ? '${time.inHours} h' : '${time.inHours} h $minutes min';
}

class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    ),
  );
}

class _InsightsSection extends StatelessWidget {
  const _InsightsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 21),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text(title, style: sectionHeadingStyle)),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.maxWidth < 430 ||
            MediaQuery.textScalerOf(context).scale(14) > 18;
        final name = Text(label, style: contentTitleStyle);
        final result = Text(value, style: contentMetadataStyle);
        return narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [name, result],
              )
            : Row(
                children: [
                  Expanded(child: name),
                  const SizedBox(width: 10),
                  result,
                ],
              );
      },
    ),
  );
}

class _ActivityChart extends StatefulWidget {
  const _ActivityChart({
    required this.report,
    required this.selected,
    required this.onSelect,
  });

  final InsightReport report;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  State<_ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<_ActivityChart> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final total = report.actual;
    if (total == null) {
      return const _InsightsSection(
        title: 'Logged time',
        children: [
          Text(
            'No confirmed activity in this period.',
            style: contentMetadataStyle,
          ),
        ],
      );
    }
    final start = shiftInsightDay(
      report.range.start,
      DateTime.monday - report.range.start.weekday,
    );
    final weeks = (report.range.days + report.range.start.weekday - 1 + 6) ~/ 7;
    return _InsightsSection(
      title: 'Logged time',
      children: [
        Text(
          '${_timeLabel(total)} across ${report.days.length} of ${report.range.days} days',
          style: contentMetadataStyle,
        ),
        const SizedBox(height: 11),
        Scrollbar(
          controller: _controller,
          child: SingleChildScrollView(
            controller: _controller,
            reverse: true,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var column = 0; column < weeks; column++)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var row = 0; row < 7; row++)
                        _cell(shiftInsightDay(start, column * 7 + row)),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('No log', style: contentMetadataStyle),
            for (final color in _intensity)
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            const Text('4 h+', style: contentMetadataStyle),
          ],
        ),
      ],
    );
  }

  Widget _cell(DateTime day) {
    final report = widget.report;
    final included = report.range.contains(day);
    final key = insightDayKey(day);
    final active = report.days[key];
    final selected = insightDayKey(widget.selected) == key;
    final color = switch (active?.actual.inMinutes) {
      null => _intensity[0],
      < 30 => _intensity[1],
      < 60 => _intensity[2],
      < 120 => _intensity[3],
      < 240 => _intensity[4],
      _ => _intensity[5],
    };
    final label = MaterialLocalizations.of(context).formatFullDate(day);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: SizedBox(
        width: 15,
        height: 15,
        child: included
            ? Semantics(
                label:
                    '$label, ${active == null ? 'no activity logged' : _timeLabel(active.actual)}',
                button: true,
                selected: selected,
                onTap: () => widget.onSelect(day),
                child: GestureDetector(
                  excludeFromSemantics: true,
                  onTap: () => widget.onSelect(day),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(3),
                      border: selected
                          ? Border.all(color: ink, width: 1.6)
                          : null,
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  static const _intensity = [
    line,
    Color(0xffcbd6c5),
    Color(0xffa6b9a1),
    Color(0xff809f7b),
    Color(0xff5c8259),
    Color(0xff385e3b),
  ];
}

typedef _LearningRequest = ({
  List<InsightTask> tasks,
  List<InsightActivity> activities,
});

List<DurationObservation> _observations(_LearningRequest input) =>
    buildDurationObservations(tasks: input.tasks, activities: input.activities);

class _DurationDialog extends StatefulWidget {
  const _DurationDialog({
    required this.tasks,
    required this.activities,
    this.onExportJson,
  });

  final List<InsightTask> tasks;
  final List<InsightActivity> activities;
  final InsightExport? onExportJson;

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog> {
  late final _pending = _load();
  String _query = '';
  InsightTask? _task;
  LearnedDuration? _result;

  Future<List<DurationObservation>> _load() {
    final request = (tasks: widget.tasks, activities: widget.activities);
    return widget.tasks.length + widget.activities.length < 128
        ? Future.sync(() => _observations(request))
        : compute(_observations, request, debugLabel: 'Duration observations');
  }

  Future<void> _export() async {
    final result = _result;
    final callback = widget.onExportJson;
    if (result == null || callback == null) return;
    try {
      if (await callback(
            'duration-evidence.json',
            const JsonEncoder.withIndent('  ')
                .convert({'version': 1, ...result.toJson()}),
          ) &&
          mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Duration evidence exported.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Duration evidence could not be exported.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: SizedBox(
      height: 430,
      width: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Duration evidence', style: sectionHeadingStyle),
                ),
                IconButton(
                  tooltip: 'Close duration evidence',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<DurationObservation>>(
              future: _pending,
              builder: (context, state) {
                if (state.hasError) {
                  return const Center(
                    child: Text('Duration evidence is unavailable.'),
                  );
                }
                final samples = state.data;
                if (samples == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (samples.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                      'Record completed work and link the activity to its task to build evidence.',
                    ),
                  );
                }
                final task = _task;
                if (task != null) return _resultView(task);
                final matches = [
                  for (final item in widget.tasks)
                    if (item.title.toLowerCase().contains(_query)) item,
                ];
                return LayoutBuilder(
                  builder: (context, constraints) => Column(
                    children: [
                      if (constraints.maxHeight > 110)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                          child: TextField(
                            onChanged: (text) => setState(
                              () => _query = text.trim().toLowerCase(),
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Find a task',
                              prefixIcon: Icon(Icons.search_rounded),
                            ),
                          ),
                        ),
                      Expanded(
                        child: matches.isEmpty
                            ? const Center(child: Text('No matching tasks.'))
                            : ListView.builder(
                                itemCount: matches.length,
                                itemBuilder: (context, index) {
                                  final candidate = matches[index];
                                  return ListTile(
                                    title: Text(
                                      candidate.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      spaceName(candidate.category),
                                      style: contentMetadataStyle,
                                    ),
                                    onTap: () {
                                      FocusScope.of(context).unfocus();
                                      setState(() {
                                        _task = candidate;
                                        _result = learnDuration(
                                          candidate,
                                          samples,
                                        );
                                      });
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _resultView(InsightTask task) {
    final result = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      children: [
        Text(task.title, style: contentTitleStyle),
        const SizedBox(height: 11),
        if (result == null)
          const Text(
            'No comparable completed tasks with logged time.',
            style: contentMetadataStyle,
          )
        else ...[
          Text(_timeLabel(result.duration), style: sectionHeadingStyle),
          const SizedBox(height: 5),
          Text(
            '${result.cohort.label} · ${_samples(result.samples)}',
            style: contentMetadataStyle,
          ),
          Text(
            '${result.hasLimitedEvidence ? 'Observed range' : 'Middle half'} ${_timeLabel(result.lower)}–${_timeLabel(result.upper)}',
            style: contentMetadataStyle,
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => setState(() => _task = null),
              child: const Text('Choose another'),
            ),
            if (result != null && widget.onExportJson != null)
              TextButton(
                onPressed: _export,
                child: const Text('Export evidence'),
              ),
          ],
        ),
      ],
    );
  }
}
