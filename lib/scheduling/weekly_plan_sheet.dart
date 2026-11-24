import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import '../calendar_page.dart';
import '../task_model.dart';
import '../ui_theme.dart';
import 'availability_settings.dart';
import 'planner.dart';
import 'weekly_planner.dart';

class WeeklyPlanSheet extends StatefulWidget {
  const WeeklyPlanSheet({
    required this.weekStart,
    required this.events,
    required this.tasks,
    this.settings,
    this.categories,
    this.clock,
    super.key,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final SchedulingSettings? settings;
  final Set<String>? categories;
  final DateTime Function()? clock;

  @override
  State<WeeklyPlanSheet> createState() => _WeeklyPlanSheetState();
}

typedef _WeekInput = ({
  DateTime weekStart,
  DateTime notBefore,
  DateTime reservationStart,
  List<CalendarEvent> events,
  List<TaskItem> tasks,
  SchedulingSettings? settings,
  WeeklyPlanHours? hours,
  Set<String>? categories,
  Set<String>? taskIds,
});

WeeklyPlanPreview? _previewWeek(_WeekInput input) => planWorkspaceWeek(
  weekStart: input.weekStart,
  notBefore: input.notBefore,
  reservationStart: input.reservationStart,
  events: input.events,
  tasks: input.tasks,
  settings: input.settings,
  hours: input.hours,
  categories: input.categories,
  taskIds: input.taskIds,
);

typedef _ReviewBlock = ({ScheduledTask task, TimeSpan span, int index});

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _WeeklyPlanSheetState extends State<WeeklyPlanSheet> {
  final _weekdaysSelected = <int>{1, 2, 3, 4, 5};
  final _selected = <String>{};
  TimeOfDay _from = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _until = const TimeOfDay(hour: 17, minute: 0);
  WeeklyPlanPreview? _preview;
  Set<String>? _taskIds;
  bool _loading = false;
  String? _error;

  DateTime get _week => DateUtils.dateOnly(widget.weekStart.toLocal());
  bool get _usesSavedHours => hasSavedWeeklyHours(widget.settings);

  void _reset() {
    _preview = null;
    _selected.clear();
    _error = null;
  }

  List<TaskItem> get _objectives => [
    for (final task in widget.tasks)
      if (!task.done && (widget.categories?.contains(task.category) ?? true))
        task,
  ];

  Future<void> _chooseObjectives() async {
    final tasks = _objectives;
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _WeekObjectives(tasks: tasks, selected: _taskIds),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      _taskIds = chosen.length == tasks.length
          ? null
          : Set.unmodifiable(chosen);
      _reset();
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: start ? _from : _until,
      helpText: start ? 'Set start time' : 'Set end time',
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (start) {
        _from = picked;
      } else {
        _until = picked;
      }
      _reset();
    });
  }

  Future<void> _previewPlan() async {
    if (_loading || _taskIds?.isEmpty == true) return;
    WeeklyPlanHours? hours;
    if (!_usesSavedHours) {
      final start = _from.hour * 60 + _from.minute;
      final end = _until.hour * 60 + _until.minute;
      if (_weekdaysSelected.isEmpty || end <= start) {
        setState(
          () => _error = _weekdaysSelected.isEmpty
              ? 'Choose at least one available day.'
              : 'End time must be after start time.',
        );
        return;
      }
      hours = WeeklyPlanHours(
        weekdays: _weekdaysSelected,
        startMinute: start,
        endMinute: end,
      );
    }
    final now = (widget.clock ?? DateTime.now)().toLocal();
    final nextQuarter = DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ 900000 + 1) * 900000,
    );
    setState(() {
      _loading = true;
      _reset();
    });
    try {
      final preview = await compute(_previewWeek, (
        weekStart: _week,
        notBefore: nextQuarter,
        reservationStart: now,
        events: widget.events,
        tasks: widget.tasks,
        settings: widget.settings,
        hours: hours,
        categories: widget.categories,
        taskIds: _taskIds,
      ));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _preview = preview;
        if (preview == null) {
          _error = 'This week has no remaining time.';
        } else {
          _selected.addAll(
            preview.proposal.scheduled.map((item) => item.task.id),
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not preview the week. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final last = DateTime(_week.year, _week.month, _week.day + 6);
    final pending = _preview;
    final scheduled = pending?.proposal.scheduled ?? const <ScheduledTask>[];
    final selection = pending?.select(_selected);
    final missingPrerequisite =
        pending != null && _selected.isNotEmpty && selection == null;
    final blocks = _orderedBlocks(scheduled);
    final availableAction = pending == null || scheduled.isNotEmpty;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 555,
          maxHeight: MediaQuery.sizeOf(context).height * .86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(18, 14, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            'Plan week',
                            style: sectionHeadingStyle.copyWith(
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${locale.formatShortDate(_week)} – ${locale.formatShortDate(last)}',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close plan',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: CustomScrollView(
                shrinkWrap: true,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsetsDirectional.fromSTEB(18, 7, 18, 4),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (pending == null) _hours(context),
                          if (pending == null && _objectives.isNotEmpty)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Objectives'),
                              subtitle: Text(switch (_taskIds?.length) {
                                null => 'All eligible tasks',
                                0 => 'No tasks selected',
                                1 => '1 task selected',
                                final count => '$count tasks selected',
                              }),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: _loading ? null : _chooseObjectives,
                            ),
                          if (_error case final error?)
                            Padding(
                              padding: const EdgeInsets.only(top: 9),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  error,
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                            ),
                          if (pending != null) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    scheduled.isEmpty
                                        ? 'No tasks fit this week.'
                                        : '${_formatDuration(_minutes(scheduled.where((item) => _selected.contains(item.task.id))))} selected',
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => setState(_reset),
                                  child: const Text('Start over'),
                                ),
                              ],
                            ),
                            for (final advisory in pending.proposal.advisories)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Text(
                                  advisory,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.builder(
                      itemCount: blocks.length,
                      itemBuilder: (context, index) {
                        final block = blocks[index];
                        final startsDay =
                            index == 0 ||
                            !DateUtils.isSameDay(
                              block.span.start.toLocal(),
                              blocks[index - 1].span.start.toLocal(),
                            );
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (startsDay)
                              Padding(
                                padding: const EdgeInsetsDirectional.fromSTEB(
                                  8,
                                  15,
                                  8,
                                  2,
                                ),
                                child: Semantics(
                                  header: true,
                                  child: Text(
                                    locale.formatMediumDate(
                                      block.span.start.toLocal(),
                                    ),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: colors.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                            _blockRow(context, block),
                          ],
                        );
                      },
                    ),
                  ),
                  if (pending != null &&
                      pending.proposal.unscheduled.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 5,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _unscheduled(pending.proposal.unscheduled),
                      ),
                    ),
                ],
              ),
            ),
            if (availableAction) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(18, 9, 18, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (missingPrerequisite)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Semantics(
                          liveRegion: true,
                          child: const Text(
                            'Select the prerequisite tasks first.',
                          ),
                        ),
                      ),
                    FilledButton(
                      onPressed: pending == null
                          ? (_loading || _taskIds?.isEmpty == true
                                ? null
                                : _previewPlan)
                          : (selection == null
                                ? null
                                : () => Navigator.pop(context, selection)),
                      child: Text(
                        pending == null
                            ? (_loading ? 'Previewing…' : 'Preview week')
                            : 'Add selected tasks',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hours(BuildContext context) {
    if (_usesSavedHours) return const Text('Uses your saved availability.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Available days'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (var offset = 0; offset < 7; offset++)
              _weekday(
                DateTime(_week.year, _week.month, _week.day + offset).weekday,
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.settings?.timeZoneId case final zone?)
          Text('Hours in $zone'),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _loading ? null : () => _pickTime(start: true),
                child: Text(
                  'From ${_formatTime(context, _from)}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _loading ? null : () => _pickTime(start: false),
                child: Text(
                  'Until ${_formatTime(context, _until)}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _weekday(int weekday) => FilterChip(
    label: Text(_weekdays[weekday - 1]),
    showCheckmark: false,
    selected: _weekdaysSelected.contains(weekday),
    onSelected: _loading
        ? null
        : (selected) => setState(() {
            if (selected) {
              _weekdaysSelected.add(weekday);
            } else {
              _weekdaysSelected.remove(weekday);
            }
            _reset();
          }),
  );

  Widget _blockRow(BuildContext context, _ReviewBlock block) {
    final item = block.task;
    final id = item.task.id;
    final start = block.span.start.toLocal();
    final end = block.span.end.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final endDate = DateUtils.isSameDay(start, end)
        ? ''
        : ' ${localizations.formatMediumDate(end)}';
    final times =
        '${_formatTime(context, TimeOfDay.fromDateTime(start))}–${_formatTime(context, TimeOfDay.fromDateTime(end))}$endDate';
    final split = item.blocks.length > 1
        ? ' · Block ${block.index + 1} of ${item.blocks.length}'
        : '';
    return CheckboxListTile(
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      value: _selected.contains(id),
      title: Text(
        item.task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$times$split'),
      onChanged: (include) => setState(() {
        if (include == true) {
          _selected.add(id);
        } else {
          _selected.remove(id);
        }
      }),
    );
  }

  Widget _unscheduled(List<UnscheduledTask> tasks) {
    final titles = {for (final task in widget.tasks) task.id: task.title};
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('Unscheduled · ${tasks.length}'),
      children: [
        for (final entry in tasks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.task.title),
            subtitle: Text(switch (entry.problem) {
              PlannerProblem.needsDuration => 'Add an estimated duration',
              PlannerProblem.needsDetails => 'Needs more details',
              PlannerProblem.unavailableDependency =>
                switch (titles[entry.prerequisiteId]) {
                  final title? => 'Waiting on $title',
                  null => 'Prerequisite unavailable',
                },
              PlannerProblem.dependencyCycle => 'Prerequisite cycle',
              PlannerProblem.deadlinePassed => 'Due before this window',
              PlannerProblem.noFeasibleTime => 'No available block fits',
            }),
          ),
      ],
    );
  }
}

class _WeekObjectives extends StatefulWidget {
  const _WeekObjectives({required this.tasks, required this.selected});

  final List<TaskItem> tasks;
  final Set<String>? selected;

  @override
  State<_WeekObjectives> createState() => _WeekObjectivesState();
}

class _WeekObjectivesState extends State<_WeekObjectives> {
  late final _selected =
      widget.selected?.toSet() ?? {for (final task in widget.tasks) task.id};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final visible = widget.tasks
        .where((task) => task.title.toLowerCase().contains(_query))
        .toList();
    final available =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final allSelected = _selected.length == widget.tasks.length;
    final locale = MaterialLocalizations.of(context);
    return AlertDialog(
      title: const Text('Choose objectives'),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 6),
      content: SizedBox(
        width: 362,
        height: (available * .48).clamp(110, 340).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.tasks.length > 8)
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Find a task',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            TextButton(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected.addAll(widget.tasks.map((task) => task.id));
                }
              }),
              child: Text(allSelected ? 'Clear selection' : 'Select all tasks'),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('No matching tasks.'))
                  : ListView.builder(
                      primary: false,
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final task = visible[index];
                        final details = [
                          if (task.date case final date?)
                            locale.formatMediumDate(date.toLocal()),
                          if (task.estimatedMinutes case final effort?
                              when effort > 0)
                            _formatDuration(effort)
                          else
                            'Needs estimate',
                        ];
                        return CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            task.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(details.join(' · ')),
                          value: _selected.contains(task.id),
                          onChanged: (selected) => setState(() {
                            if (selected == true) {
                              _selected.add(task.id);
                            } else {
                              _selected.remove(task.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, Set<String>.unmodifiable(_selected)),
          child: const Text('Use objectives'),
        ),
      ],
    );
  }
}

List<_ReviewBlock> _orderedBlocks(Iterable<ScheduledTask> tasks) =>
    <_ReviewBlock>[
      for (final task in tasks)
        for (final (index, span) in task.blocks.indexed)
          (task: task, span: span, index: index),
    ]..sort((a, b) => a.span.start.compareTo(b.span.start));

String _formatTime(BuildContext context, TimeOfDay value) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      value,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

int _minutes(Iterable<ScheduledTask> tasks) => tasks
    .expand((task) => task.blocks)
    .fold(0, (minutes, span) => minutes + span.length.inMinutes);

String _formatDuration(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes % 60 == 0) return '${minutes ~/ 60} h';
  return '${minutes ~/ 60} h ${minutes % 60} min';
}
