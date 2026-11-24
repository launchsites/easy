part of 'main.dart';

const _workspaceSetupKey = 'workspaceSetup';
const _workspaceSetupPending = 'pending';

extension _WorkspaceOnboarding on _WorkspaceState {
  bool get _requiresWorkspaceSetup =>
      _data.sections[_workspaceSetupKey] == _workspaceSetupPending &&
      _data.events.isEmpty &&
      _data.tasks.isEmpty &&
      _data.notes.isEmpty &&
      _data.captures.isEmpty &&
      (_gymSessions?.isEmpty ?? false) &&
      (_workoutPlans?.isEmpty ?? false);

  Future<void> _finishWorkspaceSetup(WorkspaceSetupChoice choice) async {
    if (!_requiresWorkspaceSetup)
      throw StateError('The workspace has already been set up.');
    final original = _data;
    final today = _today;
    final samples = choice.content == WorkspaceStartingContent.samples
        ? WorkspaceData.samples(today)
        : null;
    final features = choice.preferences;
    final modes = choice.focusModes;
    final started = original.copyWith(
      events: samples?.events,
      tasks: samples?.tasks,
      notes: samples?.notes,
      sections: {
        ...original.sections,
        _workspaceSetupKey: 'complete',
        _featuresKey: features.toJson(),
        _focusProfilesKey: [for (final mode in modes) mode.toJson()],
      },
    );
    final workouts = samples != null && features.allows(EasyFeature.workouts)
        ? [_sampleWorkoutPlan(today)]
        : null;
    await _commitReviewedData(
      original,
      started,
      plans: workouts,
      operationId: 'initial-workspace-v1',
    );
    if (!mounted) return;
    _enableWorkspaceAfterSetup(features, modes);
  }

  void _enableWorkspaceAfterSetup(
    FeaturePreferences features,
    List<FocusMode> modes,
  ) {
    // The same committed page transition opens all elected modules together.
    setState(() {
      _features.value = features;
      _modes = modes;
    });
    _refreshCalendarViews();
    if (!kIsWeb &&
        identical(widget.openStore, openWorkspaceStore) &&
        features.allows(EasyFeature.ai)) {
      unawaited(_prepareAi());
    }
  }
}
