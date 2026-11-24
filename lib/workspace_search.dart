part of 'main.dart';

const _searchPreferencesKey = 'easy.search.v1';

extension _WorkspaceSearch on _WorkspaceState {
  Future<SearchPreferences> _readSearchPreferences() async {
    try {
      final value = await _legacyPreferences.getString(_searchPreferencesKey);
      if (value != null) {
        return SearchPreferences.fromJson(
          jsonDecode(value) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Local search remains available with fresh preferences.
    }
    return SearchPreferences();
  }

  void _saveSearchPreferences(SearchPreferences preferences) {
    _searchPreferences = Future.value(preferences);
    final encoded = jsonEncode(preferences.toJson());
    _searchPreferenceWrites = _searchPreferenceWrites.then((_) async {
      try {
        await _legacyPreferences.setString(_searchPreferencesKey, encoded);
      } catch (_) {
        // Preference storage does not block opening a recent result.
      }
    });
  }

  Iterable<CalendarEvent> _searchableEvents() sync* {
    yield* _standaloneEvents(_data.events);
    for (final row in _internalFeed.events) {
      yield row.event;
    }
    final permitted = _selectedCalendars.toSet();
    for (final row in _icsFeed.events) {
      if (permitted.contains(row.calendar)) yield row.event;
    }
    if (_allows(EasyFeature.externalCalendars) &&
        _appleFeed.hasVerifiedAccess) {
      for (final entry in _appleFeed.events) {
        if (permitted.contains(entry.id.calendar)) yield _fromApple(entry);
      }
    }
  }

  List<ActivityRecord> _searchableActivities() {
    if (!_allows(EasyFeature.activity)) return const [];
    final source = _data.sections[_activitiesKey];
    if (identical(source, _searchActivitySource)) return _searchActivities;
    _searchActivitySource = source;
    try {
      _searchActivities = _activityData().records;
    } catch (_) {
      _searchActivities = const [];
    }
    return _searchActivities;
  }

  Future<SearchIndex> _workspaceSearchIndex() {
    final tasks = _workspaceTasks;
    final catalog = _catalog;
    final activities = _searchableActivities();
    final revision = (
      tasks,
      _data.events,
      _data.notes,
      _features.value,
      _calendarPreferences,
      _appleFeed.hasVerifiedAccess,
      _appleFeed.events,
      _icsFeed.events,
      _internalFeed.events,
      catalog,
      activities,
    );
    if (_searchIndex case final existing?
        when revision == _searchIndexRevision) {
      return existing;
    }
    _searchIndexRevision = revision;
    String? categoryName(String? category) =>
        category == null ? null : catalog.pathLabelFor(category);

    final documents = [
      for (final task in tasks)
        SearchDocument(
          key: SearchKey(SearchRecordKind.task, task.id),
          title: task.title,
          body: task.notes ?? '',
          categoryId: catalog.canonicalId(task.category),
          categoryName: categoryName(task.category),
          date: task.dueAt ?? task.date,
        ),
      for (final event in _searchableEvents())
        SearchDocument(
          key: SearchKey(SearchRecordKind.event, event.id),
          title: event.title,
          body: [event.location, event.description].nonNulls.join('\n'),
          categoryId: catalog.canonicalId(event.category),
          categoryName: event.sourceLabel ?? categoryName(event.category),
          date: event.start,
        ),
      for (final note in _data.notes)
        SearchDocument(
          key: SearchKey(SearchRecordKind.note, note.id),
          title: note.title,
          body: [note.body, ?note.folder, ...note.tags].join('\n'),
          categoryId: catalog.canonicalId(note.category),
          categoryName: categoryName(note.category),
          date: note.updated,
          pinned: note.pinned,
        ),
      for (final activity in activities)
        SearchDocument(
          key: SearchKey(SearchRecordKind.activity, activity.id),
          title: activity.title,
          body: [
            ?activity.target?.title,
            for (final step in activity.steps) step.title,
          ].join('\n'),
          categoryId: catalog.canonicalId(activity.category),
          categoryName: categoryName(activity.category),
          date: activity.time,
        ),
    ];
    return _searchIndex = buildSearchIndex(documents);
  }

  Future<void> _search() async {
    if (_searchOpen || _loading || _reviewSaving) return;
    _searchOpen = true;
    try {
      final preferences = await (_searchPreferences ??=
          _readSearchPreferences());
      if (!mounted || _reviewSaving) return;
      final found = await showDialog<SearchDocument>(
        context: context,
        builder: (_) => ListenableBuilder(
          listenable: _appleFeed,
          builder: (context, _) => WorkspaceSearchDialog(
            index: _workspaceSearchIndex(),
            preferences: preferences,
            onPreferencesChanged: _saveSearchPreferences,
          ),
        ),
      );
      if (found == null || !mounted || _reviewSaving) return;
      await _openSearchResult(found.key);
    } finally {
      _searchOpen = false;
    }
  }

  Future<void> _openSearchResult(SearchKey key) async {
    if (key.kind == SearchRecordKind.activity) {
      if (_searchableActivities().any((activity) => activity.id == key.id)) {
        _openActivities(initialRecordId: key.id);
      } else {
        _inform('This activity is no longer available.');
      }
      return;
    }
    final (record, destination) = switch (key.kind) {
      SearchRecordKind.task => (
        _workspaceTasks.where((task) => task.id == key.id).firstOrNull,
        _Destination.tasks,
      ),
      SearchRecordKind.event => (
        _searchableEvents().where((event) => event.id == key.id).firstOrNull,
        _Destination.calendar,
      ),
      SearchRecordKind.note => (
        _data.notes.where((note) => note.id == key.id).firstOrNull,
        _Destination.notes,
      ),
      _ => (null, _Destination.today),
    };
    if (record == null) {
      _inform('This result is no longer available.');
      return;
    }
    if (record is CalendarEvent) _changeDate(record.start);
    _navigate(destination);
    await _openRecord(record);
  }
}
