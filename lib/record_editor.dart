import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'notes/note_preview.dart';
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
    this.taskItems = const [],
    this.noteTargets = const [],
    this.initialTaskParentId,
    super.key,
  });

  final DateTime date;
  final RecordKind kind;
  final CalendarEvent? event;
  final TaskItem? task;
  final NoteItem? note;
  final DateTime? initialTaskDate;
  final String? initialCategory;
  final List<TaskItem> taskItems;
  final List<NoteTarget> noteTargets;
  final String? initialTaskParentId;

  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  static const _wash = Color(0xFFF1F1EB);

  final _form = GlobalKey<FormState>();
  final _titleFocus = FocusNode();
  final _eventErrorKey = GlobalKey();
  final _taskErrorKey = GlobalKey();
  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _body;
  late final TextEditingController _noteFolder;
  late final TextEditingController _noteTagText;
  late final TextEditingController _taskNotes;
  late final TextEditingController _estimate;
  late final TextEditingController _minimumChunk;
  late final String _taskId;
  late List<String> _prerequisiteIds;
  late final List<NoteLink> _noteLinks;
  late bool _notePinned;
  bool _previewNote = false;
  bool _showNoteDetails = false;
  late bool _allowSplit;
  late RecordKind _kind;
  late String _category;
  late DateTime _startDate;
  late DateTime _endDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late bool _allDay;
  DateTime? _dueDate;
  DateTime? _dueAt;
  String? _eventError;
  String? _taskParentId;
  TaskPriority? _priority;
  DateTime? _earliestStart;
  String? _taskError;
  bool _showTaskDetails = false;

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
    _noteFolder = TextEditingController(text: note?.folder);
    _noteTagText = TextEditingController(text: note?.tags.join(', '));
    _noteLinks = [...?note?.links];
    _notePinned = note?.pinned ?? false;
    _estimate = TextEditingController(text: task?.estimatedMinutes?.toString());
    _minimumChunk = TextEditingController(
      text: (task?.minimumChunkMinutes ?? defaultTaskChunkMinutes).toString(),
    );
    _taskNotes = TextEditingController(text: task?.notes);
    _taskId = task?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    _taskParentId = task == null ? widget.initialTaskParentId : task.parentId;
    _priority = task?.priority;
    _earliestStart = task?.earliestStart?.toLocal();
    _prerequisiteIds = [...?task?.prerequisiteIds];
    _allowSplit = task?.allowSplit ?? false;
    _dueAt = task?.dueAt?.toLocal();
    _showTaskDetails =
        _taskParentId != null ||
        _priority != null ||
        _earliestStart != null ||
        _dueAt != null ||
        _allowSplit ||
        _prerequisiteIds.isNotEmpty ||
        _estimate.text.isNotEmpty ||
        _taskNotes.text.isNotEmpty;
    _category =
        event?.category ??
        task?.category ??
        widget.initialCategory ??
        'personal';
    _dueDate = _dueAt == null
        ? task == null
              ? widget.initialTaskDate
              : task.date
        : DateUtils.dateOnly(_dueAt!);
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
    _noteFolder.dispose();
    _noteTagText.dispose();
    _estimate.dispose();
    _taskNotes.dispose();
    _minimumChunk.dispose();
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
    setState(() {
      _dueDate = date;
      if (_dueAt case final exact?) {
        _dueAt = _combine(date, TimeOfDay.fromDateTime(exact));
      }
      _taskError = null;
    });
  }

  Future<void> _changeDueTime() async {
    final due = _dueDate;
    if (due == null) return;
    final exact = _dueAt;
    final time = await showTimePicker(
      context: context,
      initialTime: exact == null
          ? const TimeOfDay(hour: 17, minute: 0)
          : TimeOfDay.fromDateTime(exact),
      helpText: 'Choose due time',
    );
    if (!mounted || time == null) return;
    setState(() {
      _dueAt = _combine(due, time);
      _taskError = null;
    });
  }

  Future<void> _changeEarliestStart() async {
    final old = _earliestStart;
    final day = await _pickDate(old ?? widget.date, 'Choose earliest date');
    if (!mounted || day == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: old == null ? TimeOfDay.now() : TimeOfDay.fromDateTime(old),
      helpText: 'Choose earliest time',
    );
    if (!mounted || time == null) return;
    setState(() {
      _earliestStart = _combine(day, time);
      _taskError = null;
    });
  }

  Future<void> _changeTaskParent() async {
    final candidates =
        TaskHierarchy(widget.taskItems).eligibleParents(_taskId).toList()..sort(
          (first, second) =>
              first.title.toLowerCase().compareTo(second.title.toLowerCase()),
        );
    final choice = await showDialog<List<String>>(
      context: context,
      builder: (_) => _TaskPicker(
        tasks: candidates,
        initiallySelected: _taskParentId == null ? const [] : [_taskParentId!],
        multiple: false,
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      _taskParentId = choice.firstOrNull;
      _taskError = null;
    });
  }

  Future<void> _changePrerequisites() async {
    final candidates =
        TaskDependencyGraph(widget.taskItems)
            .eligiblePrerequisites(_taskId)
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    final choice = await showDialog<List<String>>(
      context: context,
      builder: (_) => _TaskPicker(
        tasks: candidates,
        initiallySelected: _prerequisiteIds,
        multiple: true,
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      _prerequisiteIds = choice;
      _taskError = null;
    });
  }

  bool _validateTaskDetails(int? estimatedMinutes, int? minimumChunkMinutes) {
    final parentIssue = _taskParentId == _taskId
        ? TaskParentIssue.cycle
        : widget.taskItems.isEmpty && _taskParentId == widget.task?.parentId
        ? null
        : taskParentIssue(widget.taskItems, _taskId, _taskParentId);
    final due = _dueDate;
    final start = _earliestStart;
    final exact = _dueAt;
    final existingPrerequisites =
        widget.task?.prerequisiteIds ?? const <String>[];
    final prerequisiteIssue = _prerequisiteIds.contains(_taskId)
        ? TaskPrerequisiteIssue.cycle
        : widget.taskItems.isEmpty &&
              _prerequisiteIds.every(existingPrerequisites.contains)
        ? null
        : taskPrerequisiteIssue(widget.taskItems, _taskId, _prerequisiteIds);
    final String? error;
    if (_estimate.text.trim().isNotEmpty &&
        (estimatedMinutes == null || estimatedMinutes < 1)) {
      error = 'Enter an estimated duration in whole minutes.';
    } else if (parentIssue != null) {
      error = parentIssue.message;
    } else if (prerequisiteIssue != null) {
      error = prerequisiteIssue.message;
    } else if (exact != null && start != null && start.isAfter(exact)) {
      error = 'Earliest start must be on or before the due time.';
    } else if (due != null &&
        start != null &&
        DateUtils.dateOnly(start).isAfter(DateUtils.dateOnly(due))) {
      error = 'Earliest start must be on or before the due date.';
    } else {
      error = taskSplitIssue(
        allowSplit: _allowSplit,
        minimumChunkMinutes: minimumChunkMinutes,
        estimatedMinutes: estimatedMinutes,
      );
    }
    if (error == null) return true;

    setState(() {
      _showTaskDetails = true;
      _taskError = error;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final errorContext = _taskErrorKey.currentContext;
      if (errorContext != null) Scrollable.ensureVisible(errorContext);
    });
    return false;
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
        final estimate = int.tryParse(_estimate.text.trim());
        final minimum = int.tryParse(_minimumChunk.text.trim());
        if (!_validateTaskDetails(estimate, minimum)) return;
        final notes = _taskNotes.text;
        Navigator.of(context).pop(
          TaskItem(
            id: _taskId,
            title: title,
            category: _category,
            date: _dueDate,
            done: widget.task?.done ?? false,
            completedAt: widget.task?.completedAt,
            estimatedMinutes: estimate,
            priority: _priority,
            parentId: _taskParentId,
            notes: notes.trim().isEmpty ? null : notes,
            earliestStart: _earliestStart,
            prerequisiteIds: List.unmodifiable(_prerequisiteIds),
            allowSplit: _allowSplit,
            minimumChunkMinutes: minimum != null && minimum > 0
                ? minimum
                : defaultTaskChunkMinutes,
            dueAt: _dueAt,
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
            plannedTaskId: widget.event?.plannedTaskId,
            initialPlannedStart: widget.event?.initialPlannedStart,
            initialPlannedEnd: widget.event?.initialPlannedEnd,
            description: widget.event?.description,
            color: widget.event?.color,
          ),
        );
      case RecordKind.note:
        Navigator.of(context).pop(_noteRecord(id: newId, updated: now));
    }
  }

  NoteItem _noteRecord({required String id, required DateTime updated}) {
    final existing = widget.note;
    final folder = _noteFolder.text.trim();
    return NoteItem(
      id: existing?.id ?? id,
      title: _title.text.trim(),
      body: _body.text,
      updated: updated,
      category: existing == null ? widget.initialCategory : existing.category,
      noteToSelf: existing?.noteToSelf ?? false,
      pinned: _notePinned,
      folder: existing != null && _noteFolder.text == (existing.folder ?? '')
          ? existing.folder
          : folder.isEmpty
          ? null
          : folder,
      tags: existing != null && _noteTagText.text == existing.tags.join(', ')
          ? existing.tags
          : noteTags(_noteTagText.text),
      links: List.unmodifiable(_noteLinks),
    );
  }

  Future<void> _linkNoteTarget() async {
    final alreadyLinked = _noteLinks.toSet();
    final choices = [
      for (final target in widget.noteTargets)
        if (!alreadyLinked.contains(target.link)) target,
    ];
    if (choices.isEmpty) return;
    final target = await showDialog<NoteTarget>(
      context: context,
      builder: (context) => _NoteTargetPicker(targets: choices),
    );
    if (mounted && target != null) setState(() => _noteLinks.add(target.link));
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
                onPressed: () => setState(() {
                  _dueDate = null;
                  _dueAt = null;
                  _taskError = null;
                }),
                icon: const Icon(Icons.close_rounded, size: 16, color: muted),
              ),
          ],
        ),
      ]),
      const SizedBox(height: 6),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          expanded: _showTaskDetails,
          child: TextButton.icon(
            iconAlignment: IconAlignment.end,
            icon: Icon(
              _showTaskDetails
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
            ),
            onPressed: () =>
                setState(() => _showTaskDetails = !_showTaskDetails),
            label: const Text('Task details'),
          ),
        ),
      ),
      if (_showTaskDetails) ..._taskDetails(),
      if (_taskError case final error?) ...[
        const SizedBox(height: 8),
        Semantics(
          key: _taskErrorKey,
          liveRegion: true,
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    ];
  }

  List<Widget> _taskDetails() {
    final start = _earliestStart;
    final dueAt = _dueAt;
    final parentId = _taskParentId;
    final parent = widget.taskItems
        .where((task) => task.id == parentId)
        .firstOrNull;
    final prerequisiteLabel = switch (_prerequisiteIds.length) {
      0 => 'None',
      1 =>
        widget.taskItems
                .where((task) => task.id == _prerequisiteIds.single)
                .firstOrNull
                ?.title ??
            'Unavailable',
      _ => '${_prerequisiteIds.length} tasks',
    };
    return [
      _propertyPanel([
        MenuAnchor(
          builder: (context, controller, _) => _propertyButton(
            label: 'Priority',
            value: _priority?.label ?? 'None',
            icon: Icons.flag_outlined,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
          menuChildren: [
            for (final priority in <TaskPriority?>[
              null,
              ...TaskPriority.values,
            ])
              MenuItemButton(
                trailingIcon: priority == _priority
                    ? const Icon(Icons.check_rounded, size: 16, color: accent)
                    : null,
                onPressed: () => setState(() => _priority = priority),
                child: Text(priority?.label ?? 'None'),
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _propertyButton(
                label: 'Earliest start',
                value: start == null
                    ? 'None'
                    : '${_dateLabel(start)} · ${_timeLabel(TimeOfDay.fromDateTime(start))}',
                icon: Icons.schedule_outlined,
                onPressed: _changeEarliestStart,
                showChevron: start == null,
              ),
            ),
            if (start != null)
              IconButton(
                tooltip: 'Remove earliest start',
                onPressed: () => setState(() {
                  _earliestStart = null;
                  _taskError = null;
                }),
                icon: const Icon(Icons.close_rounded, size: 16, color: muted),
              ),
          ],
        ),
        if (_dueDate != null)
          Row(
            children: [
              Expanded(
                child: _propertyButton(
                  label: 'Due time',
                  value: dueAt == null
                      ? 'None'
                      : _timeLabel(TimeOfDay.fromDateTime(dueAt)),
                  icon: Icons.access_time_rounded,
                  onPressed: _changeDueTime,
                  showChevron: dueAt == null,
                ),
              ),
              if (dueAt != null)
                IconButton(
                  tooltip: 'Remove due time',
                  onPressed: () => setState(() {
                    _dueAt = null;
                    _taskError = null;
                  }),
                  icon: const Icon(Icons.close_rounded, size: 16, color: muted),
                ),
            ],
          ),
        if (parentId != null || widget.taskItems.isNotEmpty)
          _propertyButton(
            label: 'Parent task',
            value: parentId == null ? 'None' : parent?.title ?? 'Unavailable',
            icon: Icons.account_tree_outlined,
            onPressed: _changeTaskParent,
          ),
        if (_prerequisiteIds.isNotEmpty ||
            widget.taskItems.any((task) => task.id != _taskId))
          _propertyButton(
            label: 'Prerequisites',
            value: prerequisiteLabel,
            icon: Icons.checklist_rounded,
            onPressed: _changePrerequisites,
          ),
        SwitchListTile.adaptive(
          title: const Text(
            'Split across blocks',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 13),
          value: _allowSplit,
          onChanged: (value) => setState(() {
            _allowSplit = value;
            _taskError = null;
          }),
        ),
      ]),
      const SizedBox(height: 12),
      TextFormField(
        key: const ValueKey('task-estimate'),
        controller: _estimate,
        decoration: _decoration('Estimated minutes'),
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        onChanged: (_) {
          if (_taskError != null) setState(() => _taskError = null);
        },
      ),
      if (_allowSplit) ...[
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('task-minimum-chunk'),
          controller: _minimumChunk,
          decoration: _decoration('Minimum block (minutes)'),
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          onChanged: (_) {
            if (_taskError != null) setState(() => _taskError = null);
          },
        ),
      ],
      const SizedBox(height: 12),
      TextFormField(
        key: const ValueKey('task-notes'),
        controller: _taskNotes,
        decoration: _decoration('Task notes'),
        minLines: 2,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
      ),
    ];
  }

  List<Widget> _noteFields() => [
    if (_previewNote)
      DecoratedBox(
        decoration: BoxDecoration(
          color: raisedPaper,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: _body.text.trim().isEmpty
              ? const Text(
                  'This note is empty.',
                  style: TextStyle(color: muted),
                )
              : NotePreview(
                  note: _noteRecord(id: 'preview', updated: widget.date),
                  targets: widget.noteTargets,
                ),
        ),
      )
    else
      TextFormField(
        key: const ValueKey('note-markdown-source'),
        controller: _body,
        decoration: _decoration('Note'),
        minLines: 4,
        maxLines: 12,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
      ),
    const SizedBox(height: 5),
    Wrap(
      spacing: 4,
      children: [
        TextButton.icon(
          icon: Icon(
            _previewNote ? Icons.edit_outlined : Icons.visibility_outlined,
            size: 16,
          ),
          label: Text(_previewNote ? 'Edit text' : 'Preview'),
          onPressed: () {
            FocusScope.of(context).unfocus();
            setState(() => _previewNote = !_previewNote);
          },
        ),
        Semantics(
          expanded: _showNoteDetails,
          child: TextButton.icon(
            icon: Icon(
              _showNoteDetails
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 18,
            ),
            iconAlignment: IconAlignment.end,
            label: const Text('Organise'),
            onPressed: () =>
                setState(() => _showNoteDetails = !_showNoteDetails),
          ),
        ),
      ],
    ),
    if (_showNoteDetails) ...[
      _propertyPanel([
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 13),
          title: const Text('Pin note'),
          value: _notePinned,
          onChanged: (pinned) => setState(() => _notePinned = pinned),
        ),
      ]),
      const SizedBox(height: 10),
      TextFormField(
        key: const ValueKey('note-folder'),
        controller: _noteFolder,
        decoration: _decoration('Folder'),
        textInputAction: TextInputAction.next,
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 10),
      TextFormField(
        key: const ValueKey('note-tags'),
        controller: _noteTagText,
        decoration: _decoration('Tags')
            .copyWith(hintText: 'Separate tags with commas'),
      ),
      if (_noteLinks.isNotEmpty || widget.noteTargets.isNotEmpty) ...[
        const SizedBox(height: 10),
        _propertyPanel([
          for (final link in _noteLinks)
            ListTile(
              title: Text(
                widget.noteTargets
                        .where((target) => target.link == link)
                        .firstOrNull
                        ?.title ??
                    link.title ??
                    link.kind.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(link.kind.label),
              trailing: IconButton(
                tooltip: 'Remove ${link.kind.label.toLowerCase()} link',
                onPressed: () => setState(() => _noteLinks.remove(link)),
                icon: const Icon(Icons.close_rounded, size: 19),
              ),
            ),
          if (widget.noteTargets.any(
            (target) => !_noteLinks.contains(target.link),
          ))
            ListTile(
              leading: const Icon(Icons.link_rounded, color: accent),
              title: const Text('Link task or event'),
              trailing: const Icon(Icons.chevron_right_rounded, color: muted),
              onTap: _linkNoteTarget,
            ),
        ]),
      ],
    ],
  ];

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
              RecordKind.note => _noteFields(),
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

class _NoteTargetPicker extends StatefulWidget {
  const _NoteTargetPicker({required this.targets});

  final List<NoteTarget> targets;

  @override
  State<_NoteTargetPicker> createState() => _NoteTargetPickerState();
}

class _NoteTargetPickerState extends State<_NoteTargetPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final targets = _query.isEmpty
        ? widget.targets
        : widget.targets
              .where((target) => target.title.toLowerCase().contains(_query))
              .toList();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: SizedBox(
        width: 420,
        height: 380,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (constraints.maxHeight >= 190)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 9, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Link a record',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close link picker',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
              if (constraints.maxHeight >= 130)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                  child: TextField(
                    onChanged: (value) =>
                        setState(() => _query = value.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      labelText: 'Find a task or event',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  ),
                ),
              Expanded(
                child: targets.isEmpty
                    ? const Center(child: Text('No matching records.'))
                    : ListView.builder(
                        itemCount: targets.length,
                        itemBuilder: (context, index) {
                          final target = targets[index];
                          return ListTile(
                            leading: Icon(switch (target.kind) {
                              NoteLinkKind.task => Icons.check_box_outlined,
                              NoteLinkKind.event =>
                                Icons.calendar_today_outlined,
                            }),
                            title: Text(
                              target.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(target.kind.label),
                            onTap: () => Navigator.pop(context, target),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskPicker extends StatefulWidget {
  const _TaskPicker({
    required this.tasks,
    required this.initiallySelected,
    required this.multiple,
  });

  final List<TaskItem> tasks;
  final List<String> initiallySelected;
  final bool multiple;

  @override
  State<_TaskPicker> createState() => _TaskPickerState();
}

class _TaskPickerState extends State<_TaskPicker> {
  late final _selected = widget.initiallySelected.toSet();
  String _query = '';

  void _choose(List<String> ids) => Navigator.pop(context, ids);

  void _toggle(String id, bool? checked) => setState(() {
    if (checked == true) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
  });

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tasks
        .where((task) => task.title.toLowerCase().contains(_query))
        .toList();
    final unavailable = widget.multiple
        ? _selected.difference({
            for (final task in widget.tasks) task.id,
          }).toList()
        : const <String>[];
    final extraRows = widget.multiple ? unavailable.length : 1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.multiple
                          ? 'Choose prerequisites'
                          : 'Choose parent task',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: widget.multiple
                        ? 'Close prerequisite picker'
                        : 'Close parent picker',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: 1 + extraRows + filtered.length,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded),
                          hintText: 'Find a task',
                        ),
                        onChanged: (text) =>
                            setState(() => _query = text.trim().toLowerCase()),
                      ),
                    );
                  }
                  if (!widget.multiple && index == 1) {
                    return ListTile(
                      title: const Text('No parent'),
                      selected: _selected.isEmpty,
                      onTap: () => _choose(const []),
                    );
                  }
                  if (widget.multiple && index <= unavailable.length) {
                    final id = unavailable[index - 1];
                    return CheckboxListTile(
                      title: const Text('Unavailable prerequisite'),
                      value: true,
                      onChanged: (checked) => _toggle(id, checked),
                    );
                  }
                  final task = filtered[index - 1 - extraRows];
                  if (widget.multiple) {
                    return CheckboxListTile(
                      key: ValueKey(task.id),
                      title: Text(task.title),
                      subtitle: Text(
                        task.done ? 'Completed' : spaceName(task.category),
                      ),
                      value: _selected.contains(task.id),
                      onChanged: (checked) => _toggle(task.id, checked),
                    );
                  }
                  return ListTile(
                    title: Text(task.title),
                    subtitle: Text(spaceName(task.category)),
                    selected: _selected.contains(task.id),
                    onTap: () => _choose([task.id]),
                  );
                },
              ),
            ),
            if (widget.multiple)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () => _choose(_selected.toList()),
                    child: const Text('Apply prerequisites'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
