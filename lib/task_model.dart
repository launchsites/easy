enum TaskPriority {
  low('Low'),
  normal('Normal'),
  high('High');

  const TaskPriority(this.label);

  final String label;
}

const defaultTaskChunkMinutes = 15;

class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    required this.category,
    this.date,
    this.done = false,
    this.estimatedMinutes,
    this.priority,
    this.parentId,
    this.notes,
    this.earliestStart,
    this.prerequisiteIds = const [],
    this.allowSplit = false,
    this.minimumChunkMinutes = defaultTaskChunkMinutes,
    this.dueAt,
  });

  final String id;
  final String title;
  final String category;
  final DateTime? date;
  final bool done;
  final int? estimatedMinutes;
  final TaskPriority? priority;
  final String? parentId;
  final String? notes;
  final DateTime? earliestStart;
  final List<String> prerequisiteIds;
  final bool allowSplit;
  final int minimumChunkMinutes;
  final DateTime? dueAt;

  TaskItem withDone(bool done) => _with(done: done, parentId: parentId);

  TaskItem withParent(String? parentId) =>
      _with(done: done, parentId: parentId);

  TaskItem withPrerequisites(List<String> ids) => _with(
    done: done,
    parentId: parentId,
    prerequisites: List.unmodifiable(ids),
  );

  TaskItem _with({
    required bool done,
    required String? parentId,
    List<String>? prerequisites,
  }) => TaskItem(
    id: id,
    title: title,
    category: category,
    date: date,
    done: done,
    estimatedMinutes: estimatedMinutes,
    priority: priority,
    parentId: parentId,
    notes: notes,
    earliestStart: earliestStart,
    prerequisiteIds: prerequisites ?? prerequisiteIds,
    allowSplit: allowSplit,
    minimumChunkMinutes: minimumChunkMinutes,
    dueAt: dueAt,
  );
}

String? taskSplitIssue({
  required bool allowSplit,
  required int? minimumChunkMinutes,
  required int? estimatedMinutes,
}) {
  if (!allowSplit) return null;
  if (minimumChunkMinutes == null || minimumChunkMinutes < 1) {
    return 'Enter a minimum block in whole minutes.';
  }
  if (estimatedMinutes != null && minimumChunkMinutes > estimatedMinutes) {
    return 'Minimum block cannot exceed the estimated duration.';
  }
  return null;
}

enum TaskPrerequisiteIssue {
  missing('A prerequisite task is unavailable.'),
  cycle('Prerequisites cannot make a task depend on itself.');

  const TaskPrerequisiteIssue(this.message);

  final String message;
}

TaskPrerequisiteIssue? taskPrerequisiteIssue(
  Iterable<TaskItem> tasks,
  String taskId,
  List<String> prerequisites,
) => prerequisites.isEmpty
    ? null
    : TaskDependencyGraph(tasks).prerequisiteIssue(taskId, prerequisites);

class TaskDependencyGraph {
  TaskDependencyGraph(Iterable<TaskItem> tasks)
    : _tasks = {for (final task in tasks) task.id: task};

  final Map<String, TaskItem> _tasks;

  Iterable<TaskItem> eligiblePrerequisites(String taskId) sync* {
    final dependants = <String, List<String>>{};
    for (final task in _tasks.values) {
      for (final prerequisite in task.prerequisiteIds) {
        (dependants[prerequisite] ??= []).add(task.id);
      }
    }
    final excluded = <String>{taskId};
    final pending = [taskId];
    while (pending.isNotEmpty) {
      for (final id in dependants[pending.removeLast()] ?? const <String>[]) {
        if (excluded.add(id)) pending.add(id);
      }
    }
    for (final task in _tasks.values) {
      if (!excluded.contains(task.id)) yield task;
    }
  }

  TaskPrerequisiteIssue? prerequisiteIssue(
    String taskId,
    List<String> prerequisites,
  ) {
    final visiting = <String>{taskId};
    final checked = <String>{};
    final stack = [(id: taskId, edges: prerequisites.iterator)];
    while (stack.isNotEmpty) {
      final frame = stack.last;
      if (!frame.edges.moveNext()) {
        visiting.remove(frame.id);
        checked.add(frame.id);
        stack.removeLast();
        continue;
      }

      final id = frame.edges.current;
      if (visiting.contains(id)) return TaskPrerequisiteIssue.cycle;
      if (checked.contains(id)) continue;
      final task = _tasks[id];
      if (task == null) return TaskPrerequisiteIssue.missing;
      visiting.add(id);
      stack.add((id: id, edges: task.prerequisiteIds.iterator));
    }
    return null;
  }
}

const maxTaskDepth = 8;

enum TaskParentIssue {
  missing('That parent task is unavailable.'),
  cycle('A task cannot be inside itself or one of its subtasks.'),
  tooDeep('Tasks can be nested up to $maxTaskDepth levels.');

  const TaskParentIssue(this.message);

  final String message;
}

TaskParentIssue? taskParentIssue(
  Iterable<TaskItem> tasks,
  String taskId,
  String? parentId,
) => parentId == null
    ? null
    : TaskHierarchy(tasks).parentIssue(taskId, parentId);

class TaskHierarchy {
  TaskHierarchy(Iterable<TaskItem> tasks)
    : _tasks = {for (final task in tasks) task.id: task} {
    for (final task in _tasks.values) {
      if (task.parentId case final parent?) {
        (_children[parent] ??= []).add(task);
      }
    }
  }

  final Map<String, TaskItem> _tasks;
  final _children = <String, List<TaskItem>>{};

  // A filtered view may omit an ancestor. Keep any visible, valid links.
  String? visibleParentOf(TaskItem task) {
    final parent = task.parentId;
    if (parent == null || !_tasks.containsKey(parent)) return null;
    final issue = _placementIssue(
      task.id,
      parent,
      subtreeDepth: 0,
      allowMissingAncestor: true,
    );
    return issue == null ? parent : null;
  }

  TaskParentIssue? parentIssue(String taskId, String? parentId) {
    if (parentId == null) return null;
    return _placementIssue(taskId, parentId, subtreeDepth: _depthBelow(taskId));
  }

  Iterable<TaskItem> eligibleParents(String taskId) sync* {
    final subtreeDepth = _depthBelow(taskId);
    for (final task in _tasks.values) {
      if (_placementIssue(taskId, task.id, subtreeDepth: subtreeDepth) ==
          null) {
        yield task;
      }
    }
  }

  TaskParentIssue? _placementIssue(
    String taskId,
    String parentId, {
    required int subtreeDepth,
    bool allowMissingAncestor = false,
  }) {
    final visited = <String>{taskId};
    String? current = parentId;
    var depth = subtreeDepth;
    while (current != null) {
      if (!visited.add(current)) return TaskParentIssue.cycle;
      final task = _tasks[current];
      if (task == null) {
        return allowMissingAncestor ? null : TaskParentIssue.missing;
      }
      if (++depth > maxTaskDepth) return TaskParentIssue.tooDeep;
      current = task.parentId;
    }
    return null;
  }

  int _depthBelow(String taskId) {
    final visited = <String>{taskId};
    final stack = [(id: taskId, depth: 0)];
    var deepest = 0;
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node.depth == maxTaskDepth) return maxTaskDepth;
      if (node.depth > deepest) deepest = node.depth;
      for (final child in _children[node.id] ?? const <TaskItem>[]) {
        if (visited.add(child.id)) {
          stack.add((id: child.id, depth: node.depth + 1));
        }
      }
    }
    return deepest;
  }
}
