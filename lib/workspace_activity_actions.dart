part of 'main.dart';

extension _WorkspaceActivityActions on _WorkspaceState {
  bool _canTrackActivity(Object? record) =>
      _allows(EasyFeature.activity) &&
      (record is TaskItem ||
          record is CalendarEvent &&
              !record.allDay &&
              record.end.isAfter(record.start));

  ActivityActualTarget? _actualTarget(Object record) {
    if (!_canTrackActivity(record)) return null;
    if (record is TaskItem) {
      final task = _workspaceTasks
          .where((item) => item.id == record.id)
          .firstOrNull;
      if (task == null) return null;
      return ActivityActualTarget(
        record: ActivityTarget(
          id: task.id,
          title: task.title,
          category: task.category,
          kind: ActivityTargetKind.task,
        ),
      );
    }
    if (record is! CalendarEvent) return null;
    final event = _searchableEvents()
        .where((item) => item.id == record.id)
        .firstOrNull;
    if (event == null || event.allDay || !event.end.isAfter(event.start))
      return null;
    final selected = ActivityWindow(event.start, event.end);
    final first = event.initialPlannedStart;
    final last = event.initialPlannedEnd;
    final original = first != null && last != null && last.isAfter(first)
        ? ActivityWindow(first, last)
        : selected;
    return ActivityActualTarget(
      record: ActivityTarget(
        id: event.id,
        title: event.title,
        category: event.category,
        kind: ActivityTargetKind.event,
        plan: original,
      ),
      scheduled: selected,
    );
  }

  Future<void> _openActualActivity(Object record) async {
    if (_reviewSaving || _activityActionOpen || !_allows(EasyFeature.activity))
      return;
    final target = _actualTarget(record);
    if (target == null) return;
    _activityActionOpen = true;
    try {
      final selected = await showActivityActualReview(
        context,
        target: target,
        data: _activityData(),
      );
      if (!mounted || selected == null) return;
      final latest = _actualTarget(record);
      if (latest == null) {
        _inform('This record changed. Open it again to track time.');
        return;
      }
      final previous = _data;
      final at = DateTime.now();
      final next = selected.apply(
        current: _activityData(),
        target: latest,
        now: at,
      );
      await _commitReviewedData(
        previous,
        previous.withSection(_activitiesKey, next.toJson()),
        operationId: 'linked-activity-${at.microsecondsSinceEpoch}',
      );
      if (!mounted) return;
      if (selected.kind == ActivityActualKind.startTimer) {
        _openActivities();
      } else {
        _inform('Activity logged.');
      }
    } on StateError catch (error) {
      if (mounted) _inform(error.message);
    } catch (_) {
      if (mounted) _inform('This activity could not be saved.');
    } finally {
      _activityActionOpen = false;
    }
  }

  bool _canRemoveFutureBlocks(Object? record) =>
      _allows(EasyFeature.planning) &&
      record is TaskItem &&
      record.done &&
      _data.events.any(
        (event) =>
            event.plannedTaskId == record.id &&
            event.start.isAfter(DateTime.now()) &&
            !event.isReadOnly &&
            _appleCopyFor(event.id) == null,
      );

  Set<String> _protectedPlannedEventIds(String taskId) {
    final activity = _activityData();
    return {
      for (final event in _data.events)
        if (event.plannedTaskId == taskId && _appleCopyFor(event.id) != null)
          event.id,
      for (final record in activity.records)
        if (record.target case final target?
            when target.kind == ActivityTargetKind.event)
          target.id,
    };
  }

  Future<void> _removeFutureBlocks(TaskItem task) async {
    if (!_canRemoveFutureBlocks(task) || _reviewSaving || _futureRemovalOpen)
      return;
    _futureRemovalOpen = true;
    try {
      final review = FutureBlockRemovalReview.prepare(
        task: task,
        events: _data.events,
        now: DateTime.now(),
        protectedEventIds: _protectedPlannedEventIds(task.id),
      );
      if (review.blocks.isEmpty) {
        _inform('There are no removable future blocks for this task.');
        return;
      }
      final approval = await showFutureBlockRemovalReview(
        context,
        review: review,
      );
      if (!mounted || approval == null || !_allows(EasyFeature.planning))
        return;
      final current = _workspaceTasks
          .where((item) => item.id == task.id)
          .firstOrNull;
      if (current == null) return;
      final previous = _data;
      final now = DateTime.now();
      final remaining = approval.remainingEvents(
        task: current,
        events: previous.events,
        now: now,
        protectedEventIds: _protectedPlannedEventIds(task.id),
      );
      if (remaining == null) {
        _inform('The task or its blocks changed. Review them again.');
        return;
      }
      await _commitReviewedData(
        previous,
        previous.copyWith(events: remaining),
        operationId: 'remove-future-blocks-${now.microsecondsSinceEpoch}',
      );
      if (mounted) {
        final count = approval.blocks.length;
        _inform(count == 1 ? 'Block removed' : '$count blocks removed');
      }
    } catch (_) {
      if (mounted) _inform('The selected blocks could not be removed.');
    } finally {
      _futureRemovalOpen = false;
    }
  }
}
