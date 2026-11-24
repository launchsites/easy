import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../calendar_page.dart';
import '../reminders/local_reminder.dart' show resolveReminderClock;
import '../task_model.dart';
import '../ui_theme.dart';
import 'availability_settings.dart';
import 'manual_time_block.dart';
import 'planner.dart';

/// Records available for reviewing one exact interval.
final class ManualBlockContext {
  const ManualBlockContext({
    required this.tasks,
    required this.events,
    this.settings,
  });

  final List<TaskItem> tasks;
  final List<CalendarEvent> events;
  final SchedulingSettings? settings;
}

class ManualTimeBlockSheet extends StatefulWidget {
  const ManualTimeBlockSheet({
    required this.task,
    required this.tasks,
    required this.events,
    required this.day,
    this.settings,
    this.existingBlock,
    this.clock,
    this.loadContext,
    super.key,
  });

  final TaskItem task;
  final List<TaskItem> tasks;
  final List<CalendarEvent> events;
  final DateTime day;
  final SchedulingSettings? settings;
  final CalendarEvent? existingBlock;
  final DateTime Function()? clock;

  /// Refresh calendar coverage for the dates the user actually chose.
  final Future<ManualBlockContext?> Function(TimeSpan span)? loadContext;

  @override
  State<ManualTimeBlockSheet> createState() => _ManualTimeBlockSheetState();
}

typedef _BlockInput = ({
  String taskId,
  TimeSpan span,
  ManualBlockContext records,
  DateTime notBefore,
  String? existingEventId,
});

ManualBlockReview _reviewBlock(_BlockInput input) => reviewManualTimeBlock(
  taskId: input.taskId,
  span: input.span,
  tasks: input.records.tasks,
  events: input.records.events,
  notBefore: input.notBefore,
  settings: input.records.settings,
  existingEventId: input.existingEventId,
);

class _ManualTimeBlockSheetState extends State<ManualTimeBlockSheet> {
  late DateTime _day;
  late TimeOfDay _time;
  late final TextEditingController _duration;
  late bool _laterFold;
  bool _reviewing = false;
  bool _dateConfirmed = false;
  bool _effortConfirmed = false;
  ManualBlockReview? _review;
  String? _error;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    final existing = widget.existingBlock;
    final initial = existing?.start.toLocal() ?? _initialStart();
    _day = DateUtils.dateOnly(initial);
    _time = TimeOfDay.fromDateTime(initial);
    final minutes =
        existing?.end.difference(existing.start).inMinutes ??
        widget.task.estimatedMinutes ??
        30;
    _duration = TextEditingController(
      text: '${minutes.clamp(1, maxManualBlockMinutes)}',
    );
    final (early, late) = _choices;
    _laterFold =
        early != late && late != null && initial.isAtSameMomentAs(late);
  }

  DateTime _initialStart() {
    final today = DateUtils.dateOnly(_now.toLocal());
    final chosen = DateUtils.dateOnly(widget.day.toLocal());
    final day = chosen.isBefore(today) ? today : chosen;
    final nextQuarter = DateTime.fromMillisecondsSinceEpoch(
      (_now.millisecondsSinceEpoch ~/ 900000 + 1) * 900000,
    );
    final usual = DateUtils.isSameDay(day, today)
        ? nextQuarter
        : DateTime(day.year, day.month, day.day, 9);
    final earliest = widget.task.earliestStart;
    if (earliest == null || !earliest.isAfter(usual)) return usual;
    final minutes = earliest.millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(
      (minutes + 59999) ~/ 60000 * 60000,
    );
  }

  @override
  void dispose() {
    _duration.dispose();
    super.dispose();
  }

  (DateTime?, DateTime?) get _choices {
    final date = DateTime.utc(
      _day.year,
      _day.month,
      _day.day,
      _time.hour,
      _time.minute,
    );
    return (
      resolveReminderClock(date),
      resolveReminderClock(date, laterFold: true),
    );
  }

  void _resetReview() {
    _review = null;
    _error = null;
    _dateConfirmed = false;
    _effortConfirmed = false;
  }

  Future<void> _chooseDate() async {
    final today = DateUtils.dateOnly(_now.toLocal());
    final first = _day.isBefore(today) ? _day : today;
    final last = DateTime(
      (_day.year > today.year ? _day.year : today.year) + 5,
      12,
      31,
    );
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: first,
      lastDate: last,
      helpText: 'Choose block date',
    );
    if (!mounted || selected == null) return;
    setState(() {
      _day = selected;
      _laterFold = false;
      _resetReview();
    });
  }

  Future<void> _chooseStart() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: _time,
      helpText: 'Choose start time',
    );
    if (!mounted || selected == null) return;
    setState(() {
      _time = selected;
      _laterFold = false;
      _resetReview();
    });
  }

  TimeSpan? _interval() {
    final minutes = int.tryParse(_duration.text.trim());
    if (minutes == null || minutes < 1 || minutes > maxManualBlockMinutes) {
      return null;
    }
    final (early, late) = _choices;
    final start = _laterFold ? late : early;
    return start == null
        ? null
        : TimeSpan(start, start.add(Duration(minutes: minutes)));
  }

  Future<void> _preview() async {
    if (_reviewing) return;
    final (early, _) = _choices;
    final span = _interval();
    if (span == null) {
      setState(() {
        _resetReview();
        _error = early == null
            ? 'This local time is skipped by a clock change.'
            : ManualBlockProblem.invalidDuration.message;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _resetReview();
      _reviewing = true;
    });
    try {
      final load = widget.loadContext;
      final records = load == null
          ? ManualBlockContext(
              tasks: widget.tasks,
              events: widget.events,
              settings: widget.settings,
            )
          : await load(span);
      if (!mounted) return;
      if (records == null) {
        setState(() => _error = 'Calendar availability could not be checked.');
        return;
      }
      final review = await compute(_reviewBlock, (
        taskId: widget.task.id,
        span: span,
        records: records,
        notBefore: _now,
        existingEventId: widget.existingBlock?.id,
      ));
      if (mounted) setState(() => _review = review);
    } catch (_) {
      if (mounted) setState(() => _error = 'This time could not be reviewed.');
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = MaterialLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    String timeOf(TimeOfDay time) => locale.formatTimeOfDay(
      time,
      alwaysUse24HourFormat: media.alwaysUse24HourFormat,
    );
    final isMove = widget.existingBlock != null;
    final (early, late) = _choices;
    final review = _review;
    final ready = review != null && review.problem == null;
    final remaining = review?.remainingEstimateMinutes;
    final selection = review?.approve(
      allowSoftDateOverride: _dateConfirmed,
      allowEstimateOverrun: _effortConfirmed,
    );
    final interval = _interval();
    final end = interval?.end.toLocal();
    final nextDay = end != null && !DateUtils.isSameDay(end, _day);
    final problem = review?.problem;
    final related = review?.relatedTitle;
    final error =
        _error ??
        (problem == null ? null : [problem.message, ?related].join('\n'));
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: media.size.width < 720 ? media.viewInsets.bottom : 0,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: media.size.height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 14, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 10,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              isMove ? 'Move time block' : 'Schedule task',
                              style: sectionHeadingStyle,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.task.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close time block',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _reviewing ? null : _chooseDate,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(locale.formatMediumDate(_day)),
                    ),
                    OutlinedButton.icon(
                      onPressed: _reviewing ? null : _chooseStart,
                      icon: const Icon(Icons.schedule_rounded),
                      label: Text(
                        timeOf(_time),
                        semanticsLabel: 'Start time ${timeOf(_time)}',
                      ),
                    ),
                  ],
                ),
                if (early != null && late != null && early != late)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use the later occurrence of this time'),
                    value: _laterFold,
                    onChanged: _reviewing
                        ? null
                        : (value) => setState(() {
                            _laterFold = value;
                            _resetReview();
                          }),
                  ),
                TextField(
                  controller: _duration,
                  enabled: !_reviewing,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Duration in minutes',
                  ),
                  onChanged: (_) => setState(_resetReview),
                  onSubmitted: (_) => _preview(),
                ),
                if (end != null)
                  Text(
                    'Ends ${timeOf(TimeOfDay.fromDateTime(end))}${nextDay ? ' · ${locale.formatMediumDate(end)}' : ''}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                if (ready && remaining != null)
                  Text(
                    '$remaining min estimated effort remaining',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                if (ready && review.requiresSoftDateOverride)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _dateConfirmed,
                    onChanged: (value) =>
                        setState(() => _dateConfirmed = value ?? false),
                    title: const Text(
                      'Allow a block outside the preferred date',
                    ),
                  ),
                if (ready && review.exceedsRemainingEstimate)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _effortConfirmed,
                    onChanged: (value) =>
                        setState(() => _effortConfirmed = value ?? false),
                    title: const Text(
                      'Allow more time than the remaining estimate',
                    ),
                  ),
                if (error != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(error, style: TextStyle(color: colors.error)),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: _reviewing
                        ? null
                        : ready
                        ? selection == null
                              ? null
                              : () => Navigator.pop(context, selection)
                        : _preview,
                    child: Text(
                      _reviewing
                          ? 'Checking time…'
                          : ready
                          ? (isMove ? 'Save time' : 'Schedule block')
                          : 'Review time',
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
}
