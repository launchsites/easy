import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'capture_text.dart';
import 'list_pages.dart';
import 'record_editor.dart' show RecordKind;
import 'ui_theme.dart'
    show accent, ink, line, muted, paper, raisedPaper, softAccent;

class QuickCapture extends StatefulWidget {
  const QuickCapture({
    required this.date,
    required this.kind,
    this.initialCategory,
    this.initialTaskDate,
    this.noteToSelf = false,
    super.key,
  });

  final DateTime date;
  final RecordKind kind;
  final String? initialCategory;
  final DateTime? initialTaskDate;
  final bool noteToSelf;

  @override
  State<QuickCapture> createState() => _QuickCaptureState();
}

enum _CaptureStep { text, start, end }

class _QuickCaptureState extends State<QuickCapture> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _openedAt = DateTime.now();
  late RecordKind _kind = widget.noteToSelf ? RecordKind.note : widget.kind;
  _CaptureStep _step = _CaptureStep.text;
  _EventDraft? _event;
  String? _error;
  String _eventText = '';
  bool _finished = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _category => widget.initialCategory ?? 'personal';

  EventCaptureText _parseEvent(String input) =>
      parseEventCapture(input, date: widget.date, now: _openedAt);

  TaskCaptureText _parseTask(String input) =>
      parseTaskCapture(input, date: widget.date, now: _openedAt);

  void _setError(String message) {
    setState(() => _error = message);
    _focus.requestFocus();
  }

  void _changeKind(RecordKind kind) {
    if (_kind == kind) return;
    setState(() {
      if (_step != _CaptureStep.text) _restoreEventText();
      _kind = kind;
      _error = null;
    });
    _focus.requestFocus();
  }

  void _restoreEventText() {
    _step = _CaptureStep.text;
    _event = null;
    _error = null;
    _text.value = TextEditingValue(
      text: _eventText,
      selection: TextSelection.collapsed(offset: _eventText.length),
    );
  }

  void _ask(_CaptureStep step) {
    setState(() {
      _step = step;
      _error = null;
      _text.clear();
    });
    _focus.requestFocus();
  }

  void _finish(Object record) {
    if (_finished) return;
    _finished = true;
    Navigator.of(context).pop(record);
  }

  void _submit() {
    if (_finished) return;
    final input = _text.text.trim();
    if (_step != _CaptureStep.text) {
      _submitEventAnswer(input);
      return;
    }
    if (input.isEmpty) {
      _setError('Enter a ${_kind.name}.');
      return;
    }
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    switch (_kind) {
      case RecordKind.task:
        final task = _parseTask(input);
        if (task.title.isEmpty) {
          _setError('Enter a task name.');
          return;
        }
        _finish(
          TaskItem(
            id: id,
            title: task.title,
            category: _category,
            date: task.dueDate ?? widget.initialTaskDate,
            done: false,
          ),
        );
      case RecordKind.event:
        final parsed = _parseEvent(input);
        if (parsed.error case final error?) {
          _setError(error);
          return;
        }
        if (parsed.title.isEmpty) {
          _setError('Enter an event name.');
          return;
        }
        _eventText = _text.text;
        _event = _EventDraft(parsed);
        _advanceEvent();
      case RecordKind.note:
        final breakAt = input.indexOf('\n');
        _finish(
          NoteItem(
            id: id,
            title: breakAt < 0 ? input : input.substring(0, breakAt).trim(),
            body: breakAt < 0 ? '' : input.substring(breakAt + 1).trim(),
            updated: now,
            category: widget.initialCategory,
            noteToSelf: widget.noteToSelf,
          ),
        );
    }
  }

  void _submitEventAnswer(String input) {
    final event = _event!;
    switch (_step) {
      case _CaptureStep.text:
        return;
      case _CaptureStep.start:
        if (input.toLowerCase() == 'all day') {
          _useAllDay();
          return;
        }
        final start = parseCaptureTime(input, date: event.date);
        if (start == null) {
          _setError('Enter a time such as 9am or 14:30.');
          return;
        }
        event.start = start;
        event.end ??= event.duration == null
            ? null
            : start.add(event.duration!);
        _advanceEvent();
      case _CaptureStep.end:
        final overnight = RegExp(r'\s+next day$', caseSensitive: false);
        final nextDay = overnight.hasMatch(input);
        final start = event.start!;
        final date = nextDay ? DateUtils.addDaysToDate(start, 1) : start;
        final end = parseCaptureTime(
          input.replaceFirst(overnight, ''),
          date: date,
        );
        if (end == null) {
          _setError('Enter a time such as 10am or 15:30.');
          return;
        }
        if (!end.isAfter(start)) {
          _setError(
            'End time must be after the start. Add “next day” for an overnight event.',
          );
          return;
        }
        event.end = end;
        _advanceEvent();
    }
  }

  void _useAllDay() {
    _event!.allDay = true;
    _advanceEvent();
  }

  void _useHour() {
    final event = _event!;
    event.end = event.start!.add(const Duration(hours: 1));
    _advanceEvent();
  }

  void _advanceEvent() {
    final event = _event!;
    if (!event.allDay && event.start == null) {
      _ask(_CaptureStep.start);
      return;
    }
    if (!event.allDay && event.end == null) {
      _ask(_CaptureStep.end);
      return;
    }
    _finish(
      CalendarEvent(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: event.title,
        start: event.allDay ? event.date : event.start!,
        end: event.allDay ? DateUtils.addDaysToDate(event.date, 1) : event.end!,
        category: _category,
        allDay: event.allDay,
        location: event.location,
      ),
    );
  }

  String _formatDate(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date);

  String _formatTime(DateTime time) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(time),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  String _eventSummary(_EventDraft event) {
    final start = event.start;
    final end = event.end;
    return [
      _formatDate(event.date),
      if (event.allDay)
        'All day'
      else if (start != null)
        end == null
            ? _formatTime(start)
            : '${_formatTime(start)}–'
                  '${DateUtils.isSameDay(start, end) ? '' : '${_formatDate(end)}, '}${_formatTime(end)}',
      ?event.location,
    ].join(' · ');
  }

  String? get _label => switch (_step) {
    _CaptureStep.start => 'Start time',
    _CaptureStep.end => 'End time',
    _CaptureStep.text => null,
  };

  String get _hint => switch (_step) {
    _CaptureStep.start => 'e.g. 9am',
    _CaptureStep.end => 'e.g. 10am',
    _CaptureStep.text => switch (_kind) {
      RecordKind.task => 'What needs doing?',
      RecordKind.event => 'Coffee tomorrow, 10–11am',
      RecordKind.note =>
        widget.noteToSelf ? 'What’s on your mind?' : 'Write a note…',
    },
  };

  Widget _kindSelector() {
    final labelStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(fontWeight: FontWeight.w600);
    const options = {
      RecordKind.task: 'Task',
      RecordKind.event: 'Event',
      RecordKind.note: 'Note',
    };
    return Row(
      children: [
        for (final option in options.entries)
          Flexible(
            child: Semantics(
              selected: _kind == option.key,
              child: TextButton(
                onPressed: () => _changeKind(option.key),
                style: TextButton.styleFrom(
                  foregroundColor: _kind == option.key ? accent : muted,
                  backgroundColor: _kind == option.key ? softAccent : null,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  textStyle: labelStyle,
                ),
                child: Text(option.value),
              ),
            ),
          ),
      ],
    );
  }

  Widget _bar(String action) {
    final multiline = _kind == RecordKind.note;
    final radius = BorderRadius.circular(14);
    return TextFormField(
      controller: _text,
      focusNode: _focus,
      autofocus: true,
      maxLines: multiline ? 4 : 1,
      minLines: 1,
      textInputAction: multiline
          ? TextInputAction.newline
          : TextInputAction.done,
      keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
      textCapitalization: _step == _CaptureStep.text
          ? TextCapitalization.sentences
          : TextCapitalization.none,
      autocorrect: _step == _CaptureStep.text,
      onEditingComplete: () {},
      onFieldSubmitted: multiline ? null : (_) => _submit(),
      onChanged: (_) => setState(() => _error = null),
      style: const TextStyle(color: ink, fontSize: 16),
      decoration: InputDecoration(
        labelText: _label,
        hintText: _hint,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: const TextStyle(color: muted),
        floatingLabelStyle: const TextStyle(color: accent),
        hintStyle: const TextStyle(color: muted, fontSize: 14),
        contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 13, 7, 13),
        filled: true,
        fillColor: raisedPaper,
        border: OutlineInputBorder(borderRadius: radius),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        suffixIcon: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 5, 5, 5),
          child: IconButton.filled(
            tooltip: action,
            style: IconButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              minimumSize: const Size.square(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            onPressed: _submit,
            icon: Icon(
              action == 'Next'
                  ? Icons.arrow_forward_rounded
                  : Icons.arrow_upward_rounded,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  Widget? _stepShortcut() {
    return switch (_step) {
      _CaptureStep.text => null,
      _CaptureStep.start => TextButton(
        onPressed: _useAllDay,
        child: const Text('All day'),
      ),
      _CaptureStep.end => TextButton(
        onPressed: _useHour,
        child: const Text('Use 1 hour'),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final input = _text.text.trim();
    final event =
        _event ??
        (_kind == RecordKind.event && input.isNotEmpty
            ? _EventDraft(_parseEvent(input))
            : null);
    final task = _kind == RecordKind.task && input.isNotEmpty
        ? _parseTask(input)
        : null;
    final dueDate = task == null
        ? null
        : task.dueDate ?? widget.initialTaskDate;
    final summary = event != null
        ? _eventSummary(event)
        : dueDate == null
        ? ''
        : 'Due ${_formatDate(dueDate)}';
    final parsedTitle = event?.title ?? task?.title;
    final showTitle =
        parsedTitle != null && parsedTitle.isNotEmpty && parsedTitle != input;
    final action =
        _kind == RecordKind.event &&
            switch (_step) {
              _CaptureStep.text =>
                event != null &&
                    !event.allDay &&
                    (event.start == null || event.end == null),
              _CaptureStep.start =>
                event?.duration == null && event?.end == null,
              _CaptureStep.end => false,
            }
        ? 'Next'
        : 'Add ${_kind.name}';
    final stepShortcut = _stepShortcut();
    final close = IconButton(
      tooltip: 'Close',
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.close_rounded, color: muted, size: 19),
    );
    return AnimatedPadding(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      padding: EdgeInsets.only(
        bottom: mobile ? MediaQuery.viewInsetsOf(context).bottom : 0,
      ),
      child: Material(
        color: paper,
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          bottom: mobile,
          child: Align(
            alignment: Alignment.topCenter,
            widthFactor: 1,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 525),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                  ): _submit,
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                      _submit,
                },
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    mobile ? 18 : 21,
                    8,
                    mobile ? 18 : 21,
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: widget.noteToSelf
                                ? const Text(
                                    'Note to self',
                                    style: TextStyle(
                                      color: ink,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.25,
                                    ),
                                  )
                                : _kindSelector(),
                          ),
                          close,
                        ],
                      ),
                      const SizedBox(height: 9),
                      _bar(action),
                      if (showTitle || summary.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        if (showTitle)
                          Text(
                            parsedTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (summary.isNotEmpty)
                          Text(summary, style: const TextStyle(color: muted)),
                      ],
                      if (_error case final error?) ...[
                        const SizedBox(height: 8),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                      if (stepShortcut != null)
                        Wrap(
                          spacing: 8,
                          alignment: WrapAlignment.spaceBetween,
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(_restoreEventText);
                                _focus.requestFocus();
                              },
                              child: const Text('Edit event text'),
                            ),
                            stepShortcut,
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EventDraft {
  _EventDraft(EventCaptureText parsed)
    : title = parsed.title,
      date = parsed.date,
      start = parsed.start,
      end = parsed.end,
      duration = parsed.duration,
      allDay = parsed.allDay,
      location = parsed.location;

  final String title;
  final DateTime date;
  final Duration? duration;
  final String? location;
  bool allDay;
  DateTime? start;
  DateTime? end;
}
