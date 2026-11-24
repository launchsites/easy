import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'ui_theme.dart' show accent, ink, line, muted, paper, raisedPaper;
import 'workspace_data.dart' show spaceColor, spaceColors, spaceName;

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
  static const _wash = Color(0xFFF1F1EB);

  final _form = GlobalKey<FormState>();
  final _titleFocus = FocusNode();
  final _eventErrorKey = GlobalKey();
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
        'personal';
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
    _titleFocus.dispose();
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
    if (!_form.currentState!.validate()) {
      _titleFocus.requestFocus();
      return;
    }
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
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final errorContext = _eventErrorKey.currentContext;
            if (errorContext != null) Scrollable.ensureVisible(errorContext);
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
            category: widget.note == null
                ? widget.initialCategory
                : widget.note!.category,
            noteToSelf: widget.note?.noteToSelf ?? false,
          ),
        );
    }
  }

  String _dateLabel(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date);

  String _timeLabel(TimeOfDay time) => MaterialLocalizations.of(context)
      .formatTimeOfDay(
        time,
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  InputDecoration _decoration(String label) {
    final radius = BorderRadius.circular(11);
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: raisedPaper,
      floatingLabelStyle: const TextStyle(color: accent),
      labelStyle: const TextStyle(color: muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: accent, width: 1.5),
      ),
    );
  }

  Widget _kindSelector() {
    final showIcons = MediaQuery.textScalerOf(context).scale(14) <= 18;
    final labelStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(fontWeight: FontWeight.w600);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _wash,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            for (final kind in RecordKind.values)
              Expanded(
                child: Semantics(
                  selected: _kind == kind,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: _kind == kind ? ink : muted,
                      backgroundColor: _kind == kind ? Colors.white : null,
                      side: BorderSide(
                        color: _kind == kind ? line : Colors.transparent,
                      ),
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                      textStyle: labelStyle,
                    ),
                    onPressed: () => setState(() => _kind = kind),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (showIcons) ...[
                          Icon(
                            switch (kind) {
                              RecordKind.task => Icons.check_box_outlined,
                              RecordKind.event => Icons.calendar_today_outlined,
                              RecordKind.note => Icons.notes_rounded,
                            },
                            size: 16,
                            color: _kind == kind ? accent : muted,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(child: Text(spaceName(kind.name))),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _spaceRow() {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      builder: (context, controller, _) => _propertyButton(
        label: 'Space',
        value: spaceName(_category),
        icon: Icons.folder_outlined,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        for (final category in {...spaceColors.keys, _category})
          MenuItemButton(
            leadingIcon: Icon(
              Icons.circle,
              color: spaceColor(category),
              size: 8,
            ),
            trailingIcon: category == _category
                ? const Icon(Icons.check_rounded, color: accent, size: 16)
                : null,
            onPressed: () => setState(() => _category = category),
            child: Semantics(
              selected: category == _category,
              child: Text(spaceName(category)),
            ),
          ),
      ],
    );
  }

  Widget _propertyPanel(List<Widget> rows) {
    return Material(
      color: raisedPaper,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const Divider(height: 1, thickness: 1, color: line),
            rows[index],
          ],
        ],
      ),
    );
  }

  Widget _propertyButton({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback onPressed,
    bool showChevron = true,
    Color valueColor = muted,
  }) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            child: Row(
              children: [
                Icon(icon, size: 17, color: muted),
                const SizedBox(width: 9),
                Expanded(
                  flex: 3,
                  child: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  flex: 5,
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: TextStyle(color: valueColor),
                  ),
                ),
                if (showChevron) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more_rounded, size: 17, color: muted),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeButton({
    required String label,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }

  Widget _eventTimeRow({
    required bool start,
    required DateTime date,
    required TimeOfDay time,
  }) {
    final label = start ? 'Starts' : 'Ends';
    return Row(
      children: [
        Expanded(
          flex: 7,
          child: _propertyButton(
            label: label,
            value: _dateLabel(date),
            icon: Icons.calendar_today_outlined,
            showChevron: _allDay,
            valueColor: accent,
            onPressed: start ? _changeStartDate : _changeEndDate,
          ),
        ),
        if (!_allDay)
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 5),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _timeButton(
                  label: _timeLabel(time),
                  tooltip: start ? 'Change start time' : 'Change end time',
                  onPressed: start ? _changeStartTime : _changeEndTime,
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _eventFields() {
    return [
      _propertyPanel([
        ListTileTheme(
          data: const ListTileThemeData(
            minLeadingWidth: 17,
            horizontalTitleGap: 9,
          ),
          child: SwitchListTile.adaptive(
            value: _allDay,
            contentPadding: const EdgeInsets.symmetric(horizontal: 13),
            secondary: const Icon(
              Icons.schedule_outlined,
              color: muted,
              size: 17,
            ),
            title: const Text(
              'All day',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            onChanged: (value) => setState(() {
              _allDay = value;
              _eventError = null;
            }),
          ),
        ),
        _eventTimeRow(start: true, date: _startDate, time: _startTime),
        _eventTimeRow(start: false, date: _endDate, time: _endTime),
        _spaceRow(),
      ]),
      if (_eventError case final error?) ...[
        const SizedBox(height: 8),
        Semantics(
          key: _eventErrorKey,
          liveRegion: true,
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
      const SizedBox(height: 12),
      TextFormField(
        controller: _location,
        decoration: _decoration('Location'),
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
      ),
    ];
  }

  List<Widget> _taskFields() {
    final date = _dueDate;
    return [
      _propertyPanel([
        _spaceRow(),
        Row(
          children: [
            Expanded(
              child: _propertyButton(
                label: 'Due date',
                value: date == null ? 'None' : _dateLabel(date),
                icon: Icons.event_outlined,
                onPressed: _changeDueDate,
                showChevron: date == null,
              ),
            ),
            if (date != null)
              IconButton(
                tooltip: 'Remove due date',
                onPressed: () => setState(() => _dueDate = null),
                icon: const Icon(Icons.close_rounded, size: 16, color: muted),
              ),
          ],
        ),
      ]),
    ];
  }

  Widget _editorFields(double inset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 2, inset, 14),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_editing) ...[_kindSelector(), const SizedBox(height: 18)],
            TextFormField(
              controller: _title,
              focusNode: _titleFocus,
              autofocus: !_editing,
              decoration: _decoration('Title'),
              style: const TextStyle(
                color: ink,
                fontSize: 19,
                fontWeight: FontWeight.w600,
                letterSpacing: -.3,
              ),
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a title.'
                  : null,
            ),
            const SizedBox(height: 14),
            ...switch (_kind) {
              RecordKind.task => _taskFields(),
              RecordKind.event => _eventFields(),
              RecordKind.note => [
                TextFormField(
                  controller: _body,
                  decoration: _decoration('Note'),
                  minLines: 4,
                  maxLines: 12,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
            },
          ],
        ),
      ),
    );
  }

  Widget _header(double inset) {
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(inset, 10, inset - 3, 10),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                _editing ? 'Edit ${_kind.name}' : 'Add item',
                style: const TextStyle(
                  color: ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.65,
                  height: 1.13,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            style: IconButton.styleFrom(
              backgroundColor: _wash,
              foregroundColor: muted,
              minimumSize: const Size.square(44),
            ),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _footer(double inset, bool mobile) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: line)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, 11, inset, 13),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SizedBox(
            width: mobile ? double.infinity : null,
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(112, 46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(_editing ? 'Save changes' : 'Add ${_kind.name}'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final padding = MediaQuery.viewInsetsOf(context);
    final inset = mobile ? 20.0 : 25.0;
    return AnimatedPadding(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: mobile ? padding.bottom : 0),
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
              constraints: const BoxConstraints(maxWidth: 500),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final header = _header(inset);
                  final fields = _editorFields(inset);
                  final footer = _footer(inset, mobile);
                  final minHeight = MediaQuery.textScalerOf(context).scale(245);
                  if (constraints.maxHeight < minHeight) {
                    return SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [header, fields, footer],
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      Flexible(child: SingleChildScrollView(child: fields)),
                      footer,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
