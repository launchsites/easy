import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import '../calendar_page.dart';
import '../task_model.dart';
import '../ui_theme.dart';
import 'availability_settings.dart';
import 'plan_review_frame.dart';
import 'planner.dart';
import 'task_reservations.dart';

class PlanSelection {
  PlanSelection({
    required this.window,
    required List<ScheduledTask> tasks,
    this.reservationStart,
  }) : tasks = List.unmodifiable(tasks);

  final TimeSpan window;
  final List<ScheduledTask> tasks;
  final DateTime? reservationStart;
}

ScheduleProposal planWorkspaceDay({
  required TimeSpan window,
  required List<CalendarEvent> events,
  required List<TaskItem> tasks,
  DateTime? reservationStart,
  SchedulingSettings? settings,
  Set<String>? categories,
  Set<String>? taskIds,
}) {
  final cutoff = reservationStart ?? window.start;
  final commitments = <FixedCommitment>[];
  final placed = <PlacedCommitment>[];
  final placeIds =
      settings?.places.map((place) => place.id).toSet() ?? const <String>{};
  for (final event in events) {
    if (!event.end.isAfter(event.start)) continue;
    final eventSpan = TimeSpan(event.start, event.end);
    commitments.add(FixedCommitment(eventSpan));
    if (settings != null) {
      placed.add(
        PlacedCommitment(
          id: event.id,
          span: eventSpan,
          placeId: placeIds.contains(event.savedPlaceId)
              ? event.savedPlaceId
              : null,
        ),
      );
    }
  }

  final evidence = reviewTaskReservations(
    tasks: tasks,
    events: events,
    cutoff: cutoff,
  );
  final reservations = evidence.reservations;
  final completed = evidence.completedAt;
  final accepted = {
    for (final entry in reservations.entries)
      if (entry.value.coveredAt != null) entry.key,
  };
  final planning = <PlanningTask>[];
  for (final task in tasks) {
    if (task.done ||
        (taskIds != null && !taskIds.contains(task.id)) ||
        (categories != null && !categories.contains(task.category))) {
      continue;
    }
    final estimate = task.estimatedMinutes;
    final planned = reservations[task.id]?.minutes ?? 0;
    final hold = task.schedulingHold;
    if (accepted.contains(task.id)) continue;

    var earliest = task.earliestStart;
    for (final id in task.prerequisiteIds) {
      if (completed.containsKey(id)) continue;
      final prior = reservations[id];
      final alreadyPlannedThrough = prior?.requiresReview == true
          ? prior?.coveredAt
          : prior?.lastEnd;
      if (alreadyPlannedThrough != null &&
          (earliest == null || alreadyPlannedThrough.isAfter(earliest))) {
        earliest = alreadyPlannedThrough;
      }
    }
    final day = task.date?.toLocal();
    final deadline =
        task.dueAt ??
        (day == null ? null : DateTime(day.year, day.month, day.day + 1));
    final remaining = estimate == null || estimate <= 0 || planned >= estimate
        ? null
        : estimate - planned;
    final minimum = task.minimumChunkMinutes;
    planning.add(
      PlanningTask(
        id: task.id,
        title: task.title,
        category: task.category,
        remainingMinutes: remaining,
        earliest: earliest,
        deadline: deadline,
        priority: switch (task.priority) {
          TaskPriority.low => PlannerPriority.low,
          TaskPriority.high => PlannerPriority.high,
          _ => PlannerPriority.normal,
        },
        allowSplit: task.allowSplit,
        minimumChunkMinutes: minimum > 0 ? minimum : defaultTaskChunkMinutes,
        prerequisites: task.prerequisiteIds.toSet(),
        needsDetails: hold != null,
        needsDetailsMessage: hold?.message,
        reservationsNeedReview: reservations[task.id]?.requiresReview ?? false,
      ),
    );
  }
  final inputs = settings?.planningInputs(
    horizon: window,
    categories: planning.map((task) => task.category),
    commitments: placed,
  );
  final result = proposeSchedule(
    horizon: window,
    availability: inputs?.availability ?? [PlanningWindow(window)],
    commitments: inputs?.commitments ?? commitments,
    tasks: planning,
    completedPrerequisites: {...completed.keys, ...accepted},
  );
  if (inputs == null) return result;
  return ScheduleProposal(
    scheduled: result.scheduled,
    unscheduled: result.unscheduled,
    satisfiedPrerequisites: result.satisfiedPrerequisites,
    advisories: [
      if (inputs.availability.isEmpty) 'This window has no saved availability.',
      if (inputs.travelIssues.any(
        (issue) => issue.kind == TravelIssueKind.missingDuration,
      ))
        'Some gaps need a saved travel duration.',
      if (inputs.travelIssues.any(
        (issue) => issue.kind == TravelIssueKind.insufficientGap,
      ))
        'Some commitments leave too little travel time.',
    ],
  );
}

typedef _PlanInput = ({
  TimeSpan window,
  List<CalendarEvent> events,
  List<TaskItem> tasks,
  DateTime reservationStart,
  SchedulingSettings? settings,
  Set<String>? categories,
});

ScheduleProposal _previewDay(_PlanInput input) => planWorkspaceDay(
  window: input.window,
  events: input.events,
  tasks: input.tasks,
  reservationStart: input.reservationStart,
  settings: input.settings,
  categories: input.categories,
);

class PlanDaySheet extends StatefulWidget {
  const PlanDaySheet({
    required this.day,
    required this.events,
    required this.tasks,
    this.clock,
    this.settings,
    this.categories,
    super.key,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final DateTime Function()? clock;
  final SchedulingSettings? settings;
  final Set<String>? categories;

  @override
  State<PlanDaySheet> createState() => _PlanDaySheetState();
}

class _PlanDaySheetState extends State<PlanDaySheet> {
  static const _inlineBlockLimit = 6;

  late final DateTime _day;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _loading = false;
  bool _showUnscheduled = false;
  String? _error;
  ({TimeSpan window, DateTime reservationStart, ScheduleProposal proposal})?
  _previewResult;
  final _selected = <String>{};
  Map<String, Set<String>> _required = const {};
  Map<String, String>? _taskTitles;

  DateTime get _now => (widget.clock ?? DateTime.now)().toLocal();

  @override
  void initState() {
    super.initState();
    _day = DateUtils.dateOnly(widget.day.toLocal());
    final now = _now;
    final firstMinute = DateUtils.isSameDay(now, _day)
        ? ((now.hour * 60 + now.minute + 15) ~/ 15 * 15).clamp(
            9 * 60,
            23 * 60 + 58,
          )
        : 9 * 60;
    _start = TimeOfDay(hour: firstMinute ~/ 60, minute: firstMinute % 60);
    _end = firstMinute < 17 * 60
        ? const TimeOfDay(hour: 17, minute: 0)
        : const TimeOfDay(hour: 23, minute: 59);
  }

  DateTime _onDay(TimeOfDay time) =>
      DateTime(_day.year, _day.month, _day.day, time.hour, time.minute);

  Future<void> _pickTime({required bool start}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: start ? _start : _end,
      helpText: start ? 'Set availability start' : 'Set availability end',
    );
    if (!mounted || picked == null || picked == (start ? _start : _end)) return;
    setState(() {
      if (start) {
        _start = picked;
      } else {
        _end = picked;
      }
      _error = null;
      _previewResult = null;
      _showUnscheduled = false;
      _selected.clear();
      _required = const {};
      _taskTitles = null;
    });
  }

  Future<void> _preview() async {
    final start = _onDay(_start);
    final end = _onDay(_end);
    if (TimeOfDay.fromDateTime(start) != _start ||
        TimeOfDay.fromDateTime(end) != _end) {
      setState(() => _error = 'Choose a time that exists on this date.');
      return;
    }
    if (!end.isAfter(start)) {
      setState(() => _error = 'End time must be after start time.');
      return;
    }
    final now = _now;
    if (start.isBefore(now)) {
      setState(() => _error = 'Choose a start time in the future.');
      return;
    }
    final window = TimeSpan(start, end);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final proposal = await compute(_previewDay, (
        window: window,
        events: widget.events,
        tasks: widget.tasks,
        reservationStart: now,
        settings: widget.settings,
        categories: widget.categories,
      ));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _previewResult = (
          window: window,
          reservationStart: now,
          proposal: proposal,
        );
        _selected.addAll(
          proposal.scheduled.map((schedule) => schedule.task.id),
        );
        _required = requiredPlanSelections(proposal);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not preview this day. Try again.';
      });
    }
  }

  void _toggle(String id, bool? checked) => setState(() {
    if (checked == true) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
  });

  void _accept(List<ScheduledTask> suggestions) {
    final preview = _previewResult!;
    Navigator.pop(
      context,
      PlanSelection(
        window: preview.window,
        reservationStart: preview.reservationStart,
        tasks: [
          for (final schedule in suggestions)
            if (_selected.contains(schedule.task.id)) schedule,
        ],
      ),
    );
  }

  Widget _scheduledRow(ScheduledTask schedule, String Function(DateTime) time) {
    String range(TimeSpan block) => '${time(block.start)} – ${time(block.end)}';
    final tile = CheckboxListTile(
      title: Text(
        schedule.task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: contentTitleStyle,
      ),
      subtitle: Text(
        schedule.blocks.take(_inlineBlockLimit).map(range).join('\n'),
        style: contentMetadataStyle,
      ),
      value: _selected.contains(schedule.task.id),
      onChanged: (checked) => _toggle(schedule.task.id, checked),
    );
    if (schedule.blocks.length <= _inlineBlockLimit) {
      return KeyedSubtree(key: ValueKey(schedule.task.id), child: tile);
    }
    return Column(
      key: ValueKey(schedule.task.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: PlanReviewFrame(
                  title: 'Block times',
                  subtitle: schedule.task.title,
                  maxWidth: 440,
                  closeTooltip: 'Close block times',
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        18,
                        4,
                        18,
                        12,
                      ),
                      sliver: SliverList.builder(
                        itemCount: schedule.blocks.length,
                        itemBuilder: (_, index) => ListTile(
                          title: Text(range(schedule.blocks[index])),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: Text('Show all ${schedule.blocks.length} block times'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    final format24Hours = MediaQuery.alwaysUse24HourFormatOf(context);
    String time(TimeOfDay value) =>
        locale.formatTimeOfDay(value, alwaysUse24HourFormat: format24Hours);
    String blockTime(DateTime value) =>
        time(TimeOfDay.fromDateTime(value.toLocal()));
    final proposal = _previewResult?.proposal;
    final scheduled = proposal?.scheduled ?? const <ScheduledTask>[];
    final unscheduled = proposal?.unscheduled ?? const <UnscheduledTask>[];
    final missingPrerequisite = hasUnselectedPlanPrerequisites(
      _required,
      _selected,
    );
    final date = locale.formatFullDate(_day);
    final titles = _showUnscheduled
        ? (_taskTitles ??= planPrerequisiteTitles(widget.tasks, unscheduled))
        : const <String, String>{};
    return PlanReviewFrame(
      title: 'Plan day',
      subtitle: date,
      maxWidth: 540,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _AvailabilityButton(
                        label: 'Available from',
                        time: time(_start),
                        onPressed: _loading
                            ? null
                            : () => _pickTime(start: true),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: _AvailabilityButton(
                        label: 'Available until',
                        time: time(_end),
                        onPressed: _loading
                            ? null
                            : () => _pickTime(start: false),
                      ),
                    ),
                  ],
                ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                if (proposal != null && scheduled.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 15),
                    child: Text(
                      'No blocks to add.',
                      style: contentMetadataStyle,
                    ),
                  ),
                for (final advisory in proposal?.advisories ?? const <String>[])
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(advisory, style: contentMetadataStyle),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          sliver: SliverList.builder(
            itemCount: scheduled.length,
            itemBuilder: (_, index) =>
                _scheduledRow(scheduled[index], blockTime),
          ),
        ),
        if (unscheduled.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            sliver: SliverToBoxAdapter(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Semantics(
                  expanded: _showUnscheduled,
                  child: TextButton.icon(
                    iconAlignment: IconAlignment.end,
                    icon: Icon(
                      _showUnscheduled
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    onPressed: () =>
                        setState(() => _showUnscheduled = !_showUnscheduled),
                    label: Text('Unscheduled (${unscheduled.length})'),
                  ),
                ),
              ),
            ),
          ),
          if (_showUnscheduled)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList.builder(
                itemCount: unscheduled.length,
                itemBuilder: (context, index) {
                  final issue = unscheduled[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(issue.task.title, style: contentTitleStyle),
                    subtitle: Text(
                      planningIssueMessage(issue, titles),
                      style: contentMetadataStyle,
                    ),
                  );
                },
              ),
            ),
        ],
      ],
      footer: proposal == null || scheduled.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (missingPrerequisite)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: const Text(
                          'Select the prerequisite tasks first.',
                          style: contentMetadataStyle,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: proposal == null
                        ? (_loading ? null : _preview)
                        : (_selected.isEmpty || missingPrerequisite
                              ? null
                              : () => _accept(scheduled)),
                    child: Text(
                      proposal == null
                          ? (_loading ? 'Previewing…' : 'Preview plan')
                          : 'Add selected tasks',
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

class _AvailabilityButton extends StatelessWidget {
  const _AvailabilityButton({
    required this.label,
    required this.time,
    required this.onPressed,
  });

  final String label;
  final String time;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      side: const BorderSide(color: line),
    ),
    child: Column(
      children: [
        Text(label, textAlign: TextAlign.center, style: contentMetadataStyle),
        const SizedBox(height: 2),
        Text(time, textAlign: TextAlign.center, style: contentTitleStyle),
      ],
    ),
  );
}
