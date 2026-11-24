part of 'main.dart';

typedef _TodayFitInput = ({
  List<TaskItem> tasks,
  List<CalendarEvent> events,
  List<InternalRecurringEvent> series,
  List<WorkspaceIcsCalendar> imports,
  TimeSpan? coverage,
  SchedulingSettings settings,
  Set<String>? categories,
  Set<String> excludedTasks,
  DateTime now,
});

typedef _TodayFitResult = ({String? id, DateTime at, DateTime checkAt});

_TodayFitResult _projectTodayFit(_TodayFitInput input) {
  final now = input.now;
  final day = dateOnly(now);
  final end = plusDays(day, 1);
  var checkAt = end;
  void consider(DateTime instant) {
    if (instant.isAfter(now) && instant.isBefore(checkAt)) checkAt = instant;
  }

  final eligible = {
    for (final task in input.tasks)
      if ((task.dueAt ?? task.date)?.toLocal() case final due?
          when !task.done &&
              (task.estimatedMinutes ?? 0) > 0 &&
              !input.excludedTasks.contains(task.id) &&
              (input.categories?.contains(task.category) ?? true) &&
              sameDay(due, day))
        task.id: task,
  };
  if (eligible.isEmpty || !end.isAfter(now)) {
    return (id: null, at: now, checkAt: end);
  }
  final scopes = {for (final task in eligible.values) task.category};
  final settings = input.settings;
  final coverage = input.coverage;
  final events = coverage == null
      ? input.events
      : [
          ...input.events,
          if (input.series.isNotEmpty)
            for (final row in expandInternalWorkspace((
              sources: input.series,
              start: coverage.start,
              end: coverage.end,
            )))
              row.event,
          if (input.imports.isNotEmpty)
            for (final row in expandWorkspaceIcs((
              calendars: input.imports,
              start: coverage.start,
              end: coverage.end,
            )))
              if (row.status != CalendarEventStatus.cancelled) row.event,
        ];
  for (final event in events) {
    if (!event.blocksTime) continue;
    consider(event.start.subtract(Duration(minutes: settings.beforeMinutes)));
    consider(event.end.add(Duration(minutes: settings.afterMinutes)));
  }
  for (final task in eligible.values) {
    if (task.earliestStart case final after?) consider(after);
    if (task.dueAt case final deadline?) consider(deadline);
  }
  final prerequisites = {
    for (final task in eligible.values) ...task.prerequisiteIds,
  };
  if (prerequisites.isNotEmpty) {
    for (final task in input.tasks) {
      if (task.completedAt case final completed?
          when prerequisites.contains(task.id)) {
        consider(completed);
      }
    }
  }
  final horizon = TimeSpan(now, end);
  for (final window in settings.availabilityFor(
    horizon: horizon,
    categories: scopes,
  )) {
    consider(window.span.start);
    consider(window.span.end);
  }

  final available = deriveTaskObjectiveAvailability(
    now: now,
    horizonEnd: end,
    settings: settings,
    confirmedEvents: events,
    categories: scopes,
    calendarComplete: coverage == null,
    verifiedCalendarSpan: coverage,
  );
  if (!available.byCategory.values.any((gap) => gap > Duration.zero)) {
    return (id: null, at: now, checkAt: checkAt);
  }
  final review = reviewTaskObjectives(
    tasks: input.tasks,
    events: events,
    now: now,
    horizonEnd: end,
    focusCategories: scopes,
    candidateIds: eligible.keys.toSet(),
    verifiedAvailability: available,
  );
  for (final objective in review.ready) {
    final task = eligible[objective.id];
    final effort = objective.unreservedEffort;
    final gap = task == null ? null : available.byCategory[task.category];
    if (task == null ||
        effort == null ||
        gap == null ||
        objective.fit != ObjectiveFit.complete ||
        objective.reservedEffort != Duration.zero ||
        effort <= Duration.zero) {
      continue;
    }
    var latest = now.add(gap).subtract(effort);
    if (task.dueAt case final deadline?) {
      final beforeDeadline = deadline.subtract(effort);
      if (beforeDeadline.isBefore(latest)) latest = beforeDeadline;
    }
    if (!latest.isAfter(now)) continue;
    consider(latest);
    return (id: task.id, at: now, checkAt: checkAt);
  }
  return (id: null, at: now, checkAt: checkAt);
}

extension _WorkspaceTodayFit on _WorkspaceState {
  Object get _todayFitRevision => (
    _reviewAvailabilityRevision,
    _data.tasks,
    _data.sections[recurringTasksSection],
    _data.sections[_activitiesKey],
    _gymSessions,
    _focus,
    _today,
    _appleFeed.events,
    _appleFeed.hasCurrentCoverage,
    _appleCopyRevision,
  );

  _TodayFitResult? _currentTodayFit(DateTime now) {
    final fit = _todayFit;
    return fit != null &&
            _todayFitSource == _todayFitRevision &&
            !now.isBefore(fit.at) &&
            now.isBefore(fit.checkAt)
        ? fit
        : null;
  }

  String? get _todayFitsNowTaskId => _currentTodayFit(DateTime.now())?.id;

  bool get _maySuggestTodayFit =>
      mounted &&
      !_loading &&
      !_reviewSaving &&
      _automationForeground &&
      _destination == _Destination.today &&
      _allows(EasyFeature.planning) &&
      _data.sections[_scheduleSettingsKey] != null &&
      (_focus?.sections.contains(FocusSection.tasks) ?? true) &&
      identical(_data, _savedWorkspace) &&
      _calendarSourcesReadable &&
      !_taskSeriesUnreadable &&
      (!_allows(EasyFeature.workouts) || _gymSessions != null) &&
      _gymSessions?.lastOrNull?.finished != false;

  List<CalendarEvent>? _appleEventsForTodayFit(
    Set<CalendarIdentity> selected,
    TimeSpan coverage,
  ) {
    if (selected.isEmpty) return const [];
    if (!_appleFeed.hasCurrentCoverage ||
        !_appleFeed.covers(coverage.start) ||
        !_appleFeed.covers(
          coverage.end.subtract(const Duration(microseconds: 1)),
        ) ||
        selected.any((id) => _appleFeed.sources[id]?.canRead != true)) {
      return null;
    }
    final linked = <CalendarOccurrenceIdentity, CalendarEvent>{
      if (_data.sections[_appleCopiesKey] != null ||
          _unsavedAppleCopies.isNotEmpty)
        for (final event in _standaloneEvents(_data.events))
          ?_appleCopyFor(event.id): event,
    };
    final trusted = <CalendarEvent>[];
    for (final row in _appleFeed.events) {
      final event = row.event;
      if (!selected.contains(row.id.calendar) ||
          !event.blocksTime ||
          event.status == CalendarEventStatus.cancelled ||
          !event.start.isBefore(coverage.end) ||
          !coverage.start.isBefore(event.end) ||
          _sameAppleEvent(linked[row.id], event)) {
        continue;
      }
      if (event.status != CalendarEventStatus.confirmed) return null;
      trusted.add(_fromApple(row));
    }
    return trusted;
  }

  void _queueTodayFit([Duration? delay]) {
    _todayFitTimer?.cancel();
    if (!_maySuggestTodayFit) return;
    final now = DateTime.now();
    final cached = _currentTodayFit(now);
    _todayFitTimer = Timer(
      delay ??
          cached?.checkAt.difference(now) ??
          const Duration(milliseconds: 40),
      () => unawaited(_updateTodayFit()),
    );
  }

  Future<void> _updateTodayFit() async {
    if (!_maySuggestTodayFit) return;
    if (_todayFitChecking) {
      _todayFitQueued = true;
      return;
    }
    final source = _todayFitRevision;
    _todayFitChecking = true;
    try {
      final settings = _planningPreferences(expandCategories: true);
      if (settings == null ||
          settings.availability.isEmpty ||
          _activityData().active != null) {
        return;
      }
      final now = DateTime.now();
      final day = dateOnly(now);
      final end = plusDays(day, 1);
      final selectedApple = _selectedAppleCalendars;
      final imports = _selectedIcsCalendars;
      final coverage =
          selectedApple.isNotEmpty ||
              imports.isNotEmpty ||
              _eventSeries.isNotEmpty
          ? TimeSpan(plusDays(day, -1), plusDays(day, 2))
          : null;
      final apple = coverage == null
          ? const <CalendarEvent>[]
          : _appleEventsForTodayFit(selectedApple, coverage);
      if (apple == null) return;
      final excludedTasks = <String>{};
      DateTime? manualUntil;
      for (final row in _taskFeed.workspaceOccurrences(_data.tasks, day)) {
        if (row.manualSchedule != null || row.constraintIssue != null) {
          excludedTasks.add(row.id);
        }
      }
      for (final series in _taskFeed.series) {
        for (final schedule in series.pendingManualSchedules) {
          if (schedule.start.isBefore(end) &&
              schedule.end.isAfter(now) &&
              (manualUntil == null || schedule.end.isAfter(manualUntil))) {
            manualUntil = schedule.end.isBefore(end) ? schedule.end : end;
          }
        }
      }
      final input = (
        tasks: _workspaceTasks,
        events: _eventSeries.isEmpty && apple.isEmpty
            ? _data.events
            : [..._standaloneEvents(_data.events), ...apple],
        series: _eventSeries,
        imports: imports,
        coverage: coverage,
        settings: settings,
        categories: _expandCategoryScope(_focus),
        excludedTasks: excludedTasks,
        now: now,
      );
      final next = manualUntil != null
          ? (id: null, at: now, checkAt: manualUntil)
          : input.series.isNotEmpty ||
                input.imports.isNotEmpty ||
                input.tasks.length + input.events.length > 2000
          ? await compute(_projectTodayFit, input)
          : _projectTodayFit(input);
      if (!_maySuggestTodayFit || source != _todayFitRevision) return;
      _changeWorkspaceView(() {
        _todayFit = next;
        _todayFitSource = source;
      });
      final delay = next.checkAt.difference(DateTime.now());
      _queueTodayFit(
        delay.isNegative ? const Duration(milliseconds: 100) : delay,
      );
    } on Object {
      if (mounted) _changeWorkspaceView(() => _todayFit = null);
    } finally {
      _todayFitChecking = false;
      if (_todayFitQueued) {
        _todayFitQueued = false;
        _queueTodayFit();
      }
    }
  }
}
