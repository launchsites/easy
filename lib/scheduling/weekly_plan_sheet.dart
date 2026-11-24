import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import '../calendar_page.dart';
import '../task_model.dart';
import 'availability_settings.dart';
import 'plan_review_frame.dart';
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

typedef _ReviewBlock = ({ScheduledTask task, TimeSpan span, int index});

typedef _WeekReview = ({
  WeeklyPlanPreview plan,
  List<_ReviewBlock> blocks,
  Map<String, Set<String>> required,
  Map<String, int> minutes,
});

_WeekReview? _previewWeek(_WeekInput input) {
  final preview = planWorkspaceWeek(
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
  if (preview == null) return null;
  return (
    plan: preview,
    blocks: _orderedBlocks(preview.proposal.scheduled),
    required: requiredPlanSelections(preview.proposal),
    minutes: {
      for (final task in preview.proposal.scheduled)
        task.task.id: task.blocks.fold(
          0,
          (minutes, block) => minutes + block.length.inMinutes,
        ),
    },
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _WeeklyPlanSheetState extends State<WeeklyPlanSheet> {
  final _weekdaysSelected = <int>{1, 2, 3, 4, 5};
  final _selected = <String>{};
  TimeOfDay _from = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _until = const TimeOfDay(hour: 17, minute: 0);
  _WeekReview? _preview;
  Set<String>? _taskIds;
  List<TaskItem>? _availableObjectives;
  Map<String, String>? _taskTitles;
  int _selectedMinutes = 0;
  bool _showUnscheduled = false;
  bool _loading = false;
  String? _error;

  DateTime get _week => DateUtils.dateOnly(widget.weekStart.toLocal());
  bool get _usesSavedHours => hasSavedWeeklyHours(widget.settings);

  void _reset() {
    _preview = null;
    _selected.clear();
    _selectedMinutes = 0;
    _showUnscheduled = false;
    _taskTitles = null;
    _error = null;
  }

  List<TaskItem> get _objectives => _availableObjectives ??= [
    for (final task in widget.tasks)
      if (!task.done && (widget.categories?.contains(task.category) ?? true))
        task,
  ];

  Future<void> _chooseObjectives() async {
    final tasks = _objectives;
    final chosen = await showDialog<_ObjectiveSelection>(
      context: context,
      builder: (_) => _WeekObjectives(tasks: tasks, selected: _taskIds),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      _taskIds = chosen.ids;
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
          _selected.addAll(preview.minutes.keys);
          _selectedMinutes = preview.minutes.values.fold(
            0,
            (sum, minutes) => sum + minutes,
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

  void _accept() {
    final selection = _preview?.plan.select(_selected);
    if (selection != null) Navigator.pop(context, selection);
  }

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final last = DateTime(_week.year, _week.month, _week.day + 6);
    final preview = _preview;
    final pending = preview?.plan;
    final scheduled = pending?.proposal.scheduled ?? const <ScheduledTask>[];
    final unscheduled =
        pending?.proposal.unscheduled ?? const <UnscheduledTask>[];
    final titles = _showUnscheduled
        ? (_taskTitles ??= planPrerequisiteTitles(widget.tasks, unscheduled))
        : const <String, String>{};
    final missingPrerequisite =
        preview != null &&
        hasUnselectedPlanPrerequisites(preview.required, _selected);
    final blocks = preview?.blocks ?? const <_ReviewBlock>[];
    final availableAction = pending == null || scheduled.isNotEmpty;
    return PlanReviewFrame(
      title: 'Plan week',
      subtitle:
          '${locale.formatShortDate(_week)} – ${locale.formatShortDate(last)}',
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
                      child: Text(error, style: TextStyle(color: colors.error)),
                    ),
                  ),
                if (pending != null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          scheduled.isEmpty
                              ? 'No tasks fit this week.'
                              : '${_formatDuration(_selectedMinutes)} selected',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      Flexible(
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: () => setState(_reset),
                            child: const Text(
                              'Start over',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  for (final advisory in pending.proposal.advisories)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        advisory,
                        style: TextStyle(color: colors.onSurfaceVariant),
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
                          locale.formatMediumDate(block.span.start.toLocal()),
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
        if (unscheduled.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
            sliver: SliverToBoxAdapter(
              child: Semantics(
                expanded: _showUnscheduled,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Unscheduled · ${unscheduled.length}'),
                  trailing: Icon(
                    _showUnscheduled
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  onTap: () =>
                      setState(() => _showUnscheduled = !_showUnscheduled),
                ),
              ),
            ),
          ),
          if (_showUnscheduled)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              sliver: SliverList.builder(
                itemCount: unscheduled.length,
                itemBuilder: (_, index) =>
                    _unscheduledRow(unscheduled[index], titles),
              ),
            ),
        ],
      ],
      footer: availableAction
          ? Padding(
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
                        : (_selected.isEmpty || missingPrerequisite
                              ? null
                              : _accept),
                    child: Text(
                      pending == null
                          ? (_loading ? 'Previewing…' : 'Preview week')
                          : 'Add selected tasks',
                    ),
                  ),
                ],
              ),
            )
          : null,
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
        final minutes = _preview?.minutes[id] ?? 0;
        if (include == true && _selected.add(id)) {
          _selectedMinutes += minutes;
        } else if (include != true && _selected.remove(id)) {
          _selectedMinutes -= minutes;
        }
      }),
    );
  }

  Widget _unscheduledRow(UnscheduledTask entry, Map<String, String> titles) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          entry.task.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(planningIssueMessage(entry, titles)),
      );
}

typedef _ObjectiveSelection = ({Set<String>? ids});

class _WeekObjectives extends StatefulWidget {
  const _WeekObjectives({required this.tasks, required this.selected});

  final List<TaskItem> tasks;
  final Set<String>? selected;

  @override
  State<_WeekObjectives> createState() => _WeekObjectivesState();
}

class _WeekObjectivesState extends State<_WeekObjectives> {
  late bool _includesByDefault = widget.selected == null;
  late final _exceptions = {...?widget.selected};
  late List<TaskItem> _visible = widget.tasks;
  String _query = '';

  bool _includes(String id) => _includesByDefault != _exceptions.contains(id);

  void _search(String value) {
    final query = value.trim().toLowerCase();
    if (query == _query) return;
    final source = query.startsWith(_query) ? _visible : widget.tasks;
    setState(() {
      _query = query;
      _visible = query.isEmpty
          ? widget.tasks
          : source
                .where((task) => task.title.toLowerCase().contains(query))
                .toList();
    });
  }

  void _accept() {
    final Set<String>? ids;
    if ((_includesByDefault && _exceptions.isEmpty) ||
        (!_includesByDefault && _exceptions.length == widget.tasks.length)) {
      ids = null;
    } else {
      ids = Set.unmodifiable(
        _includesByDefault
            ? widget.tasks.map((task) => task.id).where(_includes)
            : _exceptions,
      );
    }
    Navigator.pop(context, (ids: ids));
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _includesByDefault
        ? _exceptions.isEmpty
        : _exceptions.length == widget.tasks.length;
    final locale = MaterialLocalizations.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: PlanReviewFrame(
        title: 'Choose objectives',
        maxWidth: 408,
        closeTooltip: null,
        slivers: [
          SliverPadding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.tasks.length > 8)
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'Find a task',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: _search,
                    ),
                  TextButton(
                    onPressed: () => setState(() {
                      _includesByDefault = !allSelected;
                      _exceptions.clear();
                    }),
                    child: Text(
                      allSelected ? 'Clear selection' : 'Select all tasks',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_visible.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No matching tasks.'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
              sliver: SliverList.builder(
                itemCount: _visible.length,
                itemBuilder: (_, index) {
                  final task = _visible[index];
                  final details = [
                    if (task.date case final date?)
                      locale.formatMediumDate(date.toLocal()),
                    if (task.schedulingHold case final hold?)
                      hold.message
                    else if (task.estimatedMinutes case final effort?
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
                    value: _includes(task.id),
                    onChanged: (selected) => setState(() {
                      if ((selected == true) == _includesByDefault) {
                        _exceptions.remove(task.id);
                      } else {
                        _exceptions.add(task.id);
                      }
                    }),
                  );
                },
              ),
            ),
        ],
        footer: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 12),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _accept,
                child: const Text('Use objectives'),
              ),
            ],
          ),
        ),
      ),
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

String _formatDuration(int minutes) {
  if (minutes < 60) return '$minutes min';
  if (minutes % 60 == 0) return '${minutes ~/ 60} h';
  return '${minutes ~/ 60} h ${minutes % 60} min';
}
