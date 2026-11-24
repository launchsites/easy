part of 'main.dart';

const _taskCaptureDefaultsKey = 'taskCaptureDefaults';
const _usualTaskDefaults = TaskCaptureDefaults(
  placement: TaskCapturePlacement.today,
);

extension _WorkspaceTaskActions on _WorkspaceState {
  TaskCaptureDefaults get _captureDefaults {
    final saved = _data.sections[_taskCaptureDefaultsKey];
    try {
      return saved is Map<String, Object?>
          ? TaskCaptureDefaults.fromJson(saved)
          : _usualTaskDefaults;
    } catch (_) {
      return _usualTaskDefaults;
    }
  }

  String? _defaultTaskCategory(TaskCaptureDefaults defaults) {
    final configured = defaults.categoryId;
    if (configured?.isEmpty == true) return '';
    final catalog = _catalog;
    final category = catalog.resolve(configured);
    return category != null && !category.archived
        ? category.id
        : _preferredFocusCategory;
  }

  String? _reviewDefaultCategory(CaptureProposal proposal) {
    final fallback = _catalog.resolve('personal')?.archived == true
        ? ''
        : 'personal';
    return switch (proposal.draft.kind) {
      CaptureIntentKind.task =>
        _defaultTaskCategory(_captureDefaults) ?? fallback,
      CaptureIntentKind.event => _preferredFocusCategory ?? fallback,
      CaptureIntentKind.note => _preferredFocusCategory,
      CaptureIntentKind.workout => 'gym',
      CaptureIntentKind.meal => 'health',
      CaptureIntentKind.completeTask => null,
    };
  }

  Future<void> _openTaskDefaults() async {
    final selected = await showTaskCaptureDefaultsEditor(
      context,
      defaults: _captureDefaults,
      categories: _catalog,
    );
    if (!mounted || selected == null) return;
    final previous = _data;
    try {
      await _commitReviewedData(
        previous,
        previous.withSection(_taskCaptureDefaultsKey, selected.toJson()),
      );
    } catch (_) {
      if (mounted) _inform('Task defaults could not be saved.');
    }
  }

  bool _canAddSubtask(Object? record) =>
      record is TaskItem &&
      !record.done &&
      !_taskFeed.ids.contains(record.id) &&
      _repeatingTask(record) == null;

  Future<void> _addSubtask(TaskItem parent) async {
    if (!_canAddSubtask(parent) || _reviewSaving) return;
    final editor = RecordEditor(
      date: _today,
      kind: RecordKind.task,
      initialCategory: _catalog.canonicalId(parent.category),
      initialTaskParentId: parent.id,
      taskItems: _data.tasks,
    );
    final result = await _showEditor(editor);
    if (!mounted || result is! TaskItem) return;
    _saveRecord(result);
  }

  Future<void> _breakDownTask(TaskItem parent) async {
    if (!_canAddSubtask(parent) || _reviewSaving) return;
    final review = proposeTaskBreakdown(parent, existingTasks: _data.tasks);
    final approved = await showTaskBreakdownReview(context, review: review);
    if (approved == null || !mounted) return;
    final previous = _data;
    final now = DateTime.now().microsecondsSinceEpoch;
    var ordinal = 0;
    final children = approved.createChildren(
      currentTasks: previous.tasks,
      nextId: () => 'subtask-$now-${ordinal++}',
    );
    if (children == null || _taskFeed.ids.contains(parent.id)) {
      _inform('The task changed. Open it again to review its steps.');
      return;
    }
    try {
      await _commitReviewedData(
        previous,
        previous.copyWith(tasks: [...previous.tasks, ...children]),
      );
      if (mounted) {
        _inform(
          children.length == 1
              ? 'Subtask added'
              : '${children.length} subtasks added',
        );
      }
    } catch (_) {
      if (mounted) _inform('The selected steps could not be saved.');
    }
  }
}
