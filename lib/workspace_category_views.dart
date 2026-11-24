part of 'main.dart';

const _categorySettingsKey = 'categories';

extension _WorkspaceCategoryViews on _WorkspaceState {
  WorkspaceCategories get _catalog {
    final raw = _data.sections[_categorySettingsKey];
    final revision = (raw, _data.tasks, _data.events, _data.notes, _modes);
    if (_categoryRevision == revision) return _categoryCache;

    final legacy = <String>{
      for (final task in _data.tasks) task.category,
      for (final event in _data.events) event.category,
      for (final note in _data.notes) ?note.category,
      for (final mode in _modes) ...?mode.categories,
      for (final mode in _modes) ?mode.preferredCategory,
    };
    _categoryRevision = revision;
    if (identical(_categorySource, raw) &&
        setEquals(legacy, _categoryReferences)) {
      return _categoryCache;
    }
    _categorySource = raw;
    _categoryReferences = legacy;
    try {
      _categoryCache = raw is Map<String, Object?>
          ? WorkspaceCategories.fromJson(raw, legacyIds: legacy)
          : WorkspaceCategories.defaults(legacyIds: legacy);
    } on FormatException {
      _categoryCache = WorkspaceCategories.defaults(legacyIds: legacy);
    }
    return _categoryCache;
  }

  Map<String, String> _categories({bool includeArchived = false}) =>
      _catalog.labels(includeArchived: includeArchived);

  Widget _categoryScope(Widget child) =>
      WorkspaceCategoryPalette(categories: _catalog, child: child);

  String? get _preferredFocusCategory {
    final reference = _focus?.preferredCategory;
    final category = _catalog.resolve(reference);
    return category?.archived == true ? null : category?.id ?? reference;
  }

  bool _modeIncludes(FocusMode? mode, String? category) {
    final selected = mode?.categories;
    return selected == null || _catalog.matches(category, selected);
  }

  Set<String>? _expandCategoryScope(FocusMode? mode) {
    final selected = mode?.categories;
    if (selected == null) return null;
    final catalog = _catalog;
    final roots = selected.map(catalog.canonicalId).nonNulls.toSet();
    final categories = {...roots};
    for (final entry in catalog.categories) {
      if (catalog
          .pathFor(entry.id)
          .any((parent) => roots.contains(parent.id))) {
        categories.add(entry.id);
      }
    }
    // Existing records can retain older references.
    return {
      ...categories,
      for (final reference in _categoryReferences)
        if (categories.contains(catalog.canonicalId(reference))) reference,
    };
  }

  List<TaskItem> _tasksInMode(FocusMode? mode) {
    final all = _workspaceTasks;
    if (mode?.categories == null) return all;
    final catalog = _catalog;
    final revision = (all, mode, catalog);
    if (revision != _focusedTasksRevision) {
      final scope = _expandCategoryScope(mode)!;
      _focusedTasks = [
        for (final task in all)
          if (scope.contains(catalog.canonicalId(task.category))) task,
      ];
      _focusedTasksRevision = revision;
    }
    return _focusedTasks;
  }

  List<NoteItem> _notesInMode(FocusMode? mode) {
    if (mode?.categories == null) return _data.notes;
    final catalog = _catalog;
    final revision = (_data.notes, mode, catalog);
    if (revision != _focusedNotesRevision) {
      final scope = _expandCategoryScope(mode)!;
      _focusedNotes = [
        for (final note in _data.notes)
          if (scope.contains(catalog.canonicalId(note.category))) note,
      ];
      _focusedNotesRevision = revision;
    }
    return _focusedNotes;
  }

  void _openCategories() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => WorkspaceCategoriesPage(
        categories: _catalog,
        onChanged: _updateCategories,
      ),
    ),
  );

  void _updateCategories(WorkspaceCategories changed) {
    final previous = _catalog;
    var updated = _data.withSection(_categorySettingsKey, changed.toJson());
    final newCategories = changed.categories.where(
      (entry) => !entry.archived && previous.resolve(entry.id) == null,
    );
    if (_calendarPreferences case final current?
        when newCategories.isNotEmpty) {
      final next = CalendarSourcePreferences(
        allCalendars: {
          ...current.allCalendars,
          for (final entry in newCategories) _localCalendar(entry.id),
        },
        defaultWriteCalendar: current.defaultWriteCalendar,
        memberships: CalendarModeMemberships({
          for (final mode in _modes)
            mode.id: {
              ...current.calendarsFor(mode.id),
              for (final entry in newCategories)
                if (mode.categories == null ||
                    changed.matches(entry.id, mode.categories!))
                  _localCalendar(entry.id),
            },
        }),
      );
      _calendarPreferences = next;
      updated = updated.withSection(_calendarPreferencesKey, next.toJson());
    }
    _update(updated);
  }
}
