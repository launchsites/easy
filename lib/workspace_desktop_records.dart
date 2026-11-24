part of 'main.dart';

extension _WorkspaceDesktopRecords on _WorkspaceState {
  Future<bool> _mayCloseWorkoutPlans() async {
    if (_confirmingWorkoutExit) return false;
    final panel = _workoutPanelKey.currentState;
    if (panel == null) return true;
    _confirmingWorkoutExit = true;
    try {
      return await panel.confirmLeaving();
    } finally {
      _confirmingWorkoutExit = false;
    }
  }

  Future<void> _createTimedEvent(DateTimeRange range) async {
    if (_reviewSaving) return;
    final calendar = _calendarPreferences?.defaultWriteCalendar;
    final result = await _showEditor(
      RecordEditor(
        date: range.start,
        kind: RecordKind.event,
        initialEventRange: range,
        initialCategory: calendar?.accountId == _localCalendarAccount
            ? (calendar!.calendarId == 'general' ? '' : calendar.calendarId)
            : _preferredFocusCategory,
      ),
    );
    if (!mounted || result is! CalendarEvent) return;
    _saveRecord(result);
    _changeDate(result.start);
  }

  Future<NoteItem> _saveDesktopNote(
    NoteItem expected,
    String title,
    String body,
  ) async {
    while (_reviewSaving && mounted) {
      await _pendingSave;
    }
    if (!mounted) throw StateError('The workspace closed.');
    final previous = _data;
    final current = previous.notes
        .where((note) => note.id == expected.id)
        .firstOrNull;
    if (current == null && !_newDesktopNoteIds.contains(expected.id) ||
        current != null &&
            (current.title != expected.title ||
                current.body != expected.body)) {
      throw StateError('This note changed elsewhere.');
    }
    final trimmedTitle = title.trim();
    if (current == null && trimmedTitle.isEmpty && body.trim().isEmpty) {
      return expected;
    }
    final updated = (current ?? expected).withContent(
      title: trimmedTitle.isEmpty ? 'Untitled' : trimmedTitle,
      body: body,
      updated: DateTime.now(),
    );
    await _commitReviewedData(
      previous,
      previous.copyWith(
        notes: _upsert(previous.notes, updated, (note) => note.id),
      ),
    );
    _newDesktopNoteIds.remove(updated.id);
    return updated;
  }

  Future<void> _runNoteAction(NoteItem note, {required bool delete}) async {
    final edits = _desktopNoteEdits;
    if (edits != null && !await edits.flush(note.id)) return;
    if (!mounted) return;
    final current = _data.notes.where((item) => item.id == note.id).firstOrNull;
    if (current == null) return;
    if (delete) {
      await _deleteRecord(current);
    } else {
      final result = await _showEditor(
        RecordEditor(
          date: _today,
          kind: RecordKind.note,
          note: current,
          noteTargets: _noteTargets(),
          notePropertiesOnly: true,
        ),
      );
      if (mounted && result is NoteItem) _saveRecord(result);
    }
  }

  Widget _desktopNote(NoteItem note) {
    final isNew = _newDesktopNoteIds.contains(note.id);
    final edits = _desktopNoteEdits ??= DesktopNoteEdits(
      save: _saveDesktopNote,
    );
    return Column(
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, top: 10),
            child: IconButton(
              tooltip: 'Close details',
              onPressed: _closeDesktopRecord,
              icon: const BackButtonIcon(),
            ),
          ),
        ),
        Expanded(
          child: DesktopNoteEditor(
            note: note,
            edits: edits,
            autofocus: isNew,
            targets: _noteTargets(),
            onOpenLink: _openNoteLink,
            actions: isNew
                ? null
                : PopupMenuButton<bool>(
                    tooltip: 'Note options',
                    onSelected: (delete) =>
                        _runNoteAction(note, delete: delete),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: false, child: Text('Note details')),
                      PopupMenuItem(value: true, child: Text('Delete note')),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _desktopRecordDetails(Object record, {bool centered = false}) {
    final appleAction = _appleActionFor(record);
    final task = record is TaskItem ? record : null;
    final event = record is CalendarEvent ? record : null;
    return _RecordDetails(
      record: record,
      centered: centered,
      onClose: _closeDesktopRecord,
      onEdit: () => _editRecord(record),
      onDelete: () => _deleteRecord(record),
      onToggleDone: task == null ? null : () => _toggleTask(task),
      onEstimate: task != null && _canEstimate(task)
          ? () => _suggestDuration(task)
          : null,
      appleActionLabel: appleAction?.label,
      onAppleCopy: appleAction != null && event != null
          ? () => _appleRecordAction(event, appleAction)
          : null,
      repeatingTask: _repeatingTask(record) != null,
      onRepeat: switch (record) {
        CalendarEvent event when _canRepeatEvent(event) =>
          () => _setEventRepeat(event),
        TaskItem task when _canRepeatTask(task) => () => _setTaskRepeat(task),
        _ => null,
      },
      onAssignPlace: event != null && _canAssignPlace(event)
          ? () => _assignPlace(event)
          : null,
      onAddSubtask: task != null && _canAddSubtask(task)
          ? () => _addSubtask(task)
          : null,
      onBreakdown: task != null && _canAddSubtask(task)
          ? () => _breakDownTask(task)
          : null,
      reminderSet: _hasRecordReminder(record),
      onReminder: _recordReminderTarget(record) == null
          ? null
          : () => _editRecordReminder(record),
      onSchedule: _canScheduleTask(record)
          ? () => _openManualBlock(record)
          : null,
      onTimingHistory: task != null && _canSeeTaskTiming(task)
          ? () => _openTaskTiming(task)
          : null,
      onTrackActivity: _canTrackActivity(record)
          ? () => _openActualActivity(record)
          : null,
      onRemoveFutureBlocks: task != null && _canRemoveFutureBlocks(task)
          ? () => _removeFutureBlocks(task)
          : null,
    );
  }

  Widget _recordWorkspace({
    required bool mobile,
    required Widget list,
    Widget? details,
  }) => mobile ? list : _DesktopRecordWorkspace(list: list, details: details);
}

class _DesktopRecordWorkspace extends StatelessWidget {
  const _DesktopRecordWorkspace({required this.list, this.details});

  final Widget list;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final open = details != null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final split = open && width >= 624;
        final companionWidth = (width * .29).clamp(248.0, 334.0);
        final hiddenList = open && !split;
        return ColoredBox(
          color: shell,
          child: Stack(
            children: [
              AnimatedPositionedDirectional(
                duration: duration,
                curve: Curves.easeInOutCubic,
                start: split
                    ? width - companionWidth
                    : hiddenList
                    ? width
                    : 0,
                width: split ? companionWidth : width,
                top: 0,
                bottom: 0,
                child: ExcludeFocus(
                  excluding: hiddenList,
                  child: ExcludeSemantics(
                    excluding: hiddenList,
                    child: IgnorePointer(
                      ignoring: hiddenList,
                      child: _Surface(child: list),
                    ),
                  ),
                ),
              ),
              AnimatedPositionedDirectional(
                duration: duration,
                curve: Curves.easeInOutCubic,
                start: 0,
                end: split ? companionWidth + 12 : 0,
                top: 0,
                bottom: 0,
                child: AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(
                          Directionality.of(context) == TextDirection.ltr
                              ? -.04
                              : .04,
                          0,
                        ),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final child in previous)
                        ExcludeFocus(
                          child: ExcludeSemantics(
                            child: IgnorePointer(child: child),
                          ),
                        ),
                      ?current,
                    ],
                  ),
                  child: open
                      ? _Surface(
                          key: const ValueKey('desktop-record-detail'),
                          child: details!,
                        )
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
