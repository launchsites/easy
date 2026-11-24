part of 'main.dart';

extension _WorkspaceReminders on _WorkspaceState {
  bool get _supportsReminders => switch (widget.reminderBackend) {
    PlatformLocalReminderBackend backend => backend.supportsPlatform,
    _ => true,
  };

  Future<LocalReminderSettings> _deviceReminderSettings() async {
    final pending = _localReminderSettings ??= widget.reminderSettings.load();
    try {
      return await pending;
    } catch (_) {
      if (identical(pending, _localReminderSettings)) {
        _localReminderSettings = null;
      }
      rethrow;
    }
  }

  void _queueReminderSync(
    WorkspaceData data, {
    bool force = false,
    bool immediate = false,
  }) {
    if (!mounted || !_supportsReminders) return;
    _reminderWorkspace = data;
    final revision = (
      data.tasks,
      data.events,
      data.sections[_featuresKey],
      data.sections[_recurringEventsKey],
      data.sections[recurringTasksSection],
      data.sections[recordRemindersSection],
    );
    if (!force && revision == _reminderWorkspaceRevision) return;
    _reminderWorkspaceRevision = revision;
    _reminderDebounce?.cancel();
    if (immediate) {
      unawaited(_reconcileReminders(data, revision));
    } else {
      _reminderDebounce = Timer(const Duration(milliseconds: 100), () {
        unawaited(_reconcileReminders(data, revision));
      });
    }
  }

  Future<void> _reconcileReminders(WorkspaceData data, Object revision) async {
    try {
      final settings = await _deviceReminderSettings();
      if (!mounted || revision != _reminderWorkspaceRevision) return;
      final reminders = settings.enabled
          ? _workspaceReminderIntents(data)
          : const <LocalReminder>[];
      await _localReminderController.reconcile(
        settings: settings,
        reminders: reminders,
      );
    } catch (_) {
      // A temporarily locked vault or unavailable platform is retried on resume.
    }
  }

  List<LocalReminder> _workspaceReminderIntents(WorkspaceData saved) {
    final raw = saved.sections[_featuresKey];
    final features = raw is Map<String, Object?>
        ? FeaturePreferences.fromJson(raw)
        : FeaturePreferences();
    return composeWorkspaceReminders(
      now: DateTime.now(),
      tasks: saved.tasks,
      events: saved.events,
      taskSeries: readTaskSeries(saved.sections[recurringTasksSection]),
      eventSeriesIds: {
        for (final value in readInternalSeries(
          saved.sections[_recurringEventsKey],
        ))
          value.id,
      },
      preferences: readRecordReminderPreferences(
        saved.sections[recordRemindersSection],
      ).values,
      planningEnabled: features.allows(EasyFeature.planning),
    );
  }

  Future<void> _openReminderSettings() async {
    try {
      final previous = await _deviceReminderSettings();
      if (!mounted) return;
      final settings = await showLocalReminderSettings(
        context,
        settings: previous,
        backend: widget.reminderBackend,
      );
      if (settings == null || !mounted) return;
      await widget.reminderSettings.save(settings);
      _localReminderSettings = Future.value(settings);
      if (_reminderWorkspace case final saved?) {
        _queueReminderSync(saved, force: true, immediate: true);
      }
    } catch (_) {
      if (mounted) _inform('Reminder settings are unavailable.');
    }
  }

  ReminderTarget? _recordReminderTarget(Object? record) {
    if (!_supportsReminders) return null;
    return switch (record) {
      TaskItem task
          when !task.done &&
              !_taskFeed.ids.contains(task.id) &&
              _repeatingTask(task) == null =>
        ReminderTarget(kind: ReminderTargetKind.task, recordId: task.id),
      CalendarEvent event
          when !event.isReadOnly &&
              event.recurringSeriesId == null &&
              !_eventSeriesIds.contains(event.id) &&
              (event.plannedTaskId == null || _allows(EasyFeature.planning)) =>
        targetForLocalCalendarEvent(event),
      _ => null,
    };
  }

  bool _hasRecordReminder(Object? record) {
    final key = _recordReminderTarget(record)?.notificationId;
    if (key == null) return false;
    try {
      return readRecordReminderPreferences(
        _data.sections[recordRemindersSection],
      ).containsKey(key);
    } catch (_) {
      return false;
    }
  }

  Future<void> _editRecordReminder(Object record) async {
    final target = _recordReminderTarget(record);
    if (target == null || _reviewSaving) return;
    final raw = _data.sections[recordRemindersSection];
    final String key = target.notificationId;
    final Map<String, RecordReminderPreference> preferences;
    try {
      preferences = readRecordReminderPreferences(raw);
    } catch (_) {
      _inform('Your saved reminders could not be opened.');
      return;
    }
    final choice = await showRecordReminderEditor(
      context,
      target: target,
      initial: preferences[key],
      start: record is CalendarEvent ? record.start : null,
    );
    if (choice == null || !mounted) return;
    final previous = _data;
    final records = record is CalendarEvent ? previous.events : previous.tasks;
    if (!identical(raw, previous.sections[recordRemindersSection]) ||
        _recordReminderTarget(record) == null ||
        !records.any((value) => identical(value, record))) {
      _inform('The record changed. Open it again to edit its reminder.');
      return;
    }
    final next = {...preferences};
    if (choice.preference case final preference?) {
      next[key] = preference;
    } else {
      next.remove(key);
    }
    if (next.length > maxRecordReminderPreferences) {
      _inform('The workspace has reached its reminder preference limit.');
      return;
    }
    try {
      final updated = previous.withSection(recordRemindersSection, [
        for (final value in next.values) value.toJson(),
      ]);
      await _commitReviewedData(previous, updated);
      _queueReminderSync(updated, force: true, immediate: true);
      if (mounted) {
        _inform(
          choice.preference == null ? 'Reminder removed' : 'Reminder saved',
        );
      }
    } catch (_) {
      if (mounted) _inform('The reminder could not be saved.');
    }
  }
}
