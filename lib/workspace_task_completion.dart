part of 'main.dart';

const _taskCompletionFailure = 'Changes could not be saved on this device.';

extension _WorkspaceTaskCompletion on _WorkspaceState {
  Future<bool> _toggleTask(TaskItem task, {bool showFailure = true}) async {
    if (_reviewSaving) return false;
    if (_repeatingTask(task) case final row?) {
      return _toggleRepeatingTask(row, showFailure: showFailure);
    }
    final done = !task.done;
    final updated = await _commitTaskCompletion(
      task,
      done,
      completedAt: done ? DateTime.now().toUtc() : null,
      dispatch: done,
      showFailure: showFailure,
    );
    if (updated == null) return false;
    if (!mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done ? 'Task completed' : 'Task reopened'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _commitTaskCompletion(
            updated,
            task.done,
            completedAt: task.completedAt,
          ),
        ),
      ),
    );
    return true;
  }

  Future<TaskItem?> _commitTaskCompletion(
    TaskItem expected,
    bool done, {
    DateTime? completedAt,
    bool dispatch = false,
    bool showFailure = true,
  }) async {
    if (!mounted || _reviewSaving || expected.done == done) return null;
    final workspace = _data;
    final task = workspace.tasks
        .where((item) => item.id == expected.id)
        .firstOrNull;
    if (!identical(task, expected)) return null;
    final updated = expected.withDone(done, completedAt: completedAt);
    final replacement = workspace.copyWith(
      tasks: _upsert(workspace.tasks, updated, (item) => item.id),
    );
    try {
      await _commitReviewedData(
        workspace,
        dispatch
            ? _withAutomationEvents(replacement, [?automationForTask(updated)])
            : replacement,
      );
      return updated;
    } on WorkspaceRevisionConflict {
      if (mounted && showFailure) {
        _inform('This workspace changed in another window.');
      }
      return null;
    } on Object {
      if (mounted && showFailure) _inform(_taskCompletionFailure);
      return null;
    }
  }

  Future<void> _toggleTaskFromDetails(BuildContext sheet, TaskItem task) async {
    if (_reviewSaving) return;
    final saved = await _toggleTask(task, showFailure: false);
    if (!sheet.mounted) return;
    if (saved) {
      Navigator.pop(sheet);
      return;
    }
    await showDialog<void>(
      context: sheet,
      builder: (context) => AlertDialog(
        title: const Text('Task could not be saved'),
        content: const Text(_taskCompletionFailure),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
