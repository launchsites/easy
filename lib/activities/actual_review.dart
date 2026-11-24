import 'package:material_ui/material_ui.dart';

import '../reminders/local_reminder.dart' show resolveReminderClock;
import '../ui_theme.dart';
import 'activity_actual_selection.dart';
import 'activity_model.dart';

export 'activity_actual_selection.dart';

Future<ActivityActualSelection?> showActivityActualReview(
  BuildContext context, {
  required ActivityActualTarget target,
  required ActivityData data,
  DateTime Function()? clock,
}) {
  final review = _ActualReview(target: target, data: data, clock: clock);
  if (MediaQuery.sizeOf(context).width < 720) {
    return showModalBottomSheet<ActivityActualSelection>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(top: false, child: review),
    );
  }
  return showDialog<ActivityActualSelection>(
    context: context,
    builder: (_) => Dialog(child: review),
  );
}

enum _ReviewStep { actions, manual, scheduled }

typedef _ClockDraft = ({DateTime day, TimeOfDay? time, bool? laterFold});
typedef _ClockChoices = ({DateTime? first, DateTime? last});

class _ActualReview extends StatefulWidget {
  const _ActualReview({required this.target, required this.data, this.clock});

  final ActivityActualTarget target;
  final ActivityData data;
  final DateTime Function()? clock;

  @override
  State<_ActualReview> createState() => _ActualReviewState();
}

class _ActualReviewState extends State<_ActualReview> {
  _ReviewStep _step = _ReviewStep.actions;
  String? _error;
  bool _endDateChosen = false;
  late _ClockDraft _start = (
    day: DateUtils.dateOnly(_now),
    time: null,
    laterFold: null,
  );
  late _ClockDraft _end = _start;

  DateTime get _now => (widget.clock ?? DateTime.now)().toLocal();

  void _stepTo(_ReviewStep value) => setState(() {
    _step = value;
    _error = null;
  });

  void _choose(ActivityActualSelection selection) {
    final problem = selection.issue(
      current: widget.data,
      target: widget.target,
      now: _now,
    );
    if (problem == null) {
      Navigator.pop(context, selection);
    } else {
      setState(() => _error = problem);
    }
  }

  _ClockDraft _endpoint(bool start) => start ? _start : _end;

  void _change(bool start, _ClockDraft value) {
    setState(() {
      if (start) {
        _start = value;
      } else {
        _end = value;
      }
      _error = null;
    });
  }

  Future<void> _pickDay(bool start) async {
    final endpoint = _endpoint(start);
    final today = DateUtils.dateOnly(_now);
    final existing = endpoint.day.isAfter(today) ? today : endpoint.day;
    final picked = await showDatePicker(
      context: context,
      initialDate: existing,
      firstDate: DateTime(1),
      lastDate: today,
      helpText: start ? 'Start date' : 'End date',
    );
    if (!mounted || picked == null) return;
    if (!start) _endDateChosen = true;
    if (start && !_endDateChosen && _end.time == null) {
      _end = (day: picked, time: null, laterFold: null);
    }
    _change(start, (day: picked, time: endpoint.time, laterFold: null));
  }

  Future<void> _pickTime(bool start) async {
    final endpoint = _endpoint(start);
    final value = await showTimePicker(
      context: context,
      initialTime: endpoint.time ?? _start.time ?? TimeOfDay.fromDateTime(_now),
      helpText: start ? 'Start time' : 'End time',
    );
    if (!mounted || value == null) return;
    _change(start, (day: endpoint.day, time: value, laterFold: null));
  }

  _ClockChoices _clockChoices(_ClockDraft endpoint) {
    final time = endpoint.time;
    if (time == null) return (first: null, last: null);
    final day = endpoint.day;
    final wall = DateTime.utc(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    );
    return (
      first: resolveReminderClock(wall),
      last: resolveReminderClock(wall, laterFold: true),
    );
  }

  DateTime? _exact(_ClockDraft endpoint) {
    final choices = _clockChoices(endpoint);
    if (choices.first == choices.last) return choices.first;
    return switch (endpoint.laterFold) {
      true => choices.last,
      false => choices.first,
      null => null,
    };
  }

  void _confirmManual() {
    final start = _exact(_start);
    final end = _exact(_end);
    if (start == null || end == null) {
      setState(() => _error = 'Choose an exact start and end time.');
      return;
    }
    if (!end.isAfter(start)) {
      setState(() => _error = 'End time must be after start time.');
      return;
    }
    _choose(
      ActivityActualSelection.manualTimes(
        widget.target,
        ActivityWindow(start, end),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final compact = MediaQuery.sizeOf(context).width < 380;
    final scheduled = widget.target.scheduled;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 440,
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsetsDirectional.fromSTEB(
          compact ? 16 : 22,
          12,
          compact ? 16 : 22,
          20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_step != _ReviewStep.actions)
                  BackButton(onPressed: () => _stepTo(_ReviewStep.actions)),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      switch (_step) {
                        _ReviewStep.actions => 'Track time',
                        _ReviewStep.manual => 'Log actual time',
                        _ReviewStep.scheduled => 'Use scheduled times?',
                      },
                      style: sectionHeadingStyle.copyWith(
                        fontSize: compact ? 25 : 28,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close time review',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              widget.target.record.title,
              style: contentTitleStyle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            switch (_step) {
              _ReviewStep.actions => _actions(scheduled),
              _ReviewStep.manual => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _clockFields(start: true),
                  const SizedBox(height: 12),
                  _clockFields(start: false),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _confirmManual,
                    child: const Text('Log these times'),
                  ),
                ],
              ),
              _ReviewStep.scheduled => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _scheduledRow('Start', scheduled!.start, localizations),
                  _scheduledRow('End', scheduled.end, localizations),
                  const SizedBox(height: 10),
                  Text(
                    'Confirm these were the times you actually spent.',
                    style: contentMetadataStyle,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _choose(
                      ActivityActualSelection.scheduledTimes(widget.target),
                    ),
                    child: const Text('Confirm scheduled times'),
                  ),
                ],
              ),
            },
            if (_error case final issue?) ...[
              const SizedBox(height: 9),
              Semantics(
                liveRegion: true,
                child: Text(issue, style: TextStyle(color: colors.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(ActivityWindow? scheduled) {
    final active = widget.data.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start timer'),
          onPressed: active == null
              ? () => _choose(ActivityActualSelection.startTimer(widget.target))
              : null,
        ),
        if (active != null)
          Text(
            '${active.status == ActivityStatus.paused ? 'Paused' : 'Tracking'} · ${active.title}',
            style: contentMetadataStyle,
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.edit_calendar_outlined),
          label: const Text('Log actual time'),
          onPressed: () => _stepTo(_ReviewStep.manual),
        ),
        if (scheduled != null && !scheduled.end.isAfter(_now))
          TextButton(
            onPressed: () => _stepTo(_ReviewStep.scheduled),
            child: const Text('Use scheduled times'),
          ),
      ],
    );
  }

  Widget _clockFields({required bool start}) {
    final endpoint = _endpoint(start);
    final localizations = MaterialLocalizations.of(context);
    final choices = _clockChoices(endpoint);
    final label = start ? 'Start' : 'End';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: contentTitleStyle),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton(
              onPressed: () => _pickDay(start),
              child: Text(
                localizations.formatMediumDate(endpoint.day),
                semanticsLabel:
                    '$label date ${localizations.formatMediumDate(endpoint.day)}',
              ),
            ),
            OutlinedButton(
              onPressed: () => _pickTime(start),
              child: Text(
                endpoint.time?.format(context) ?? 'Choose time',
                semanticsLabel:
                    '$label time ${endpoint.time?.format(context) ?? 'not set'}',
              ),
            ),
          ],
        ),
        if (endpoint.time != null && choices.first == null)
          Text(
            'This clock time is skipped on that date.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (choices.first != choices.last) ...[
          Text('This clock time occurs twice.', style: contentMetadataStyle),
          Wrap(
            spacing: 8,
            children: [
              for (final later in [false, true])
                ChoiceChip(
                  label: Text(later ? 'Second occurrence' : 'First occurrence'),
                  selected: endpoint.laterFold == later,
                  onSelected: (_) => _change(start, (
                    day: endpoint.day,
                    time: endpoint.time,
                    laterFold: later,
                  )),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _scheduledRow(
    String label,
    DateTime value,
    MaterialLocalizations format,
  ) {
    final local = value.toLocal();
    final day = format.formatMediumDate(local);
    final time = TimeOfDay.fromDateTime(local).format(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text('$label · $day, $time'),
    );
  }
}
