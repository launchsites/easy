part of 'main.dart';

extension _WorkspaceRepeatingTasks on _WorkspaceState {
  List<TaskItem> get _workspaceTasks =>
      _taskFeed.workspaceTasks(_data.tasks, _today);

  void _readTaskFeed() {
    try {
      _taskFeed = TaskWorkspaceFeed(
        readTaskSeries(_data.sections[recurringTasksSection]),
      );
      _taskSeriesUnreadable = false;
    } catch (_) {
      _taskFeed = TaskWorkspaceFeed();
      _taskSeriesUnreadable = true;
    }
  }

  WorkspaceData _withTaskSeries(
    WorkspaceData previous,
    List<RecurringTaskSeries> series,
  ) => previous.withSection(recurringTasksSection, [
    for (final item in series) item.toJson(),
  ]);

  Future<void> _saveTaskSeries(
    RecurringTaskSeries series, {
    AutomationEvent? completed,
  }) async {
    final previous = _data;
    final updated = _upsert(_taskFeed.series, series, (item) => item.id);
    if (_taskSeriesUnreadable || updated.length > maximumTaskSeries) {
      throw const FormatException('This repeating task could not be stored.');
    }
    await _commitReviewedData(
      previous,
      _withAutomationEvents(_withTaskSeries(previous, updated), [?completed]),
    );
  }

  TaskSeriesRow? _repeatingTask(Object? record) =>
      record is TaskItem ? _taskFeed.row(record.id, _data.tasks, _today) : null;

  bool _canRepeatTask(Object? record) =>
      record is TaskItem &&
      !record.done &&
      !_taskSeriesUnreadable &&
      !_taskFeed.ids.contains(record.id);

  Iterable<TaskItem> _captureTaskMatches(DateTime when) =>
      _taskFeed.reviewTasks(_data.tasks, when.toLocal());

  TaskItem? _linkedTaskOccurrence(String id) {
    if (!_taskFeed.ids.contains(id)) return null;
    for (final task in _workspaceTasks) {
      if (!task.done && _repeatingTask(task)?.series.id == id) return task;
    }
    return null;
  }

  Future<void> _setTaskRepeat(TaskItem task) async {
    if (!_canRepeatTask(task) || _reviewSaving) return;
    final row = _repeatingTask(task);
    final selected = await showTaskRepeatEditor(
      context,
      startDate: row?.occurrence.scheduledDate ?? task.date ?? _today,
      initialRule: row?.occurrence.rule,
      initialReminder: row?.occurrence.reminder,
    );
    if (!mounted || selected == null) return;
    try {
      if (row == null) {
        if (!_data.tasks.any((item) => identical(item, task)) ||
            !_canRepeatTask(task)) {
          _inform('The task changed. Open it again to set a repeat.');
          return;
        }
        await _saveTaskSeries(
          RecurringTaskSeries(
            id: task.id,
            task: task.withDate(task.date ?? selected.startDate),
            rule: selected.rule,
            startDate: selected.startDate,
            timeZoneId: _planningPreferences()?.timeZoneId,
            reminder: selected.reminder,
          ),
        );
      } else {
        await _applyTaskRepeatSettings(row, selected);
      }
    } on RecurringTaskScheduleException catch (error) {
      if (mounted) _inform(error.issue.message);
    } catch (_) {
      if (mounted) _inform('The repeat could not be saved.');
    }
  }

  Future<void> _applyTaskRepeatSettings(
    TaskSeriesRow row,
    TaskRepeatSettings settings,
  ) async {
    final scope = await showTaskOccurrenceScopeDialog(
      context,
      skipping: false,
      allowSingle: false,
    );
    if (!mounted || scope == null || !_taskFeed.series.contains(row.series)) {
      return;
    }
    await _saveTaskSeries(
      row.series.edit(
        row.occurrence,
        scope: scope,
        task: row.series.fieldsForDate(row.occurrence, settings.startDate),
        rule: settings.rule,
        startDate: settings.startDate,
        reminder: settings.reminder,
        clearReminder: settings.reminder == null,
      ),
    );
  }

  Future<void> _editRepeatingTask(TaskSeriesRow row) async {
    if (row.task.done) {
      _inform('Reopen the task to edit this occurrence.');
      return;
    }
    final scope = await showTaskOccurrenceScopeDialog(context, skipping: false);
    if (!mounted || scope == null || !_taskFeed.series.contains(row.series)) {
      return;
    }
    final edited = await _showEditor(
      RecordEditor(
        date: row.occurrence.scheduledDate,
        kind: RecordKind.task,
        task: row.task,
        taskItems: _workspaceTasks,
      ),
    );
    if (!mounted ||
        edited is! TaskItem ||
        !_taskFeed.series.contains(row.series)) {
      return;
    }
    try {
      await _saveTaskSeries(
        row.series.edit(row.occurrence, scope: scope, task: edited),
      );
    } on RecurringTaskScheduleException catch (error) {
      if (mounted) _inform(error.issue.message);
    } catch (_) {
      if (mounted) _inform('The repeating task could not be changed.');
    }
  }

  Future<void> _skipRepeatingTask(TaskSeriesRow row) async {
    if (row.task.done) {
      _inform('Reopen the task to skip it.');
      return;
    }
    final scope = await showTaskOccurrenceScopeDialog(context, skipping: true);
    if (!mounted || scope == null || !_taskFeed.series.contains(row.series)) {
      return;
    }
    try {
      await _saveTaskSeries(row.series.skip(row.occurrence, scope: scope));
    } catch (_) {
      if (mounted) _inform('The repeating task could not be skipped.');
    }
  }

  Future<bool> _toggleRepeatingTask(
    TaskSeriesRow row, {
    required bool showFailure,
  }) async {
    final done = !row.task.done;
    final next = done
        ? row.series.complete(row.occurrence, at: DateTime.now().toUtc())
        : row.series.reopen(row.occurrence);
    try {
      await _saveTaskSeries(
        next,
        completed: done ? _automationForRepeatedTask(next, row.task.id) : null,
      );
    } catch (_) {
      if (mounted && showFailure) _inform(_taskCompletionFailure);
      return false;
    }
    if (!mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done ? 'Task completed' : 'Task reopened'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_undoRepeatingToggle(row, next.revision)),
        ),
      ),
    );
    return true;
  }

  Future<void> _undoRepeatingToggle(TaskSeriesRow before, int revision) async {
    final current = _taskFeed.row(
      before.task.id,
      _data.tasks,
      _today,
      sourceDate: before.occurrence.scheduledDate,
    );
    if (current == null || current.series.revision != revision) {
      _inform('The repeating task changed after this action.');
      return;
    }
    try {
      await _saveTaskSeries(
        before.task.done
            ? current.series.complete(
                current.occurrence,
                at: before.task.completedAt!,
              )
            : current.series.reopen(current.occurrence),
      );
    } catch (_) {
      if (mounted) _inform('The task could not be restored.');
    }
  }
}
