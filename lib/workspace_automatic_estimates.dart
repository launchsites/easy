part of 'main.dart';

extension _WorkspaceAutomaticEstimates on _WorkspaceState {
  bool _idleForAutomaticEstimates(AiRuntime runtime) {
    if (!mounted ||
        _loading ||
        _reviewSaving ||
        _reviewingMealPhoto ||
        !identical(_ai, runtime) ||
        runtime.busy ||
        !_allows(EasyFeature.ai) ||
        !runtime.settings.automaticEstimates ||
        !identical(_savedWorkspace, _data) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        DateTime.now().difference(_lastWorkspaceInput) >=
            const Duration(seconds: 25);
  }

  Object get _estimateCandidateOrderKey => (_data.tasks, _taskFeed.ids);

  Future<List<TaskItem>?> _rankEstimateTasks(AiRuntime runtime) async {
    final key = _estimateCandidateOrderKey;
    if (_rankedEstimateKey == key) return _rankedEstimateTasks;
    if (_rankingEstimateTasks) return null;
    final tasks = _data.tasks;
    final recurring = _taskFeed.ids;
    bool stale() =>
        !_idleForAutomaticEstimates(runtime) ||
        _estimateCandidateOrderKey != key;
    _rankingEstimateTasks = true;
    try {
      final list = tasks.length <= 2048
          ? rankAutomaticEstimateTasks(tasks, recurringBaseIds: recurring)
          : await rankAutomaticEstimateTasksCooperatively(
              tasks,
              recurringBaseIds: recurring,
              shouldCancel: stale,
            );
      if (list == null || stale()) return null;
      _rankedEstimateKey = key;
      return _rankedEstimateTasks = list;
    } finally {
      _rankingEstimateTasks = false;
    }
  }
}
