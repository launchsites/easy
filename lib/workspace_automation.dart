part of 'main.dart';

const _automationKey = 'automationRules';

extension _WorkspaceAutomation on _WorkspaceState {
  AutomationData _automationData(WorkspaceData workspace) {
    final raw = workspace.sections[_automationKey];
    final cached = _cachedAutomation;
    if (cached != null && identical(raw, _automationCacheKey)) return cached;
    final decoded = raw == null
        ? AutomationData()
        : AutomationData.fromJson(raw as Map<String, Object?>);
    _automationCacheKey = raw;
    _cachedAutomation = decoded;
    return decoded;
  }

  bool get _automationForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  WorkspaceData _withAutomationEvents(
    WorkspaceData workspace,
    Iterable<AutomationEvent> events,
  ) {
    if (!_automationForeground || workspace.sections[_automationKey] == null) {
      return workspace;
    }
    final AutomationData rules;
    try {
      rules = _automationData(workspace);
    } on Object {
      return workspace;
    }
    if (!rules.enabled) return workspace;
    var next = rules;
    final now = DateTime.now();
    for (final event in events) {
      next = next
          .dispatch(
            event,
            currentSourceRevision: event.sourceRevision,
            now: now,
            foreground: true,
          )
          .data;
    }
    return identical(rules, next)
        ? workspace
        : workspace.withSection(_automationKey, next.toJson());
  }

  Future<void> _openAutomation() async {
    if (_automationOpen) return;
    final AutomationData settings;
    try {
      settings = _automationData(_data);
    } on Object {
      _inform('The saved rules could not be opened.');
      return;
    }
    _automationOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AutomationPage(
            data: settings,
            onChange: _updateAutomation,
            onAcceptDraft: _acceptAutomationDraft,
            categories: _categories(),
            enabledTriggers: {
              AutomationTrigger.taskCompleted,
              AutomationTrigger.acceptedEventStarted,
              if (_allows(EasyFeature.workouts))
                AutomationTrigger.workoutFinished,
              if (_allows(EasyFeature.reviews)) AutomationTrigger.reviewSaved,
            },
          ),
        ),
      );
    } finally {
      _automationOpen = false;
    }
  }

  Future<AutomationData> _updateAutomation(
    AutomationData Function(AutomationData) change,
  ) async {
    final workspace = _data;
    final next = change(_automationData(workspace));
    await _commitReviewedData(
      workspace,
      workspace.withSection(_automationKey, next.toJson()),
    );
    if (mounted) _queueAutomationCalendarCheck();
    return next;
  }

  Future<AutomationData> _acceptAutomationDraft(String id) async {
    final workspace = _data;
    final current = _automationData(workspace);
    final draft = current.draftById(id);
    if (draft == null || draft.status != AutomationDraftStatus.pending) {
      throw const FormatException('This draft has already been reviewed.');
    }
    final revision = await _currentAutomationSource(draft.event);
    if (!mounted ||
        !identical(workspace, _data) ||
        revision == null ||
        revision != draft.event.sourceRevision) {
      throw const FormatException(
        'The source changed. Review its current state.',
      );
    }
    final recordId = 'automation-$id';
    if (workspace.tasks.any((task) => task.id == recordId) ||
        workspace.notes.any((note) => note.id == recordId)) {
      throw const FormatException('This draft is already in the workspace.');
    }
    final action = draft.action;
    final rawCategory = action.category;
    final category = rawCategory == null ? null : _catalog.resolve(rawCategory);
    if (rawCategory != null && (category == null || category.archived)) {
      throw const FormatException('This draft’s category is unavailable.');
    }
    final now = DateTime.now();
    final next = current.reviewDraft(
      id,
      status: AutomationDraftStatus.accepted,
      now: now,
      currentSourceRevision: revision,
    );
    final String title;
    final String body;
    if (action.kind == AutomationActionKind.noteDraft) {
      final split = action.text.indexOf('\n');
      title = split < 0 ? action.text : action.text.substring(0, split).trim();
      body = split < 0 ? '' : action.text.substring(split + 1);
    } else {
      title = action.text;
      body = '';
    }
    final updated = switch (action.kind) {
      AutomationActionKind.taskDraft => workspace.copyWith(
        tasks: [
          ...workspace.tasks,
          TaskItem(
            id: recordId,
            title: title,
            category: category?.id ?? '',
            date: _captureDefaults.dateFor(now),
            schedulingHold: taskSchedulingHoldHint(title),
          ),
        ],
      ),
      AutomationActionKind.noteDraft => workspace.copyWith(
        notes: [
          ...workspace.notes,
          NoteItem(
            id: recordId,
            title: title,
            body: body,
            category: category?.id,
            updated: now,
          ),
        ],
      ),
    };
    await _commitReviewedData(
      workspace,
      updated.withSection(_automationKey, next.toJson()),
      operationId: 'automation-accept-$id',
    );
    return next;
  }

  Future<int?> _currentAutomationSource(AutomationEvent source) async {
    final id = source.sourceId;
    final AutomationEvent? current;
    switch (source.trigger) {
      case AutomationTrigger.taskCompleted:
        final task = _taskFeed
            .insightTasks(_data.tasks)
            .where((item) => item.id == id)
            .firstOrNull;
        current = task == null ? null : automationForTask(task);
      case AutomationTrigger.acceptedEventStarted:
        var event = _standaloneEvents(_data.events)
            .where((item) => item.id == id)
            .firstOrNull;
        if (event == null && _eventSeries.isNotEmpty) {
          final occurrences = await _automationSeriesForDay(
            source.occurredAt.toLocal(),
          );
          event = occurrences
              .where((row) => row.event.id == id)
              .firstOrNull
              ?.event;
        }
        current = event == null ? null : automationForCalendar(event);
      case AutomationTrigger.workoutFinished:
        final workout = _gymSessions
            ?.where(
              (item) =>
                  'workout-${item.startedAt.microsecondsSinceEpoch}' == id,
            )
            .firstOrNull;
        current = workout == null ? null : automationForWorkout(workout);
      case AutomationTrigger.reviewSaved:
        final review = _readReviewData(_data);
        final entry = review.reflections
            .where((item) => item.id == id)
            .firstOrNull;
        current = entry == null ? null : automationForReflection(entry);
    }
    return current?.key == source.key ? current!.sourceRevision : null;
  }

  AutomationEvent? _automationForRepeatedTask(
    RecurringTaskSeries series,
    String id,
  ) {
    final occurrence = series.completions
        .where((item) => item.id == id)
        .firstOrNull;
    if (occurrence == null) return null;
    final day = occurrence.scheduledDate;
    final task = occurrence.task;
    return automationForTask(
      task.date != null
          ? task
          : task.withDate(DateTime(day.year, day.month, day.day)),
    );
  }

  void _persistWorkoutWithAutomation() {
    final workspace = _data;
    final sessions = _gymSessions!;
    final workspaceJson = workspace.encode();
    final sessionJson = [for (final session in sessions) session.encode()];
    _queueSave(() async {
      final saved = await _store!.read();
      await _saveMutation(
        WorkspaceMutation.replace(
          WorkspaceSnapshot(
            workspaceJson: workspaceJson,
            gymSessionJson: sessionJson,
            workoutPlanJson: saved.snapshot.workoutPlanJson,
          ),
        ),
      );
      _savedWorkspace = workspace;
      _savedGymSessions = sessions;
      _queueReminderSync(workspace);
      _queueAutomationCalendarCheck();
      _queueTodayFit();
    }, _persistWorkoutWithAutomation);
  }

  ReviewData _readReviewData(WorkspaceData workspace) {
    final raw = workspace.sections[_reviewsKey];
    return raw == null
        ? ReviewData()
        : ReviewData.fromJson(raw as Map<String, Object?>);
  }

  Future<void> _saveReviewWithAutomation(ReviewData next) async {
    final workspace = _data;
    final updated = workspace.withSection(_reviewsKey, next.toJson());
    if (workspace.sections[_automationKey] == null) {
      await _commitReviewedData(workspace, updated);
      return;
    }
    final previousIds = _readReviewData(workspace).reflections
        .map((entry) => entry.id)
        .toSet();
    await _commitReviewedData(
      workspace,
      _withAutomationEvents(updated, [
        for (final reflection in next.reflections)
          if (!previousIds.contains(reflection.id))
            ?automationForReflection(reflection),
      ]),
    );
  }

  Future<List<InternalWorkspaceEvent>> _automationSeriesForDay(
    DateTime date,
  ) async {
    if (_eventSeries.isEmpty) return const [];
    final day = dateOnly(date);
    final previous = plusDays(day, -1);
    final next = plusDays(day, 1);
    if (_internalFeed.problem == null &&
        _internalFeed.covers(previous) &&
        _internalFeed.covers(next)) {
      return _internalFeed.events;
    }
    final revision = (day, _eventSeries);
    if (_automationSeriesKey != revision || _automationSeriesWindow == null) {
      _automationSeriesKey = revision;
      _automationSeriesWindow = compute(expandInternalWorkspace, (
        sources: _eventSeries,
        start: previous,
        end: plusDays(next, 1),
      ));
    }
    final pending = _automationSeriesWindow!;
    try {
      return await pending;
    } on Object {
      if (identical(pending, _automationSeriesWindow)) {
        _automationSeriesWindow = null;
      }
      return const [];
    }
  }

  Iterable<CalendarEvent> _automationEvents(
    WorkspaceData workspace,
    List<InternalWorkspaceEvent> rows,
  ) sync* {
    yield* _standaloneEvents(workspace.events);
    for (final row in rows) {
      yield row.event;
    }
  }

  bool get _hasCalendarAutomation {
    if (!_automationForeground ||
        _loading ||
        _data.sections[_automationKey] == null) {
      return false;
    }
    try {
      final config = _automationData(_data);
      return config.enabled &&
          config.rules.any(
            (rule) =>
                rule.enabled &&
                rule.trigger == AutomationTrigger.acceptedEventStarted,
          );
    } on Object {
      return false;
    }
  }

  void _queueAutomationCalendarCheck([Duration delay = Duration.zero]) {
    _automationCalendarTimer?.cancel();
    if (!mounted || !_hasCalendarAutomation) return;
    _automationCalendarTimer = Timer(
      delay,
      () => unawaited(_checkAutomationCalendar()),
    );
  }

  Future<void> _checkAutomationCalendar() async {
    if (!mounted || !_hasCalendarAutomation) return;
    if (_reviewSaving || !identical(_data, _savedWorkspace)) return;
    final workspace = _data;
    final definitions = _eventSeries;
    final rows = await _automationSeriesForDay(DateTime.now());
    if (!mounted ||
        !_hasCalendarAutomation ||
        _reviewSaving ||
        !identical(workspace, _data) ||
        !identical(definitions, _eventSeries)) {
      return;
    }
    final now = DateTime.now();
    final active = <AutomationEvent>[];
    var nextStart = plusDays(dateOnly(now), 1);
    for (final event in _automationEvents(workspace, rows)) {
      if (event.allDay ||
          event.isReadOnly ||
          !event.end.isAfter(now) ||
          !event.end.isAfter(event.start)) {
        continue;
      }
      if (event.start.isAfter(now)) {
        if (event.start.isBefore(nextStart)) {
          nextStart = event.start;
        }
      } else if (automationForCalendar(event) case final source?) {
        active.add(source);
      }
    }
    active.sort((a, b) {
      final byTime = a.occurredAt.compareTo(b.occurredAt);
      return byTime == 0 ? a.key.compareTo(b.key) : byTime;
    });
    final updated = _withAutomationEvents(workspace, active);
    if (!identical(updated, workspace)) {
      try {
        await _commitReviewedData(workspace, updated);
      } on Object {
        // The exact rule and event are checked again from the next saved view.
        return;
      }
    }
    if (!mounted) return;
    final delay = nextStart.difference(DateTime.now());
    _queueAutomationCalendarCheck(
      delay > Duration.zero ? delay : Duration.zero,
    );
  }
}
