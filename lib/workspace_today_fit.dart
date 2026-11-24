part of 'main.dart';

typedef _TodayFitInput = ({
  List<TaskItem> tasks,
  List<CalendarEvent> events,
  SchedulingSettings settings,
  Set<String>? categories,
  DateTime now,
});

typedef _TodayFitResult = ({String? id, DateTime checkAt});

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
              (input.categories?.contains(task.category) ?? true) &&
              sameDay(due, day))
        task.id: task,
  };
  if (eligible.isEmpty || !end.isAfter(now)) return (id: null, checkAt: end);
  final scopes = {for (final task in eligible.values) task.category};
  final settings = input.settings;
  final events = input.events;
  for (final event in events) {
    consider(event.start.subtract(Duration(minutes: settings.beforeMinutes)));
    consider(event.end.add(Duration(minutes: settings.afterMinutes)));
  }
  for (final task in eligible.values) {
    if (task.earliestStart case final after?) consider(after);
    if (task.dueAt case final deadline?) consider(deadline);
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
    calendarComplete: true,
  );
  if (!available.byCategory.values.any((gap) => gap > Duration.zero)) {
    return (id: null, checkAt: checkAt);
  }
  final review = reviewTaskObjectives(
    tasks: input.tasks,
    events: events,
    now: now,
    horizonEnd: end,
    focusCategories: scopes,
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
    return (id: task.id, checkAt: checkAt);
  }
  return (id: null, checkAt: checkAt);
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
  );

  String? get _todayFitsNowTaskId {
    final fit = _todayFit;
    return fit != null &&
            _todayFitSource == _todayFitRevision &&
            DateTime.now().isBefore(fit.checkAt)
        ? fit.id
        : null;
  }

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
      _selectedAppleCalendars.isEmpty &&
      _selectedIcsCalendars.isEmpty &&
      _eventSeries.isEmpty &&
      (!_allows(EasyFeature.workouts) || _gymSessions != null) &&
      _gymSessions?.lastOrNull?.finished != false;

  void _queueTodayFit([Duration delay = const Duration(milliseconds: 40)]) {
    _todayFitTimer?.cancel();
    if (!_maySuggestTodayFit) return;
    _todayFitTimer = Timer(delay, () => unawaited(_updateTodayFit()));
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
      final input = (
        tasks: _workspaceTasks,
        events: _data.events,
        settings: settings,
        categories: _expandCategoryScope(_focus),
        now: DateTime.now(),
      );
      final next = input.tasks.length + input.events.length > 2000
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
