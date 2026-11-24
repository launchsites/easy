import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import '../workout_plan.dart';
import 'review_agenda.dart';
import 'review_availability.dart';
import 'review_data.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    required this.data,
    required this.onChanged,
    required this.agendaForDay,
    this.availabilityForDay,
    this.activityMinutesForDay,
    this.onRollForward,
    this.onReviewActions,
    this.initialDay,
    this.clock,
    super.key,
  });

  final ReviewData data;
  final Future<void> Function(ReviewData data) onChanged;
  final ReviewAgenda Function(DateTime day) agendaForDay;

  /// Loads verified availability for the day shown in the briefing.
  /// The agenda's synchronous availability remains available to legacy callers.
  final Future<ReviewDayAvailability?> Function(DateTime day)?
  availabilityForDay;

  /// Optional fast path for History. The host can provide a cached lookup by
  /// civil date. With no callback, History uses the day agenda's activity total.
  final int? Function(DateTime day)? activityMinutesForDay;
  final Future<void> Function(ReviewTask task, DateTime day)? onRollForward;
  final ValueChanged<String>? onReviewActions;
  final DateTime? initialDay;
  final DateTime Function()? clock;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

enum _ReviewView { day, week, habits }

class _ReviewPageState extends State<ReviewPage> {
  late ReviewData _data = widget.data;
  late DateTime _day = reviewDay(widget.initialDay ?? _now);
  var _view = _ReviewView.day;
  var _monthHistory = false;
  var _busy = false;
  DateTime? _requestedAvailabilityDay;
  Future<ReviewDayAvailability?>? _dayAvailability;

  DateTime get _now => (widget.clock ?? DateTime.now)().toLocal();
  DateTime get _today => reviewDay(_now);

  @override
  void initState() {
    super.initState();
    _requestDayAvailability();
  }

  @override
  void didUpdateWidget(covariant ReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy && oldWidget.data != widget.data) _data = widget.data;
    if (oldWidget.availabilityForDay != widget.availabilityForDay) {
      _requestedAvailabilityDay = null;
      _dayAvailability = null;
      _requestDayAvailability();
    }
  }

  void _requestDayAvailability() {
    final load = widget.availabilityForDay;
    final day = _day;
    if (load == null ||
        _view != _ReviewView.day ||
        _requestedAvailabilityDay == day) {
      return;
    }
    _requestedAvailabilityDay = day;
    _dayAvailability = Future<ReviewDayAvailability?>.sync(() => load(day))
        .onError((_, _) => null);
  }

  Future<bool> _save(ReviewData next) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await widget.onChanged(next);
      if (mounted) setState(() => _data = next);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notifyFailure() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The change could not be saved. Try again.'),
        ),
      );
    }
  }

  Future<void> _pickDay() async {
    final dates = _PickerBounds(_day);
    final choice = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: dates.first,
      lastDate: dates.last,
      helpText: 'Choose review date',
    );
    if (mounted && choice != null) {
      setState(() {
        _day = reviewDay(choice);
        _requestDayAvailability();
      });
    }
  }

  Future<void> _priorities(DailyReview review) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _TextReviewDialog(
        title: 'Priorities',
        fields: [('What matters today?', review.priorities)],
        saveLabel: 'Save priorities',
        onSave: (values) => _save(
          _data.withDay(_data.dayFor(review.day).withPriorities(values.single)),
        ),
      ),
    );
  }

  Future<void> _reflection(DateTime day) async {
    final savedAt = _now;
    final id =
        'reflection-${savedAt.microsecondsSinceEpoch}-${_data.dayFor(day).reflections.length}';
    await showDialog<void>(
      context: context,
      builder: (context) => _TextReviewDialog(
        title: 'Reflect on the day',
        fields: const [
          ('What did you get done?', ''),
          ('What got in the way?', ''),
          ('What matters tomorrow?', ''),
        ],
        saveLabel: 'Save reflection',
        requireText: true,
        onSave: (values) => _save(
          _data.withDay(
            _data
                .dayFor(day)
                .withReflection(
                  ReviewReflection(
                    id: id,
                    savedAt: savedAt,
                    achieved: values[0],
                    obstacle: values[1],
                    tomorrow: values[2],
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Future<void> _reviewOccurrence(DailyReview review, ReviewEvent event) async {
    final result = await showDialog<({ReviewOutcome? value})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(event.title),
        children: [
          for (final (outcome, label) in [
            (ReviewOutcome.completed, 'Completed'),
            (ReviewOutcome.partial, 'Partly completed'),
            (ReviewOutcome.skipped, 'Skipped'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (value: outcome)),
              child: Text(label),
            ),
          if (review.outcomes.containsKey(event.id))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (value: null)),
              child: const Text('Clear outcome'),
            ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    if (!await _save(
      _data.withDay(
        _data.dayFor(review.day).withOutcome(event.id, result.value),
      ),
    )) {
      _notifyFailure();
    }
  }

  Future<void> _rollForward(ReviewTask task) async {
    final roll = widget.onRollForward;
    if (roll == null || !task.canRollForward || _busy) return;
    final forward = nextReviewDay(_day.isBefore(_today) ? _today : _day);
    final label = MaterialLocalizations.of(context).formatMediumDate(forward);
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move to $label?'),
        content: Text(task.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Move task'),
          ),
        ],
      ),
    );
    if (!mounted || choice != true) return;
    setState(() => _busy = true);
    try {
      await roll(task, forward);
    } catch (_) {
      _notifyFailure();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkIn(Habit habit, HabitOutcome outcome) async {
    final chosen = _data.habitCheckin(habit.id, _day)?.outcome;
    if (!await _save(
      _data.checkIn(
        id: habit.id,
        day: _day,
        outcome: chosen == outcome ? null : outcome,
      ),
    )) {
      _notifyFailure();
    }
  }

  Future<void> _editHabit([Habit? existing]) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _HabitEditor(
        habit: existing,
        earliestDay: existing == null ? _today : nextReviewDay(_today),
        onSave: (version) {
          final habit =
              existing?.withRevision(version) ??
              Habit(
                id: 'habit-${_now.microsecondsSinceEpoch}-${_data.habits.length}',
                revisions: [version],
              );
          return _save(_data.withHabit(habit));
        },
      ),
    );
  }

  Future<void> _pauseHabit(Habit habit) async {
    final dates = _PickerBounds(_today);
    final selected = await showDateRangePicker(
      context: context,
      firstDate: _today,
      lastDate: dates.last,
      initialDateRange: DateTimeRange(start: _today, end: _today),
      helpText: 'Pause habit',
      saveText: 'Pause dates',
    );
    if (!mounted || selected == null) return;
    if (!await _save(
      _data.withHabit(
        habit.withPause(HabitPause(start: selected.start, end: selected.end)),
      ),
    )) {
      _notifyFailure();
    }
  }

  Future<void> _archiveHabit(Habit habit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive habit?'),
        content: Text(habit.revisions.last.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    if (!await _save(_data.withHabit(habit.archivedFrom(_today)))) {
      _notifyFailure();
    }
  }

  @override
  Widget build(BuildContext context) {
    final availability = _view == _ReviewView.day ? _dayAvailability : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 690),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 3, 18, 9),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 4,
                    children: [
                      for (final (view, label) in [
                        (_ReviewView.day, 'Day'),
                        (_ReviewView.week, 'History'),
                        (_ReviewView.habits, 'Habits'),
                      ])
                        ChoiceChip(
                          selected: _view == view,
                          label: Text(label),
                          onSelected: _busy
                              ? null
                              : (_) => setState(() {
                                  _view = view;
                                  _requestDayAvailability();
                                }),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: availability == null
                      ? _reviewContent()
                      : FutureBuilder(
                          future: availability,
                          builder: (context, snapshot) => _reviewContent(
                            snapshot.connectionState == ConnectionState.done
                                ? snapshot.data
                                : null,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reviewContent([ReviewDayAvailability? availability]) {
    final day = _day;
    final localizations = MaterialLocalizations.of(context);
    return ListView(
      key: PageStorageKey(_view),
      padding: const EdgeInsets.fromLTRB(21, 8, 21, 35),
      children: [
        if (_view case _ReviewView.day || _ReviewView.week)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy ? null : _pickDay,
              icon: const Icon(Icons.calendar_today_outlined, size: 17),
              label: Text(localizations.formatFullDate(day)),
            ),
          ),
        ...switch (_view) {
          _ReviewView.day => _daySections(day, availability),
          _ReviewView.week => _weekSections(day),
          _ReviewView.habits => _habitSections(),
        },
      ],
    );
  }

  List<Widget> _daySections(DateTime day, ReviewDayAvailability? availability) {
    final review = _data.dayFor(day);
    final agenda = widget.agendaForDay(day);
    final brief =
        (widget.availabilityForDay == null
                ? agenda
                : ReviewAgenda(
                    events: agenda.events,
                    tasks: agenda.tasks,
                    unresolvedCaptures: agenda.unresolvedCaptures,
                    confirmedActivityMinutes: agenda.confirmedActivityMinutes,
                    availability: availability?.windows,
                  ))
            .forDay(day);
    final stats = [
      if (brief.freeMinutes case final free?) '${_durationLabel(free)} free',
      if (brief.knownEffortMinutes > 0)
        '${_durationLabel(brief.knownEffortMinutes)} estimated work',
      if (brief.unestimatedTasks > 0)
        '${brief.unestimatedTasks} without estimates',
      if (brief.unresolvedCaptures > 0)
        '${brief.unresolvedCaptures} captures to review',
    ];
    return [
      _ReviewSection(
        title: 'Priorities',
        action: TextButton(
          onPressed: _busy ? null : () => _priorities(review),
          child: Text(
            review.priorities.trim().isEmpty ? 'Set priorities' : 'Edit',
          ),
        ),
        children: [
          if (review.priorities.trim().isNotEmpty) Text(review.priorities),
        ],
      ),
      _ReviewSection(
        title: 'Briefing',
        children: [
          if (stats.isNotEmpty)
            Text(stats.join(' · '), style: contentMetadataStyle),
          if (brief.events.isNotEmpty)
            _ReviewRows(
              label: 'Calendar',
              count: brief.events.length,
              item: (index) => _eventRow(brief.events[index], review),
            ),
          if (brief.openDueTasks.isNotEmpty)
            _ReviewRows(
              label: 'Open due tasks',
              count: brief.openDueTasks.length,
              item: (index) => _taskRow(brief.openDueTasks[index]),
            ),
          if (stats.isEmpty &&
              brief.events.isEmpty &&
              brief.openDueTasks.isEmpty)
            const Text(
              'Nothing due or scheduled.',
              style: contentMetadataStyle,
            ),
        ],
      ),
      if (_data.habitsOn(day).isNotEmpty)
        _ReviewSection(
          title: 'Check-ins',
          children: [
            for (final habit in _data.habitsOn(day)) _habitCheckinRow(habit),
          ],
        ),
      _ReviewSection(
        title: 'Reflection',
        action: TextButton(
          onPressed: _busy ? null : () => _reflection(day),
          child: const Text('Write reflection'),
        ),
        children: [
          if (brief.scheduledMinutes > 0 ||
              brief.confirmedActivityMinutes != null)
            Text(
              [
                if (brief.scheduledMinutes > 0)
                  '${_durationLabel(brief.scheduledMinutes)} scheduled',
                if (brief.confirmedActivityMinutes case final actual?)
                  '${_durationLabel(actual)} logged',
              ].join(' · '),
              style: contentMetadataStyle,
            ),
          for (final completed in brief.completedTasks)
            ListTile(
              leading: const Icon(Icons.check_rounded, color: accent),
              title: Text(completed.title),
              contentPadding: EdgeInsets.zero,
            ),
          for (final reflection in review.reflections.reversed)
            _reflectionSummary(reflection),
        ],
      ),
    ];
  }

  Widget _eventRow(ReviewEvent event, DailyReview review) {
    final localizations = MaterialLocalizations.of(context);
    final when = event.allDay
        ? 'All day'
        : localizations.formatTimeOfDay(
            TimeOfDay.fromDateTime(event.start.toLocal()),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    final outcome = review.outcomes[event.id];
    final elapsed = !event.end.isAfter(_now);
    final status = switch (outcome) {
      ReviewOutcome.completed => 'Completed',
      ReviewOutcome.partial => 'Partial',
      ReviewOutcome.skipped => 'Skipped',
      null => elapsed ? 'Confirm outcome' : null,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(event.title),
      subtitle: Text([when, ?status].join(' · '), style: contentMetadataStyle),
      trailing: elapsed
          ? const Icon(Icons.chevron_right_rounded, color: muted)
          : null,
      onTap: elapsed && !_busy ? () => _reviewOccurrence(review, event) : null,
    );
  }

  Widget _taskRow(ReviewTask task) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(task.title),
    subtitle: task.estimatedMinutes == null
        ? null
        : Text(
            _durationLabel(task.estimatedMinutes!),
            style: contentMetadataStyle,
          ),
    trailing: task.canRollForward && widget.onRollForward != null
        ? IconButton(
            tooltip: 'Move ${task.title} to another day',
            onPressed: _busy ? null : () => _rollForward(task),
            icon: const Icon(Icons.redo_rounded, color: muted),
          )
        : null,
  );

  Widget _reflectionSummary(ReviewReflection entry) => ExpansionTile(
    key: PageStorageKey(('reflection', entry.id)),
    title: Text(
      MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(entry.savedAt.toLocal())),
    ),
    tilePadding: EdgeInsets.zero,
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    childrenPadding: const EdgeInsets.only(bottom: 7),
    children: [
      for (final (label, value) in [
        ('What went well', entry.achieved),
        ('What got in the way', entry.obstacle),
        ('Tomorrow', entry.tomorrow),
      ])
        if (value.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(label, style: contentMetadataStyle),
                SelectionArea(child: Text(value)),
              ],
            ),
          ),
      if (entry.tomorrow.trim().isNotEmpty && widget.onReviewActions != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => widget.onReviewActions!(entry.tomorrow),
            child: const Text('Review follow-up'),
          ),
        ),
    ],
  );

  Widget _habitCheckinRow(Habit habit) {
    final title = habit.revisionFor(_day)?.name ?? habit.revisions.last.name;
    final check = _data.habitCheckin(habit.id, _day)?.outcome;
    final subtitle = switch (check) {
      HabitOutcome.done => 'Done',
      HabitOutcome.skipped => 'Skipped',
      null => null,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: contentMetadataStyle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: check == HabitOutcome.done
                ? 'Clear done for $title'
                : 'Mark $title done',
            isSelected: check == HabitOutcome.done,
            onPressed: _busy ? null : () => _checkIn(habit, HabitOutcome.done),
            icon: const Icon(Icons.check_circle_outline_rounded),
            selectedIcon: const Icon(Icons.check_circle_rounded, color: accent),
          ),
          IconButton(
            tooltip: check == HabitOutcome.skipped
                ? 'Clear skip for $title'
                : 'Skip $title',
            isSelected: check == HabitOutcome.skipped,
            onPressed: _busy
                ? null
                : () => _checkIn(habit, HabitOutcome.skipped),
            icon: const Icon(Icons.remove_circle_outline_rounded),
            selectedIcon: const Icon(Icons.remove_circle_rounded, color: muted),
          ),
        ],
      ),
    );
  }

  List<Widget> _weekSections(DateTime selected) {
    final start = _monthHistory
        ? DateTime(selected.year, selected.month)
        : nextReviewDay(selected, DateTime.monday - selected.weekday);
    final duration = _monthHistory
        ? DateUtils.getDaysInMonth(start.year, start.month)
        : 7;
    final summaries = [
      for (var index = 0; index < duration; index++)
        _weekDay(nextReviewDay(start, index)),
    ];
    final reflectionCount = summaries.fold(
      0,
      (sum, item) => sum + item.reflections,
    );
    final habitsDone = summaries.fold(0, (sum, item) => sum + item.done);
    final logged = summaries.where((entry) => entry.actual != null);
    return [
      _ReviewSection(
        title: _monthHistory
            ? MaterialLocalizations.of(context).formatMonthYear(start)
            : 'Week of ${MaterialLocalizations.of(context).formatMediumDate(start)}',
        action: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _monthHistory = !_monthHistory),
          child: Text(_monthHistory ? 'Show week' : 'Show month'),
        ),
        children: [
          Text(
            [
              '$reflectionCount ${reflectionCount == 1 ? 'reflection' : 'reflections'}',
              '$habitsDone ${habitsDone == 1 ? 'check-in' : 'check-ins'} done',
              if (logged.isNotEmpty)
                '${_durationLabel(logged.fold(0, (sum, entry) => sum + entry.actual!))} logged',
            ].join(' · '),
            style: contentMetadataStyle,
          ),
          for (final item in summaries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                MaterialLocalizations.of(context).formatMediumDate(item.day),
              ),
              subtitle:
                  item.reflections + item.done + item.skipped == 0 &&
                      item.actual == null
                  ? null
                  : Text(
                      [
                        if (item.reflections > 0)
                          '${item.reflections} ${item.reflections == 1 ? 'reflection' : 'reflections'}',
                        if (item.done > 0) '${item.done} done',
                        if (item.skipped > 0) '${item.skipped} skipped',
                        if (item.actual case final minutes?)
                          '${_durationLabel(minutes)} logged',
                      ].join(' · '),
                      style: contentMetadataStyle,
                    ),
              trailing: const Icon(Icons.chevron_right_rounded, color: muted),
              onTap: _busy
                  ? null
                  : () => setState(() {
                      _day = item.day;
                      _view = _ReviewView.day;
                      _requestDayAvailability();
                    }),
            ),
        ],
      ),
    ];
  }

  ({DateTime day, int reflections, int done, int skipped, int? actual})
  _weekDay(DateTime day) {
    var done = 0;
    var skipped = 0;
    for (final habit in _data.habitsOn(day)) {
      switch (_data.habitCheckin(habit.id, day)?.outcome) {
        case HabitOutcome.done:
          done++;
        case HabitOutcome.skipped:
          skipped++;
        case null:
          break;
      }
    }
    final activityMinutes = widget.activityMinutesForDay;
    return (
      day: day,
      reflections: _data.dayFor(day).reflections.length,
      done: done,
      skipped: skipped,
      actual: activityMinutes == null
          ? widget.agendaForDay(day).confirmedActivityMinutes
          : activityMinutes(day),
    );
  }

  List<Widget> _habitSections() {
    final habits = _data.habits.toList();
    return [
      _ReviewSection(
        title: 'Habits',
        action: TextButton.icon(
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New habit'),
          onPressed: _busy ? null : _editHabit,
        ),
        children: [
          if (habits.isEmpty)
            const Text('No habits yet.', style: contentMetadataStyle),
          for (final habit in habits) _habitRow(habit),
        ],
      ),
    ];
  }

  Widget _habitRow(Habit habit) {
    final current = habit.revisionFor(_today) ?? habit.revisions.first;
    final todayKey = reviewDayKey(_today);
    final future = habit.revisions
        .where(
          (revision) =>
              reviewDayKey(revision.effectiveOn).compareTo(todayKey) > 0,
        )
        .firstOrNull;
    final archived = habit.isArchivedOn(_today);
    final status = archived
        ? 'Archived'
        : habit.isPausedOn(_today)
        ? 'Paused'
        : _scheduleLabel(current.schedule, context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(current.name),
      subtitle: Text(
        [
          status,
          if (!archived && future != null)
            'Next schedule ${MaterialLocalizations.of(context).formatMediumDate(future.effectiveOn)}',
        ].join(' · '),
        style: contentMetadataStyle,
      ),
      trailing: archived
          ? null
          : PopupMenuButton<int>(
              tooltip: 'Manage ${current.name}',
              enabled: !_busy,
              onSelected: (selected) => switch (selected) {
                0 => _editHabit(habit),
                1 => _pauseHabit(habit),
                _ => _archiveHabit(habit),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text('Edit schedule')),
                PopupMenuItem(value: 1, child: Text('Pause dates')),
                PopupMenuItem(value: 2, child: Text('Archive habit')),
              ],
            ),
    );
  }
}

String _durationLabel(int minutes) {
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  if (hours == 0) return '$remainder min';
  return remainder == 0 ? '$hours h' : '$hours h $remainder min';
}

String _scheduleLabel(WorkoutSchedule schedule, BuildContext context) {
  final labels = MaterialLocalizations.of(context);
  return switch (schedule.kind) {
    WorkoutScheduleKind.once => labels.formatMediumDate(schedule.startDate),
    WorkoutScheduleKind.weekdays =>
      schedule.weekdays.map((day) => _weekdays[day - 1]).join(', '),
    WorkoutScheduleKind.interval when schedule.intervalDays == 1 => 'Daily',
    WorkoutScheduleKind.interval => 'Every ${schedule.intervalDays} days',
  };
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _PickerBounds {
  _PickerBounds(DateTime date)
    : first = DateTime(math.min(1900, date.year)),
      last = DateTime(math.max(2200, date.year), 12, 31);

  final DateTime first;
  final DateTime last;
}

class _ReviewSection extends StatelessWidget {
  const _ReviewSection({
    required this.title,
    required this.children,
    this.action,
  });

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final heading = Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (action == null)
            Padding(padding: const EdgeInsets.only(bottom: 7), child: heading)
          else if (large)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, action!],
            )
          else
            Row(
              children: [
                Expanded(child: heading),
                action!,
              ],
            ),
          ...children,
        ],
      ),
    );
  }
}

class _ReviewRows extends StatefulWidget {
  const _ReviewRows({
    required this.label,
    required this.count,
    required this.item,
  });

  final String label;
  final int count;
  final Widget Function(int) item;

  @override
  State<_ReviewRows> createState() => _ReviewRowsState();
}

class _ReviewRowsState extends State<_ReviewRows> {
  int _limit = 4;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label, style: contentTitleStyle),
        for (var index = 0; index < math.min(_limit, widget.count); index++)
          widget.item(index),
        if (widget.count > _limit)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _limit += 8),
              child: const Text('Show more'),
            ),
          ),
      ],
    ),
  );
}

class _TextReviewDialog extends StatefulWidget {
  const _TextReviewDialog({
    required this.title,
    required this.fields,
    required this.saveLabel,
    required this.onSave,
    this.requireText = false,
  });

  final String title;
  final List<(String label, String value)> fields;
  final String saveLabel;
  final Future<bool> Function(List<String>) onSave;
  final bool requireText;

  @override
  State<_TextReviewDialog> createState() => _TextReviewDialogState();
}

class _TextReviewDialogState extends State<_TextReviewDialog> {
  late final _fields = [
    for (final (_, text) in widget.fields) TextEditingController(text: text),
  ];
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final values = _fields.map((controller) => controller.text).toList();
    if (widget.requireText && values.every((text) => text.trim().isEmpty)) {
      setState(() => _problem = 'Write a reflection before saving.');
      return;
    }
    setState(() {
      _problem = null;
      _saving = true;
    });
    FocusScope.of(context).unfocus();
    try {
      final saved = await widget.onSave(values);
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _problem = 'The entry could not be saved. Try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _problem = 'The entry could not be saved. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, field) in widget.fields.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 13),
                child: TextField(
                  controller: _fields[index],
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: field.$1,
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            if (_problem case final problem?)
              Text(
                problem,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Saving…' : widget.saveLabel),
        ),
      ],
    ),
  );
}

enum _HabitPattern { daily, weekdays, interval, once }

class _HabitEditor extends StatefulWidget {
  const _HabitEditor({
    required this.habit,
    required this.earliestDay,
    required this.onSave,
  });

  final Habit? habit;
  final DateTime earliestDay;
  final Future<bool> Function(HabitRevision) onSave;

  @override
  State<_HabitEditor> createState() => _HabitEditorState();
}

class _HabitEditorState extends State<_HabitEditor> {
  HabitRevision? get _previous =>
      widget.habit?.revisionFor(widget.earliestDay) ??
      widget.habit?.revisions.first;
  late final _name = TextEditingController(text: _previous?.name);
  late final _interval = TextEditingController(
    text: (_previous?.schedule.intervalDays ?? 2).toString(),
  );
  late final _weekdays = {...?_previous?.schedule.weekdays};
  late DateTime _start = switch (_previous?.effectiveOn) {
    final date?
        when reviewDayKey(date).compareTo(reviewDayKey(widget.earliestDay)) >
            0 =>
      reviewDay(date),
    _ => widget.earliestDay,
  };
  late _HabitPattern _pattern = switch (_previous?.schedule.kind) {
    WorkoutScheduleKind.weekdays => _HabitPattern.weekdays,
    WorkoutScheduleKind.once => _HabitPattern.once,
    WorkoutScheduleKind.interval when _previous!.schedule.intervalDays > 1 =>
      _HabitPattern.interval,
    _ => _HabitPattern.daily,
  };

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final bounds = _PickerBounds(_start);
    final selected = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: widget.earliestDay,
      lastDate: bounds.last,
      helpText: 'Habit start date',
    );
    if (mounted && selected != null) {
      setState(() => _start = reviewDay(selected));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final interval = _pattern == _HabitPattern.interval
        ? int.tryParse(_interval.text.trim())
        : 1;
    if (_name.text.trim().isEmpty || _name.text.trim().length > 160) {
      setState(() => _error = 'Enter a habit name of at most 160 characters.');
      return;
    }
    if (_pattern == _HabitPattern.weekdays && _weekdays.isEmpty) {
      setState(() => _error = 'Choose at least one weekday.');
      return;
    }
    if (interval == null || interval < 1) {
      setState(() => _error = 'Enter a positive number of days.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      final saved = await widget.onSave(
        HabitRevision(
          effectiveOn: _start,
          name: _name.text.trim(),
          schedule: WorkoutSchedule(
            startDate: _start,
            kind: switch (_pattern) {
              _HabitPattern.weekdays => WorkoutScheduleKind.weekdays,
              _HabitPattern.once => WorkoutScheduleKind.once,
              _ => WorkoutScheduleKind.interval,
            },
            intervalDays: interval,
            weekdays: _weekdays.toList(),
          ),
        ),
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _error = 'The habit could not be saved. Try again.');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The habit could not be saved. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.habit == null ? 'New habit' : 'Edit habit'),
      content: SizedBox(
        width: 410,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Habit name'),
            ),
            const SizedBox(height: 13),
            DropdownButtonFormField<_HabitPattern>(
              initialValue: _pattern,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Repeat'),
              items: const [
                DropdownMenuItem(
                  value: _HabitPattern.daily,
                  child: Text('Daily'),
                ),
                DropdownMenuItem(
                  value: _HabitPattern.weekdays,
                  child: Text('Selected weekdays'),
                ),
                DropdownMenuItem(
                  value: _HabitPattern.interval,
                  child: Text('Every few days'),
                ),
                DropdownMenuItem(
                  value: _HabitPattern.once,
                  child: Text('Once'),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _pattern = value ?? _pattern),
            ),
            if (_pattern == _HabitPattern.weekdays)
              Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Wrap(
                  spacing: 5,
                  children: [
                    for (
                      var day = DateTime.monday;
                      day <= DateTime.sunday;
                      day++
                    )
                      FilterChip(
                        label: Text(_reviewWeekdays[day - 1]),
                        selected: _weekdays.contains(day),
                        onSelected: _saving
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  _weekdays.add(day);
                                } else {
                                  _weekdays.remove(day);
                                }
                              }),
                      ),
                  ],
                ),
              ),
            if (_pattern == _HabitPattern.interval)
              TextField(
                controller: _interval,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Days between occurrences',
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined, size: 18),
              title: Text(
                MaterialLocalizations.of(context).formatMediumDate(_start),
              ),
              subtitle: Text(
                widget.habit == null ? 'Starts' : 'New schedule starts',
              ),
              onTap: _saving ? null : _pickStart,
            ),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save habit'),
        ),
      ],
    ),
  );
}

const _reviewWeekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
