import 'package:flutter/foundation.dart' show compute;
import 'package:material_ui/material_ui.dart';

import '../calendar_page.dart';
import '../task_model.dart';
import '../ui_theme.dart';
import 'availability_settings.dart';
import 'planner.dart';

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
}) {
  final cutoff = reservationStart ?? window.start;
  final commitments = <FixedCommitment>[];
  final placed = <PlacedCommitment>[];
  final placeIds =
      settings?.places.map((place) => place.id).toSet() ?? const <String>{};
  final reserved = <String, List<TimeSpan>>{};
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
    final id = event.plannedTaskId;
    if (id == null || !event.end.isAfter(cutoff)) continue;
    final from = event.start.isBefore(cutoff) ? cutoff : event.start;
    (reserved[id] ??= []).add(TimeSpan(from, event.end));
  }

  final reservations = reserved.map(
    (id, spans) => MapEntry(id, _combineReservations(spans)),
  );
  final completed = {
    for (final task in tasks)
      if (task.done) task.id,
  };
  final accepted = {
    for (final task in tasks)
      if ((task.estimatedMinutes ?? 0) > 0 &&
          (reservations[task.id]?.minutes ?? 0) >= task.estimatedMinutes!)
        task.id,
  };
  final planning = <PlanningTask>[];
  for (final task in tasks) {
    if (task.done ||
        (categories != null && !categories.contains(task.category))) {
      continue;
    }
    final estimate = task.estimatedMinutes;
    final planned = reservations[task.id]?.minutes ?? 0;
    if (estimate != null && estimate > 0 && planned >= estimate) continue;

    var earliest = task.earliestStart;
    for (final id in task.prerequisiteIds) {
      if (completed.contains(id)) continue;
      final alreadyPlannedThrough = reservations[id]?.end;
      if (alreadyPlannedThrough != null &&
          (earliest == null || alreadyPlannedThrough.isAfter(earliest))) {
        earliest = alreadyPlannedThrough;
      }
    }
    final day = task.date?.toLocal();
    final deadline =
        task.dueAt ??
        (day == null ? null : DateTime(day.year, day.month, day.day + 1));
    final remaining = estimate == null || estimate <= 0
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
    completedPrerequisites: {...completed, ...accepted},
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

({int minutes, DateTime end}) _combineReservations(List<TimeSpan> spans) {
  spans.sort((a, b) => a.start.compareTo(b.start));
  var start = spans.first.start;
  var end = spans.first.end;
  var total = Duration.zero;
  for (final span in spans.skip(1)) {
    if (span.start.isAfter(end)) {
      total += end.difference(start);
      start = span.start;
      end = span.end;
    } else if (span.end.isAfter(end)) {
      end = span.end;
    }
  }
  total += end.difference(start);
  return (minutes: total.inMinutes, end: end);
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
  late final DateTime _day;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _loading = false;
  bool _showUnscheduled = false;
  String? _error;
  ({TimeSpan window, DateTime reservationStart, ScheduleProposal proposal})?
  _previewResult;
  final _selected = <String>{};

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
    final proposedIds = {for (final item in scheduled) item.task.id};
    final missingPrerequisite = scheduled.any(
      (schedule) =>
          _selected.contains(schedule.task.id) &&
          schedule.task.prerequisites.any(
            (id) => proposedIds.contains(id) && !_selected.contains(id),
          ),
    );
    final date = locale.formatFullDate(_day);
    final titles = _showUnscheduled
        ? {for (final task in widget.tasks) task.id: task.title}
        : const <String, String>{};
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 540,
          maxHeight: MediaQuery.sizeOf(context).height * .86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: const Text(
                            'Plan day',
                            style: sectionHeadingStyle,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(date, style: contentMetadataStyle),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close plan',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: muted),
                  ),
                ],
              ),
            ),
            Flexible(
              child: CustomScrollView(
                shrinkWrap: true,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
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
                          for (final advisory
                              in proposal?.advisories ?? const <String>[])
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                advisory,
                                style: contentMetadataStyle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    sliver: SliverList.builder(
                      itemCount: scheduled.length,
                      itemBuilder: (context, index) {
                        final schedule = scheduled[index];
                        return CheckboxListTile(
                          key: ValueKey(schedule.task.id),
                          title: Text(
                            schedule.task.title,
                            style: contentTitleStyle,
                          ),
                          subtitle: Text(
                            schedule.blocks
                                .map(
                                  (block) =>
                                      '${blockTime(block.start)} – ${blockTime(block.end)}',
                                )
                                .join('\n'),
                            style: contentMetadataStyle,
                          ),
                          value: _selected.contains(schedule.task.id),
                          onChanged: (checked) =>
                              _toggle(schedule.task.id, checked),
                        );
                      },
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
                              onPressed: () => setState(
                                () => _showUnscheduled = !_showUnscheduled,
                              ),
                              label: Text(
                                'Unscheduled (${unscheduled.length})',
                              ),
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
                              title: Text(
                                issue.task.title,
                                style: contentTitleStyle,
                              ),
                              subtitle: Text(
                                _reason(issue, titles),
                                style: contentMetadataStyle,
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (proposal == null || scheduled.isNotEmpty) ...[
              const Divider(),
              Padding(
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
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _reason(UnscheduledTask issue, Map<String, String> titles) =>
    switch (issue.problem) {
      PlannerProblem.needsDuration => 'Add an estimated duration',
      PlannerProblem.needsDetails => 'Needs more details',
      PlannerProblem.unavailableDependency =>
        switch (titles[issue.prerequisiteId]) {
          final title? => 'Waiting on $title',
          null => 'Prerequisite unavailable',
        },
      PlannerProblem.dependencyCycle => 'Prerequisite cycle',
      PlannerProblem.deadlinePassed => 'Due before this window',
      PlannerProblem.noFeasibleTime => 'No available block fits',
    };

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
