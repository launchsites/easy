part of 'main.dart';

extension _WorkspaceFocusSuggestions on _WorkspaceState {
  Future<void> _loadFocusSuggestions() async {
    final preferences = await _focusSuggestionStore.load();
    if (mounted && !_focusSuggestionSaving) {
      _changeWorkspaceView(() => _focusSuggestionPreferences = preferences);
    }
  }

  Future<void> _openFocusSuggestionSettings() async {
    final enabled = _focusSuggestionPreferences.enabled;
    final decision = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calendar focus suggestions'),
        content: Text(
          enabled
              ? 'Suggestions are on for this device. You choose when to switch.'
              : 'Offer a focus mode when a confirmed event matches one of your selected calendars. You choose when to switch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, !enabled),
            child: Text(enabled ? 'Turn off' : 'Turn on'),
          ),
        ],
      ),
    );
    if (!mounted || decision == null) return;
    await _saveFocusSuggestionPreferences(
      _focusSuggestionPreferences.withEnabled(decision),
    );
  }

  Future<bool> _saveFocusSuggestionPreferences(
    FocusSuggestionPreferences next,
  ) async {
    if (_focusSuggestionSaving) return false;
    _focusSuggestionSaving = true;
    try {
      await _focusSuggestionStore.save(next);
      if (!mounted) return false;
      _changeWorkspaceView(() => _focusSuggestionPreferences = next);
      return true;
    } on Object {
      if (mounted) _inform('Focus suggestions could not be saved.');
      return false;
    } finally {
      _focusSuggestionSaving = false;
    }
  }

  Widget? _focusSuggestionAction() {
    _focusSuggestionBoundary?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_focusSuggestionPreferences.enabled ||
        _destination != _Destination.today ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return null;
    }
    final now = DateTime.now();
    final candidates = _focusSuggestionEvents(now);
    var boundary = DateTime(now.year, now.month, now.day + 1);
    for (final event in candidates) {
      final change = now.isBefore(event.start) ? event.start : event.end;
      if (now.isBefore(change) && change.isBefore(boundary)) boundary = change;
    }
    _focusSuggestionBoundary = Timer(
      boundary.difference(now),
      _changeWorkspaceView,
    );
    final suggestion = _activeFocusSuggestion(now, candidates);
    if (suggestion == null) return null;
    return FocusSuggestionAction(
      suggestion: suggestion,
      onAccept: () => _actOnFocusSuggestion(suggestion, switchMode: true),
      onDismiss: () => _actOnFocusSuggestion(suggestion, switchMode: false),
    );
  }

  FocusSuggestion? _activeFocusSuggestion(
    DateTime now,
    List<FocusSuggestionEvent> candidates,
  ) {
    bool activityInProgress;
    try {
      activityInProgress = _activityData().active != null;
    } on Object {
      return null;
    }
    return suggestFocusMode(
      preferences: _focusSuggestionPreferences,
      modes: _availableModes,
      events: candidates,
      now: now,
      memberships: _calendarPreferences?.memberships,
      currentModeId: _space,
      activityInProgress: activityInProgress,
      workoutInProgress: _gymSessions?.lastOrNull?.finished == false,
      matchesLocalCategory: _modeIncludes,
    );
  }

  Future<void> _actOnFocusSuggestion(
    FocusSuggestion suggestion, {
    required bool switchMode,
  }) async {
    final now = DateTime.now();
    final current = _activeFocusSuggestion(now, _focusSuggestionEvents(now));
    if (current == null || !current.matches(suggestion)) {
      _changeWorkspaceView();
      return;
    }
    if (switchMode) _changeSpace(suggestion.mode.id);
    await _saveFocusSuggestionPreferences(
      _focusSuggestionPreferences.dismissing(suggestion),
    );
  }

  List<FocusSuggestionEvent> _focusSuggestionEvents(DateTime now) {
    final day = dateOnly(now);
    final appleAllowed =
        _allows(EasyFeature.externalCalendars) && _appleFeed.hasVerifiedAccess;
    final revision = (
      day,
      _data.events,
      _internalFeed.events,
      _icsFeed.events,
      appleAllowed ? _appleFeed.events : null,
      _calendarPreferences,
      _appleCopyRevision,
      _data.sections[_appleCopiesKey],
    );
    if (revision == _focusSuggestionSourceRevision) return _focusEvents;
    final tomorrow = DateTime(day.year, day.month, day.day + 1);
    bool relevant(DateTime start, DateTime end, bool allDay) =>
        !allDay &&
        end.isAfter(start) &&
        end.isAfter(day) &&
        start.isBefore(tomorrow);
    final local = [
      for (final event in _standaloneEvents(_data.events))
        if (event.blocksTime && relevant(event.start, event.end, event.allDay))
          event,
      for (final row in _internalFeed.events)
        if (row.event.blocksTime &&
            relevant(row.event.start, row.event.end, row.event.allDay))
          row.event,
    ];
    final linked = <CalendarOccurrenceIdentity, CalendarEvent>{
      if (_data.sections[_appleCopiesKey] != null ||
          _unsavedAppleCopies.isNotEmpty)
        for (final event in local) ?_appleCopyFor(event.id): event,
    };
    _focusEvents = [
      for (final event in local)
        FocusSuggestionEvent.local(
          id: event.id,
          category: event.category,
          calendar: _localCalendar(event.category),
          start: event.start,
          end: event.end,
        ),
      if (appleAllowed && _appleFeed.problem == null)
        for (final row in _appleFeed.events)
          if (row.event.blocksTime &&
              row.event.status == CalendarEventStatus.confirmed &&
              !_sameAppleEvent(linked[row.id], row.event) &&
              relevant(row.event.start, row.event.end, row.event.allDay))
            FocusSuggestionEvent.sourced(
              id: row.id,
              start: row.event.start,
              end: row.event.end,
              accepted: true,
            ),
      if (_icsFeed.problem == null)
        for (final row in _icsFeed.events)
          if (row.event.blocksTime &&
              row.status == CalendarEventStatus.confirmed &&
              relevant(row.event.start, row.event.end, row.event.allDay))
            FocusSuggestionEvent.sourced(
              id: CalendarOccurrenceIdentity(
                calendar: row.calendar,
                eventId: row.event.id,
              ),
              start: row.event.start,
              end: row.event.end,
              accepted: true,
            ),
    ];
    _focusSuggestionSourceRevision = revision;
    return _focusEvents;
  }
}
