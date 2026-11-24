part of 'main.dart';

typedef _VerifyManualInput = ({
  ManualBlockSelection selection,
  ManualBlockContext records,
  DateTime asOf,
});

ManualBlockSelection? _verifyManualBlock(_VerifyManualInput input) =>
    input.selection.verify(
      tasks: input.records.tasks,
      events: input.records.events,
      notBefore: input.asOf,
      settings: input.records.settings,
    );

extension _WorkspaceManualPlan on _WorkspaceState {
  bool _canScheduleTask(Object? record) =>
      _allows(EasyFeature.planning) &&
      record is TaskItem &&
      !record.done &&
      !_taskFeed.ids.contains(record.id);

  TaskItem? _scheduleTask(String id, DateTime effectiveDay) =>
      _workspaceTasks.where((task) => task.id == id).firstOrNull ??
      _taskFeed.row(id, _data.tasks, _today, sourceDate: effectiveDay)?.task;

  Future<ManualBlockContext?> _readManualPlanContext(
    TimeSpan span,
    String taskId,
    DateTime sourceDay,
  ) async {
    final start = dateOnly(span.start.toLocal());
    final end = dateOnly(
      span.end.subtract(const Duration(microseconds: 1)).toLocal(),
    );
    final external = await _planningCalendar(
      start,
      firstDay: start,
      lastDay: end,
    );
    if (!mounted || external == null || !_allows(EasyFeature.planning)) {
      return null;
    }
    final all = _workspaceTasks;
    final target = _scheduleTask(taskId, sourceDay);
    if (target == null || target.done) return null;
    final SchedulingSettings? settings;
    try {
      settings = _planningPreferences(expandCategories: true);
    } catch (_) {
      return null;
    }
    return ManualBlockContext(
      tasks: all.contains(target) ? all : [...all, target],
      events: [..._standaloneEvents(_data.events), ...external],
      settings: settings,
    );
  }

  Future<void> _openManualBlock(Object record) async {
    if (!_allows(EasyFeature.planning) || _reviewSaving || _planningDay) return;
    final existing = record is CalendarEvent ? record : null;
    final id =
        existing?.plannedTaskId ?? (record is TaskItem ? record.id : null);
    if (id == null) return;
    final day =
        existing?.start.toLocal() ??
        (record is TaskItem
            ? (record.dueAt ?? record.date)?.toLocal()
            : null) ??
        _today;
    final task = _scheduleTask(id, day);
    if (task == null || task.done) {
      _inform('This task is unavailable for scheduling.');
      return;
    }
    _planningDay = true;
    try {
      final chosen = await _showEditor(
        ManualTimeBlockSheet(
          task: task,
          tasks: const [],
          events: const [],
          day: day,
          existingBlock: existing,
          loadContext: (span) => _readManualPlanContext(span, id, day),
        ),
      );
      if (!mounted || chosen is! ManualBlockSelection) return;
      final current = await _readManualPlanContext(chosen.span, id, day);
      if (!mounted || current == null) return;
      final previous = _data;
      final calendarRevision = (
        _appleFeed.events,
        _icsFeed.events,
        _internalFeed.events,
      );
      final verified = await compute(_verifyManualBlock, (
        selection: chosen,
        records: current,
        asOf: DateTime.now(),
      ));
      if (!mounted) return;
      if (verified == null ||
          !identical(previous, _data) ||
          calendarRevision !=
              (_appleFeed.events, _icsFeed.events, _internalFeed.events) ||
          chosen.span.start.isBefore(DateTime.now())) {
        _inform('The available time changed. Preview this block again.');
        return;
      }
      final operationId =
          'manual-block-${DateTime.now().microsecondsSinceEpoch}';
      final event = verified.calendarEvent(
        newId: verified.existingEventId == null ? operationId : null,
      );
      await _commitReviewedData(
        previous,
        previous.copyWith(
          events: _upsert(previous.events, event, (value) => value.id),
        ),
        operationId: operationId,
      );
      if (!mounted) return;
      _changeDate(event.start.toLocal());
      _navigate(_Destination.calendar);
    } catch (_) {
      if (mounted) _inform('The time block could not be saved.');
    } finally {
      _planningDay = false;
    }
  }
}
