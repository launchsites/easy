part of 'main.dart';

typedef _VerifyWeekInput = ({
  WeeklyPlanSelection selection,
  List<CalendarEvent> events,
  List<TaskItem> tasks,
  DateTime notBefore,
  SchedulingSettings? settings,
  Set<String>? categories,
});

List<ScheduledTask>? _verifyWorkspaceWeek(_VerifyWeekInput input) =>
    input.selection.verify(
      events: input.events,
      tasks: input.tasks,
      notBefore: input.notBefore,
      settings: input.settings,
      categories: input.categories,
    );

extension _WorkspacePlanner on _WorkspaceState {
  Future<void> _planWeek() async {
    if (_reviewSaving || _planningDay || !_allows(EasyFeature.planning)) return;
    _planningDay = true;
    try {
      final current = weeklyPlanStart(_today);
      final next = weeklyPlanEnd(current);
      final start = await showDialog<DateTime>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Plan week'),
          children: [
            for (final (title, first) in [
              ('This week', current),
              ('Next week', next),
            ])
              ListTile(
                title: Text(title),
                subtitle: Text(
                  '${MaterialLocalizations.of(context).formatShortDate(first)} – '
                  '${MaterialLocalizations.of(context).formatShortDate(plusDays(first, 6))}',
                ),
                onTap: () => Navigator.pop(context, first),
              ),
          ],
        ),
      );
      if (start != null && mounted) await _reviewAndSaveWeek(start);
    } finally {
      _planningDay = false;
    }
  }

  Future<void> _reviewAndSaveWeek(DateTime start) async {
    Future<List<CalendarEvent>?> appointments() => _planningCalendar(
      plusDays(start, 3),
      firstDay: start,
      lastDay: plusDays(start, 6),
    );

    final initial = await appointments();
    if (!mounted || initial == null) return;
    final scope = _focus;
    final SchedulingSettings? settings;
    try {
      settings = _planningPreferences(expandCategories: true);
    } catch (_) {
      _inform('Your scheduling settings could not be opened.');
      return;
    }
    final categories = _expandCategoryScope(scope);
    final proposed = await _showEditor(
      WeeklyPlanSheet(
        weekStart: start,
        events: [..._standaloneEvents(_data.events), ...initial],
        tasks: weeklyWorkspaceTasks(
          feed: _taskFeed,
          tasks: _data.tasks,
          weekStart: start,
        ),
        settings: settings,
        categories: categories,
      ),
    );
    if (!mounted || proposed is! WeeklyPlanSelection) return;
    final current = await appointments();
    if (!mounted || current == null) return;
    final before = _data;
    final calendarRevision = (
      _appleFeed.events,
      _icsFeed.events,
      _internalFeed.events,
    );
    final SchedulingSettings? currentSettings;
    try {
      currentSettings = _planningPreferences(expandCategories: true);
    } catch (_) {
      _inform('Your scheduling settings could not be opened.');
      return;
    }
    final verified = await compute(_verifyWorkspaceWeek, (
      selection: proposed,
      events: [..._standaloneEvents(before.events), ...current],
      tasks: weeklyWorkspaceTasks(
        feed: _taskFeed,
        tasks: before.tasks,
        weekStart: start,
      ),
      notBefore: DateTime.now(),
      settings: currentSettings,
      categories: _expandCategoryScope(_focus),
    ));
    if (!mounted) return;
    if (verified == null ||
        !identical(before, _data) ||
        scope != _focus ||
        calendarRevision !=
            (_appleFeed.events, _icsFeed.events, _internalFeed.events)) {
      _inform('The available time changed. Preview the week again.');
      return;
    }
    await _storeReviewedBlocks(before, verified);
  }

  Future<void> _storeReviewedBlocks(
    WorkspaceData previous,
    List<ScheduledTask> tasks,
  ) async {
    final now = DateTime.now();
    final operationId = 'schedule-${now.microsecondsSinceEpoch}';
    final additions = <CalendarEvent>[];
    DateTime? first;
    for (final entry in tasks) {
      for (final block in entry.blocks) {
        if (block.start.isBefore(now)) {
          _inform(
            'A proposed block has already started. Preview the plan again.',
          );
          return;
        }
        if (first == null || block.start.isBefore(first)) first = block.start;
        additions.add(
          CalendarEvent(
            id: '$operationId-${additions.length}',
            title: entry.task.title,
            start: block.start,
            end: block.end,
            category: entry.task.category,
            plannedTaskId: entry.task.id,
            initialPlannedStart: block.start,
            initialPlannedEnd: block.end,
          ),
        );
      }
    }
    if (first == null) return;
    try {
      await _commitReviewedData(
        previous,
        previous.copyWith(events: [...previous.events, ...additions]),
        operationId: operationId,
      );
    } catch (_) {
      if (mounted) _inform('The plan could not be saved. Preview it again.');
      return;
    }
    if (!mounted) return;
    _changeDate(first);
    _navigate(_Destination.calendar);
  }
}
