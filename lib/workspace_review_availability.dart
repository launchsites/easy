part of 'main.dart';

typedef _ReviewAvailabilityInput = ({
  DateTime day,
  SchedulingSettings settings,
  Set<String> categories,
  List<CalendarEvent> events,
});

ReviewDayAvailability? _projectReviewAvailability(
  _ReviewAvailabilityInput input,
) => deriveReviewDayAvailability(
  day: input.day,
  settings: input.settings,
  categories: input.categories,
  events: input.events,
  calendarComplete: true,
);

extension _WorkspaceReviewAvailability on _WorkspaceState {
  Object get _reviewAvailabilityRevision => (
    _data.events,
    _data.sections[_scheduleSettingsKey],
    _data.sections[_categorySettingsKey],
    _data.sections[_calendarPreferencesKey],
    _data.sections[_recurringEventsKey],
    _calendarPreferences,
    _eventSeries,
    _icsCalendars,
    _features.value,
  );

  Future<ReviewDayAvailability?> _reviewAvailabilityFor(DateTime day) async {
    if (!_allows(EasyFeature.planning) ||
        !identical(_data, _savedWorkspace) ||
        !_calendarSourcesReadable ||
        _selectedAppleCalendars.isNotEmpty ||
        _selectedIcsCalendars.isNotEmpty ||
        _eventSeries.isNotEmpty) {
      return null;
    }
    final source = _reviewAvailabilityRevision;
    if (_reviewAvailabilityKey != source) {
      _reviewAvailabilityKey = source;
      _reviewAvailabilityCache.clear();
    }
    final localDay = dateOnly(day);
    final Future<ReviewDayAvailability?> pending;
    if (_reviewAvailabilityCache[localDay] case final cached?) {
      pending = cached;
    } else {
      try {
        final settings = _planningPreferences(expandCategories: true);
        if (settings == null || settings.availability.isEmpty) return null;
        final input = (
          day: localDay,
          settings: settings,
          categories: _categories().keys.toSet(),
          events: _data.events,
        );
        pending = input.events.length >= 1000
            ? compute(_projectReviewAvailability, input)
            : Future.sync(() => _projectReviewAvailability(input));
      } on Object {
        return null;
      }
      if (_reviewAvailabilityCache.length >= 14) {
        _reviewAvailabilityCache.remove(_reviewAvailabilityCache.keys.first);
      }
      _reviewAvailabilityCache[localDay] = pending;
    }
    try {
      final result = await pending;
      return mounted &&
              source == _reviewAvailabilityRevision &&
              identical(_data, _savedWorkspace)
          ? result
          : null;
    } on Object {
      return null;
    }
  }
}
