part of 'main.dart';

typedef _WorkspaceTaskContextInput = ({
  List<TaskItem> tasks,
  List<RecurringTaskSeries> repeats,
  Object activities,
  WorkspaceCategories categories,
  DateTime asOf,
});

TaskContextIndex _buildWorkspaceTaskContext(_WorkspaceTaskContextInput input) {
  final activities = ActivityData.fromJson(
    input.activities as Map<String, Object?>,
  ).records;
  final linked = {
    for (final record in activities)
      if (record.finishedAt != null &&
          record.target?.kind == ActivityTargetKind.task)
        record.target!.id,
  };
  TaskContextTarget target(TaskItem task, [String? seriesId]) =>
      TaskContextTarget(
        id: task.id,
        title: task.title,
        category: input.categories.canonicalId(task.category) ?? task.category,
        seriesId: seriesId,
        completedAt: task.done ? task.completedAt : null,
      );
  return TaskContextIndex.build(
    tasks: [
      for (final task in input.tasks)
        if (linked.contains(task.id)) target(task),
      for (final series in input.repeats)
        for (final row in series.completions)
          if (linked.contains(row.id)) target(row.task, series.id),
    ],
    activities: activities,
    asOf: input.asOf,
  );
}

extension _WorkspaceTaskContext on _WorkspaceState {
  bool get _hasTaskHistory =>
      _allows(EasyFeature.activity) && _data.sections[_activitiesKey] != null;

  Object get _taskHistoryKey => (
    _taskHistoryRevision,
    _today,
    _data.sections[_activitiesKey],
    _data.sections[_categorySettingsKey],
    _data.sections[recurringTasksSection],
  );

  bool _changesTaskEvidence(List<TaskItem> before, List<TaskItem> after) {
    if (identical(before, after)) return false;
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      final old = before[i];
      final next = after[i];
      if (old.id != next.id ||
          old.title != next.title ||
          old.category != next.category ||
          old.done != next.done ||
          old.completedAt != next.completedAt) {
        return true;
      }
    }
    return false;
  }

  bool get _needsEstimateHistory =>
      _hasTaskHistory && (_ai?.settings.includeOptionalMetadata ?? false);

  bool get _taskHistoryReady =>
      _taskHistoryCacheKey == _taskHistoryKey && _taskHistoryCache != null;

  Future<bool> _prepareTaskHistory() async {
    if (!_hasTaskHistory || _taskHistoryReady) return true;
    final key = _taskHistoryKey;
    if (_taskHistoryCacheKey != key || _buildingTaskHistory == null) {
      _taskHistoryCacheKey = key;
      _taskHistoryCache = null;
      _buildingTaskHistory = compute(_buildWorkspaceTaskContext, (
        tasks: _data.tasks,
        repeats: _taskFeed.series,
        activities: _data.sections[_activitiesKey]!,
        categories: _catalog,
        asOf: DateTime.now(),
      ), debugLabel: 'Confirmed task history');
    }
    final pending = _buildingTaskHistory!;
    try {
      final data = await pending;
      if (!mounted || _taskHistoryKey != key || !_hasTaskHistory) return false;
      _taskHistoryCache = data;
      return true;
    } catch (_) {
      if (identical(pending, _buildingTaskHistory)) _buildingTaskHistory = null;
      return false;
    }
  }

  TaskContextEvidence? _timingFor(TaskItem task) {
    if (!_hasTaskHistory || !_taskHistoryReady) return null;
    return _taskHistoryCache!.evidenceFor(
      TaskContextTarget(
        id: task.id,
        title: task.title,
        category: _catalog.canonicalId(task.category) ?? task.category,
        seriesId: _repeatingTask(task)?.series.id,
        completedAt: task.completedAt,
      ),
    );
  }

  TaskDurationEvidence? _providerDurationHistoryFor(TaskItem task) {
    final history = _timingFor(task)?.duration;
    return estimateFromConfirmedHistory(history) == null ? null : history;
  }

  bool _canSeeTaskTiming(Object? record) =>
      record is TaskItem && _hasTaskHistory;

  Future<void> _openTaskTiming(TaskItem task) async {
    final ready = await _prepareTaskHistory();
    if (!mounted) return;
    if (!ready) {
      _inform('Timing history is unavailable.');
      return;
    }
    final observed = _timingFor(task);
    final duration = observed?.duration;
    final exact = observed?.exactElapsed;
    final recurrence = observed?.recurrence;
    final minutes = estimateFromConfirmedHistory(duration)?.duration.inMinutes;
    final canUse =
        minutes != null &&
        !task.done &&
        task.estimatedMinutes == null &&
        _repeatingTask(task) == null &&
        taskSplitIssue(
              allowSplit: task.allowSplit,
              minimumChunkMinutes: task.minimumChunkMinutes,
              estimatedMinutes: minutes,
            ) ==
            null;
    final chosen = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Timing history'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 9,
          children: [
            Text(task.title, style: sectionHeadingStyle),
            if (exact != null)
              Text(
                '${_observedDuration(exact.elapsed)} recorded across ${exact.activityCount} activities',
              ),
            if (duration != null) ...[
              Text(duration.cohort.label, style: contentMetadataStyle),
              Text(
                '${_observedDuration(duration.median)} median · ${duration.sampleCount} observed',
              ),
              Text(
                '${_observedDuration(duration.lower)} to ${_observedDuration(duration.upper)} '
                '${duration.sampleCount < 5 ? 'observed range' : 'middle range'}',
                style: contentMetadataStyle,
              ),
              Text(
                duration.newestAge.inDays == 0
                    ? 'Most recent today'
                    : 'Most recent ${duration.newestAge.inDays} days ago',
                style: contentMetadataStyle,
              ),
            ],
            if (recurrence?.commonWeekday case final weekday?)
              Text(
                'Most observed starts on ${_taskWeekdays[weekday - 1]}',
                style: contentMetadataStyle,
              ),
            if (exact == null && duration == null)
              const Text('No comparable finished timers yet.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          if (canUse)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use median estimate'),
            ),
        ],
      ),
    );
    if (!mounted || chosen != true || minutes == null) return;
    if (!_data.tasks.any((value) => identical(value, task)) ||
        !_taskHistoryReady) {
      _inform('The task or its timing history changed. Review it again.');
      return;
    }
    _saveRecord(task.withEstimate(minutes));
  }
}

String _observedDuration(Duration duration) => duration.inMinutes >= 1
    ? '${duration.inMinutes} min'
    : '${duration.inSeconds} sec';

const _taskWeekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
