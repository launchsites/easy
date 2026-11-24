import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance/appearance.dart' show readableTint;
import 'calendar_page.dart';
import 'capture/capture_review_sheet.dart' show CaptureReviewRequest;
import 'capture/task_category_hint.dart';
import 'capture_text.dart';
import 'categories/category_palette.dart';
import 'list_pages.dart';
import 'record_editor.dart' show RecordKind;
import 'ui_theme.dart'
    show accent, ink, line, muted, paper, raisedPaper, softAccent;
import 'workspace_data.dart' show spaceColors, spaceName;

class QuickCapture extends StatefulWidget {
  const QuickCapture({
    required this.date,
    required this.kind,
    this.initialCategory,
    this.initialTaskCategory,
    this.initialTaskDate,
    this.noteToSelf = false,
    this.allowReview = false,
    this.allowVoice = false,
    this.categories = const {},
    super.key,
  });

  final DateTime date;
  final RecordKind kind;
  final String? initialCategory;
  final String? initialTaskCategory;
  final DateTime? initialTaskDate;
  final bool noteToSelf;
  final bool allowReview;
  final bool allowVoice;
  final Map<String, String> categories;

  @override
  State<QuickCapture> createState() => _QuickCaptureState();
}

enum _CaptureStep { text, start, end }

class VoiceCaptureRequest {
  const VoiceCaptureRequest(this.text);

  final String text;
}

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
  String? _selectedCategory;
  bool _categoryChosen = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String? get _noteCategory =>
      _categoryChosen ? _selectedCategory : widget.initialCategory;
  Iterable<String> get _categoryIds =>
      widget.categories.isNotEmpty ||
          WorkspaceCategoryPalette.maybeOf(context) != null
      ? widget.categories.keys
      : spaceColors.keys;

  String get _category => _categoryChosen
      ? _selectedCategory ?? ''
      : (_kind == RecordKind.task
                ? taskCategoryHint(_text.text, {..._categoryIds})
                : null) ??
            (_kind == RecordKind.task ? widget.initialTaskCategory : null) ??
            _noteCategory ??
            (_categoryIds.contains('personal') ? 'personal' : '');

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
            schedulingHold: taskSchedulingHoldHint(task.title),
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
            category: _noteCategory,
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
    return Wrap(
      spacing: 2,
      children: [
        for (final option in options.entries)
          Semantics(
            selected: _kind == option.key,
            child: TextButton(
              onPressed: () => _changeKind(option.key),
              style: TextButton.styleFrom(
                foregroundColor: _kind == option.key ? accent : muted,
                backgroundColor: _kind == option.key ? softAccent : null,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
                textStyle: labelStyle,
              ),
              child: Text(
                option.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }

  Widget _categoryChoice() {
    final current = _kind == RecordKind.note ? _noteCategory : _category;
    final catalog = WorkspaceCategoryPalette.of(context);
    final activeIds = _categoryIds;
    final label = widget.categories[current] ?? catalog.labelFor(current);
    final tint = current == null || current.isEmpty
        ? muted
        : WorkspaceCategoryPalette.colorFor(context, current);
    Widget button(VoidCallback onPressed) => Tooltip(
      message: 'Choose category',
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded, size: 16),
        iconAlignment: IconAlignment.end,
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          foregroundColor: readableTint(tint, surface: paper, foreground: ink),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
    if (activeIds.length > 8 ||
        catalog.categories.any((entry) => entry.parentId != null)) {
      return button(() async {
        final selected = await showWorkspaceCategoryPicker(
          context,
          categories: catalog,
          selectedId: current,
        );
        if (mounted && selected != null) _chooseCategory(selected);
      });
    }
    return MenuAnchor(
      builder: (_, controller, _) => button(
        () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => _chooseCategory(''),
          child: const Text('General'),
        ),
        for (final category in activeIds)
          MenuItemButton(
            onPressed: () => _chooseCategory(category),
            leadingIcon: Icon(
              Icons.circle,
              color: WorkspaceCategoryPalette.colorFor(context, category),
              size: 8,
            ),
            trailingIcon: current == category
                ? const Icon(Icons.check_rounded, size: 17)
                : null,
            child: Text(widget.categories[category] ?? spaceName(category)),
          ),
      ],
    );
  }

  void _chooseCategory(String? category) {
    setState(() {
      _categoryChosen = true;
      _selectedCategory = category?.isEmpty == true ? null : category;
    });
    _focus.requestFocus();
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
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < 720;
    final horizontalPadding = width < 360 ? 14.0 : (mobile ? 18.0 : 21.0);
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
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.allowVoice && _step == _CaptureStep.text)
          IconButton(
            tooltip: 'Record voice',
            onPressed: () => _finish(VoiceCaptureRequest(_text.text)),
            icon: const Icon(Icons.mic_none_rounded, color: muted),
          ),
        if (widget.allowReview && _step == _CaptureStep.text)
          IconButton(
            tooltip: 'Open capture review',
            onPressed: () => _finish(CaptureReviewRequest(_text.text)),
            icon: const Icon(Icons.playlist_add_rounded, color: muted),
          ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, color: muted, size: 19),
        ),
      ],
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
                    horizontalPadding,
                    8,
                    horizontalPadding,
                    16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.noteToSelf)
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Note to self',
                                style: TextStyle(
                                  color: ink,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.25,
                                ),
                              ),
                            ),
                            actions,
                          ],
                        )
                      else
                        OverflowBar(
                          alignment: MainAxisAlignment.spaceBetween,
                          overflowAlignment: OverflowBarAlignment.end,
                          overflowSpacing: 3,
                          children: [_kindSelector(), actions],
                        ),
                      const SizedBox(height: 9),
                      _bar(action),
                      if (input.isNotEmpty || event != null) ...[
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
                        Wrap(
                          spacing: 9,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (summary.isNotEmpty)
                              Text(
                                summary,
                                style: const TextStyle(color: muted),
                              ),
                            _categoryChoice(),
                          ],
                        ),
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
