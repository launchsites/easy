part of 'main.dart';

typedef _WorkspaceObjectiveInput = ({
  List<TaskItem> tasks,
  List<CalendarEvent> events,
  DateTime now,
  DateTime horizonEnd,
  Set<String>? focusCategories,
  SchedulingSettings? settings,
  TimeSpan? verifiedSpan,
  bool calendarComplete,
});

TaskObjectiveReview _reviewWorkspaceObjectives(_WorkspaceObjectiveInput input) {
  final availability = deriveTaskObjectiveAvailability(
    now: input.now,
    horizonEnd: input.horizonEnd,
    settings: input.settings,
    confirmedEvents: input.events,
    categories:
        input.focusCategories ??
        {
          for (final task in input.tasks)
            if (!task.done) task.category,
        },
    verifiedCalendarSpan: input.verifiedSpan,
    calendarComplete: input.calendarComplete,
  );
  return reviewTaskObjectives(
    tasks: input.tasks,
    events: input.events,
    now: input.now,
    horizonEnd: input.horizonEnd,
    focusCategories: input.focusCategories,
    verifiedAvailability: availability,
  );
}

extension _WorkspaceTaskObjectives on _WorkspaceState {
  Future<void> _openTaskObjectives() async {
    if (_taskObjectivesOpen ||
        _reviewSaving ||
        !_allows(EasyFeature.planning)) {
      return;
    }
    _taskObjectivesOpen = true;
    try {
      await _reviewTaskObjectives();
    } finally {
      _taskObjectivesOpen = false;
    }
  }

  Future<void> _reviewTaskObjectives() async {
    final day = _today;
    final scope = _focus;
    final first = plusDays(day, -1);
    final last = plusDays(day, 1);
    final selectedSources = (
      _calendarPreferences,
      _eventSeries,
      _icsCalendars,
      _allows(EasyFeature.externalCalendars),
    );
    final refreshed = await _planningCalendar(
      day,
      firstDay: first,
      lastDay: last,
      reportProblem: false,
    );
    if (!mounted ||
        scope != _focus ||
        day != _today ||
        _reviewSaving ||
        selectedSources !=
            (
              _calendarPreferences,
              _eventSeries,
              _icsCalendars,
              _allows(EasyFeature.externalCalendars),
            )) {
      return;
    }
    final now = DateTime.now();
    final horizon = plusDays(day, 1);
    if (!horizon.isAfter(now)) return;
    final preferences = _calendarPreferences;
    final workspace = _data;
    final apple = _appleFeed.events;
    final imports = _icsFeed.events;
    final series = _internalFeed.events;
    final hasApple = _selectedAppleCalendars.isNotEmpty;
    final hasImports = _selectedIcsCalendars.isNotEmpty;
    final hasSeries = _eventSeries.isNotEmpty;

    SchedulingSettings? settings;
    try {
      settings = _planningPreferences(expandCategories: true);
    } on Object {
      // Grouping remains available. There is no verified work window.
    }

    final local = _standaloneEvents(workspace.events).toList();
    final linked = <CalendarOccurrenceIdentity, CalendarEvent>{
      if (hasApple &&
          (workspace.sections[_appleCopiesKey] != null ||
              _unsavedAppleCopies.isNotEmpty))
        for (final event in local) ?_appleCopyFor(event.id): event,
    };
    final coverageEnd = plusDays(last, 1);
    bool uncertain(CalendarEventStatus value, DateTime start, DateTime end) =>
        value != CalendarEventStatus.confirmed &&
        value != CalendarEventStatus.cancelled &&
        start.isBefore(coverageEnd) &&
        end.isAfter(first);
    var unconfirmed = false;
    final trusted = [...local];
    if (refreshed != null) {
      if (hasSeries) trusted.addAll(series.map((row) => row.event));
      if (hasApple) {
        for (final row in apple) {
          final event = row.event;
          if (!event.blocksTime) continue;
          if (_sameAppleEvent(linked[row.id], event)) continue;
          if (event.status == CalendarEventStatus.confirmed) {
            trusted.add(_fromApple(row));
          } else if (uncertain(event.status, event.start, event.end)) {
            unconfirmed = true;
          }
        }
      }
      if (hasImports) {
        for (final row in imports) {
          if (!row.event.blocksTime) continue;
          if (row.status == CalendarEventStatus.confirmed) {
            trusted.add(row.event);
          } else if (uncertain(row.status, row.event.start, row.event.end)) {
            unconfirmed = true;
          }
        }
      }
    }
    final tasks = _workspaceTasks;
    final categories = _expandCategoryScope(scope);
    final review = await compute(_reviewWorkspaceObjectives, (
      tasks: tasks,
      events: trusted,
      now: now,
      horizonEnd: horizon,
      focusCategories: categories,
      settings: settings,
      verifiedSpan: refreshed != null && !unconfirmed
          ? TimeSpan(first, coverageEnd)
          : null,
      calendarComplete:
          refreshed != null && !hasApple && !hasImports && !hasSeries,
    ));
    if (!mounted || !_allows(EasyFeature.planning) || _reviewSaving) return;
    if (!identical(workspace, _data) ||
        scope != _focus ||
        preferences != _calendarPreferences ||
        (apple, imports, series) !=
            (_appleFeed.events, _icsFeed.events, _internalFeed.events)) {
      _inform('The workspace changed. Open the suggestions again.');
      return;
    }
    final selected = await showTaskObjectives(
      context,
      review: review,
      onPlanDay:
          tasks.any(
            (task) =>
                !task.done &&
                (task.estimatedMinutes ?? 0) > 0 &&
                (categories?.contains(task.category) ?? true),
          )
          ? _planDay
          : null,
    );
    if (!mounted || selected == null) return;
    final task = _workspaceTasks
        .where((item) => item.id == selected)
        .firstOrNull;
    if (task == null || task.done) {
      _inform('This task changed. Open the suggestions again.');
      return;
    }
    await _openRecord(task);
  }
}
