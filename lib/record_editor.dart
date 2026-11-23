import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';

enum RecordKind { task, event, note }

class RecordEditor extends StatefulWidget {
  const RecordEditor({
    required this.date,
    required this.kind,
    this.event,
    this.task,
    this.note,
    this.initialTaskDate,
    this.initialCategory,
    super.key,
  });

  final DateTime date;
  final RecordKind kind;
  final CalendarEvent? event;
  final TaskItem? task;
  final NoteItem? note;
  final DateTime? initialTaskDate;
  final String? initialCategory;

  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  static const _ink = Color(0xFF202521);
  static const _muted = Color(0xFF696E66);
  static const _paper = Color(0xFFFAF9F6);
  static const _line = Color(0xFFE9E8E1);
  static const _accent = Color(0xFF466955);
  static const _categories = ['personal', 'work', 'study', 'health'];

  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _body;
  late RecordKind _kind;
  late String _category;
  late DateTime _startDate;
  late DateTime _endDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late bool _allDay;
  DateTime? _dueDate;
  String? _eventError;

  bool get _editing =>
      widget.event != null || widget.task != null || widget.note != null;

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    final task = widget.task;
    final note = widget.note;
    _kind = widget.kind;
    _title = TextEditingController(
      text: event?.title ?? task?.title ?? note?.title,
    );
    _location = TextEditingController(text: event?.location);
    _body = TextEditingController(text: note?.body);
    _category =
        event?.category ??
        task?.category ??
        widget.initialCategory ??
        _categories.first;
    _dueDate = task == null ? widget.initialTaskDate : task.date;
    _allDay = event?.allDay ?? false;

    final now = DateTime.now();
    final day = DateUtils.dateOnly(widget.date);
    final defaultHour = DateUtils.isSameDay(now, day) && now.hour < 23
        ? now.hour + 1
        : 9;
    final defaultStart = DateTime(day.year, day.month, day.day, defaultHour);
    final start = event?.start ?? defaultStart;
    final end = event?.end ?? defaultStart.add(const Duration(hours: 1));
    _startDate = DateUtils.dateOnly(start);
    _endDate = _allDay && end.isAfter(start) && end == DateUtils.dateOnly(end)
        ? _shiftDay(end, -1)
        : DateUtils.dateOnly(end);
    _startTime = _allDay
        ? const TimeOfDay(hour: 9, minute: 0)
        : TimeOfDay.fromDateTime(start);
    _endTime = _allDay
        ? const TimeOfDay(hour: 10, minute: 0)
        : TimeOfDay.fromDateTime(end);
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _body.dispose();
    super.dispose();
  }

  DateTime _shiftDay(DateTime day, int offset) =>
      DateTime(day.year, day.month, day.day + offset);

  DateTime _combine(DateTime day, TimeOfDay time) =>
      DateTime(day.year, day.month, day.day, time.hour, time.minute);

  DateTime get _start => _combine(_startDate, _startTime);
  DateTime get _end => _combine(_endDate, _endTime);

  Future<DateTime?> _pickDate(DateTime date, String label) => showDatePicker(
    context: context,
    initialDate: date,
    firstDate: DateTime(date.year < 1900 ? date.year : 1900),
    lastDate: DateTime(date.year > 2200 ? date.year : 2200, 12, 31),
    helpText: label,
  );

  Future<void> _changeStartDate() async {
    final date = await _pickDate(_startDate, 'Choose start date');
    if (!mounted || date == null) return;
    final daySpan = DateTime.utc(_endDate.year, _endDate.month, _endDate.day)
        .difference(
          DateTime.utc(_startDate.year, _startDate.month, _startDate.day),
        )
        .inDays;
    setState(() {
      _startDate = date;
      _endDate = _shiftDay(date, daySpan);
      _eventError = null;
    });
  }

  Future<void> _changeEndDate() async {
    final date = await _pickDate(_endDate, 'Choose end date');
    if (!mounted || date == null) return;
    setState(() {
      _endDate = date;
      _eventError = null;
    });
  }

  Future<void> _changeStartTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _startTime,
      helpText: 'Choose start time',
    );
    if (!mounted || time == null) return;
    final previousDuration = _end.difference(_start);
    final duration = previousDuration > Duration.zero
        ? previousDuration
        : const Duration(hours: 1);
    setState(() {
      _startTime = time;
      final end = _start.add(duration);
      _endTime = TimeOfDay.fromDateTime(end);
      _endDate = DateUtils.dateOnly(end);
      _eventError = null;
    });
  }

  Future<void> _changeEndTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _endTime,
      helpText: 'Choose end time',
    );
    if (!mounted || time == null) return;
    setState(() {
      _endTime = time;
      _eventError = null;
    });
  }

  Future<void> _changeDueDate() async {
    final date = await _pickDate(_dueDate ?? widget.date, 'Choose a due date');
    if (!mounted || date == null) return;
    setState(() => _dueDate = date);
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final title = _title.text.trim();
    final now = DateTime.now();
    final newId = now.microsecondsSinceEpoch.toString();
    switch (_kind) {
      case RecordKind.task:
        Navigator.of(context).pop(
          TaskItem(
            id: widget.task?.id ?? newId,
            title: title,
            category: _category,
            date: _dueDate,
            done: widget.task?.done ?? false,
          ),
        );
      case RecordKind.event:
        final start = _allDay ? _startDate : _start;
        final end = _allDay ? _shiftDay(_endDate, 1) : _end;
        if (!end.isAfter(start)) {
          setState(() {
            _eventError = _allDay
                ? 'End date must be on or after the start date.'
                : 'End time must be after the start time.';
          });
          return;
        }
        final location = _location.text.trim();
        Navigator.of(context).pop(
          CalendarEvent(
            id: widget.event?.id ?? newId,
            title: title,
            start: start,
            end: end,
            category: _category,
            allDay: _allDay,
            location: location.isEmpty ? null : location,
          ),
        );
      case RecordKind.note:
        Navigator.of(context).pop(
          NoteItem(
            id: widget.note?.id ?? newId,
            title: title,
            body: _body.text,
            updated: now,
          ),
        );
    }
  }

  String _label(String value) => value.isEmpty
      ? 'Uncategorised'
      : value[0].toUpperCase() + value.substring(1);

  String _dateLabel(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date);

  String _timeLabel(TimeOfDay time) => MaterialLocalizations.of(context)
      .formatTimeOfDay(
        time,
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  InputDecoration _decoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white,
      floatingLabelStyle: const TextStyle(color: _accent),
      labelStyle: const TextStyle(color: _muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
    );
  }

  Widget _kindSelector() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF0EFEA),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (final kind in RecordKind.values)
              Expanded(
                child: Semantics(
                  selected: _kind == kind,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: _kind == kind ? _ink : _muted,
                      backgroundColor: _kind == kind ? Colors.white : null,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => setState(() => _kind = kind),
                    child: Text(_label(kind.name)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryField() {
    final categories = {..._categories, _category};
    return DropdownButtonFormField<String>(
      initialValue: _category,
      decoration: _decoration('Space'),
      isExpanded: true,
      items: [
        for (final category in categories)
          DropdownMenuItem(value: category, child: Text(_label(category))),
      ],
      onChanged: (category) {
        if (category != null) setState(() => _category = category);
      },
    );
  }

  Widget _dateButton({
    required String label,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: _ink,
          backgroundColor: Colors.white,
          side: const BorderSide(color: _line),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        onPressed: onPressed,
      ),
    );
  }

  Widget _eventTimeRow({
    required bool start,
    required DateTime date,
    required TimeOfDay time,
  }) {
    final label = start ? 'Starts' : 'Ends';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: _muted, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _dateButton(
              label: _dateLabel(date),
              tooltip: '$label on',
              icon: Icons.calendar_today_outlined,
              onPressed: start ? _changeStartDate : _changeEndDate,
            ),
            if (!_allDay)
              _dateButton(
                label: _timeLabel(time),
                tooltip: '$label at',
                icon: Icons.schedule_outlined,
                onPressed: start ? _changeStartTime : _changeEndTime,
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _eventFields() {
    return [
      SwitchListTile.adaptive(
        value: _allDay,
        contentPadding: EdgeInsets.zero,
        title: const Text('All day'),
        onChanged: (value) => setState(() {
          _allDay = value;
          _eventError = null;
        }),
      ),
      const SizedBox(height: 8),
      _eventTimeRow(start: true, date: _startDate, time: _startTime),
      const SizedBox(height: 12),
      _eventTimeRow(start: false, date: _endDate, time: _endTime),
      if (_eventError case final error?) ...[
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
      const SizedBox(height: 16),
      TextFormField(
        controller: _location,
        decoration: _decoration('Location', hint: 'Optional'),
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: 12),
      _categoryField(),
    ];
  }

  List<Widget> _taskFields() {
    final date = _dueDate;
    return [
      _categoryField(),
      const SizedBox(height: 14),
      Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _dateButton(
            label: date == null ? 'Add a due date' : _dateLabel(date),
            tooltip: 'Set due date',
            icon: Icons.event_outlined,
            onPressed: _changeDueDate,
          ),
          if (date != null)
            IconButton(
              tooltip: 'Remove due date',
              onPressed: () => setState(() => _dueDate = null),
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final padding = MediaQuery.viewInsetsOf(context);
    return AnimatedPadding(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: mobile ? padding.bottom : 0),
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: mobile,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Material(
            color: _paper,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                mobile ? 20 : 26,
                18,
                mobile ? 20 : 26,
                22,
              ),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _editing
                                ? 'Edit ${_kind.name}'
                                : 'New ${_kind.name}',
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 25,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.65,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (!_editing) ...[
                      _kindSelector(),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _title,
                      autofocus: !_editing,
                      decoration: _decoration('Title'),
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter a title.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    ...switch (_kind) {
                      RecordKind.task => _taskFields(),
                      RecordKind.event => _eventFields(),
                      RecordKind.note => [
                        TextFormField(
                          controller: _body,
                          decoration: _decoration(
                            'Note',
                            hint: 'Write a note or paste Markdown',
                          ),
                          minLines: 4,
                          maxLines: 12,
                          keyboardType: TextInputType.multiline,
                          textCapitalization: TextCapitalization.sentences,
                        ),
                      ],
                    },
                    const SizedBox(height: 22),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton(
                        onPressed: _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(112, 46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                        child: Text(
                          _editing ? 'Save changes' : 'Add ${_kind.name}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
