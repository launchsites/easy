import '../task_model.dart';

final class TaskBreakdownProposal {
  const TaskBreakdownProposal._(this.title, this.sourceText);

  final String title;
  final String sourceText;
}

final class TaskBreakdownReview {
  TaskBreakdownReview._(
    this._parent,
    List<TaskBreakdownProposal> proposals,
    Set<String> existing,
  ) : proposals = List.unmodifiable(proposals),
      _existing = Set.unmodifiable(existing);

  final TaskItem _parent;
  final List<TaskBreakdownProposal> proposals;
  final Set<String> _existing;

  String get parentId => _parent.id;
  String get parentTitle => _parent.title;

  /// Keys are reviewed proposal indices. Values may be edited by the user.
  TaskBreakdownApproval? approve(Map<int, String> selected) {
    if (selected.isEmpty ||
        selected.keys.any((index) => index < 0 || index >= proposals.length)) {
      return null;
    }
    final seen = {..._existing, _titleKey(parentTitle)};
    final titles = <String>[];
    for (final index in selected.keys.toList()..sort()) {
      final title = selected[index]!.trim();
      if (!validBreakdownTitle(title) || !seen.add(_titleKey(title))) {
        return null;
      }
      titles.add(title);
    }
    return TaskBreakdownApproval._(_parent, titles);
  }
}

final class TaskBreakdownApproval {
  TaskBreakdownApproval._(this._parent, Iterable<String> titles)
    : titles = List.unmodifiable(titles);

  final TaskItem _parent;
  final List<String> titles;

  String get parentId => _parent.id;

  /// Resolve against the complete current task list before committing together.
  List<TaskItem>? createChildren({
    required Iterable<TaskItem> currentTasks,
    required String Function() nextId,
  }) {
    final tasks = currentTasks.toList();
    final parents = tasks.where((task) => task.id == parentId);
    if (parents.length != 1) return null;
    final parent = parents.single;
    if (parent.done ||
        parent.title != _parent.title ||
        parent.category != _parent.category ||
        parent.parentId != _parent.parentId) {
      return null;
    }
    final seen = _childTitles(tasks, parentId);
    if (titles.any((title) => seen.contains(_titleKey(title)))) return null;
    final hierarchy = TaskHierarchy(tasks);
    final ids = tasks.map((task) => task.id).toSet();
    final children = <TaskItem>[];
    for (final title in titles) {
      final id = nextId();
      if (id.trim().isEmpty ||
          !ids.add(id) ||
          hierarchy.parentIssue(id, parentId) != null) {
        return null;
      }
      children.add(
        TaskItem(
          id: id,
          title: title,
          category: parent.category,
          parentId: parentId,
        ),
      );
    }
    return List.unmodifiable(children);
  }
}

TaskBreakdownReview proposeTaskBreakdown(
  TaskItem parent, {
  Iterable<TaskItem> existingTasks = const [],
}) {
  final existing = _childTitles(existingTasks, parent.id);
  final seen = {...existing, _titleKey(parent.title)};
  final pieces = parent.done ? const <String>[] : _explicitSteps(parent.title);
  var target = pieces.isEmpty ? null : _directObject(pieces.first);
  final proposals = <TaskBreakdownProposal>[];
  for (final (index, source) in pieces.indexed) {
    final text = index == 0 || target == null
        ? source
        : _replaceIt(source, target);
    final title = _sentenceCase(text).replaceFirst(_terminalPunctuation, '');
    if (validBreakdownTitle(title) && seen.add(_titleKey(title))) {
      proposals.add(TaskBreakdownProposal._(title, source));
    }
    if (index > 0 && _objectSource.hasMatch(source)) target = null;
  }
  return TaskBreakdownReview._(parent, proposals, existing);
}

const maxBreakdownTitleLength = 300;

bool validBreakdownTitle(String title) {
  final text = title.trim();
  return text.isNotEmpty &&
      text.runes.length <= maxBreakdownTitleLength &&
      !_invalidTitle.hasMatch(text);
}

const _verbs =
    'add|apply|assemble|book|build|buy|call|check|clean|collect|compare|compile|'
    'complete|confirm|contact|copy|create|deliver|design|discuss|do|download|'
    'draft|edit|email|file|fill|finish|fix|gather|install|invite|make|measure|'
    'order|organize|organise|pack|pay|plan|prepare|print|publish|record|remove|'
    'replace|research|return|review|run|save|schedule|send|share|sign|submit|'
    'test|track|update|upload|verify|wash|write';
final _action = RegExp('^(?:$_verbs)\\b', caseSensitive: false);
final _negative = RegExp(
  r'^(?:do\s+not|don[’\x27]t|never|avoid)\b',
  caseSensitive: false,
);
final _separator = RegExp(
  '(?:[;\\n]\\s*|,\\s*(?:(?:and\\s+)?then\\s+|and\\s+)?|'
  '\\s+(?:(?:and\\s+)?then|and|/)\\s+)(?=(?:$_verbs)\\b)',
  caseSensitive: false,
);
final _objectSource = RegExp(
  r'^(?:assemble|build|create|design|draft|make|prepare|record|write)\s+(.+?)(?=\s+(?:for|using|with|by|before|after|at)\b|$)',
  caseSensitive: false,
);
final _objectTarget = RegExp(
  r'^(send|deliver|share|submit|publish|upload|review|edit|test)\s+it\b',
  caseSensitive: false,
);
final _article = RegExp(r'^(?:a|an)\s+', caseSensitive: false);
final _ambiguousObject = RegExp(
  r'[;,()"“”/]|\b(?:and|or|it|them)\b',
  caseSensitive: false,
);
final _terminalPunctuation = RegExp(r'[.;!]+$');
final _nominalJoin = RegExp(
  r'^(?:test results|design notes|draft documents|review notes|order details)\b',
  caseSensitive: false,
);
final _whitespace = RegExp(r'\s+');
final _invalidTitle = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]');

List<String> _explicitSteps(String title) {
  final text = title.trim();
  if (text.length > 1600 || !_hasActionBody(text)) {
    return const [];
  }
  final parts = <String>[];
  var start = 0;
  for (final split in _separator.allMatches(text)) {
    if (!_outsideGroups(text, split.start)) continue;
    if (split[0]!.trim().toLowerCase() == 'and' &&
        _nominalJoin.hasMatch(text.substring(split.end))) {
      continue;
    }
    parts.add(text.substring(start, split.start).trim());
    start = split.end;
  }
  if (parts.isEmpty) return const [];
  parts.add(text.substring(start).trim());
  if (!parts.every(_hasActionBody)) return const [];
  return parts;
}

bool _hasActionBody(String text) {
  final action = _action.firstMatch(text);
  return action != null &&
      !_negative.hasMatch(text) &&
      text.substring(action.end).trim().isNotEmpty;
}

bool _outsideGroups(String source, int offset) {
  String? quote;
  var depth = 0;
  for (var index = 0; index < offset; index++) {
    final character = source[index];
    if (quote != null) {
      if (character == r'\') {
        index++;
      } else if (character == quote) {
        quote = null;
      }
      continue;
    }
    switch (character) {
      case '“':
        quote = '”';
      case '‘':
        quote = '’';
      case '"':
        quote = '"';
      case "'" when index == 0 || ' \t\n([{'.contains(source[index - 1]):
        quote = "'";
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}' when depth > 0:
        depth--;
    }
  }
  return quote == null && depth == 0;
}

String? _directObject(String source) {
  final match = _objectSource.firstMatch(source);
  final object = match?[1]?.trim();
  if (object == null ||
      object.isEmpty ||
      object.length > 80 ||
      _ambiguousObject.hasMatch(object)) {
    return null;
  }
  return object
      .replaceFirst(_terminalPunctuation, '')
      .replaceFirst(_article, 'the ');
}

String _replaceIt(String title, String object) {
  final match = _objectTarget.firstMatch(title);
  return match == null
      ? title
      : '${match[1]} $object${title.substring(match.end)}';
}

String _sentenceCase(String text) {
  if (text.isEmpty) return text;
  final first = String.fromCharCode(text.runes.first);
  return '${first.toUpperCase()}${text.substring(first.length)}';
}

Set<String> _childTitles(Iterable<TaskItem> tasks, String parentId) => {
  for (final task in tasks)
    if (task.parentId == parentId) _titleKey(task.title),
};

String _titleKey(String title) => title
    .trim()
    .replaceFirst(_terminalPunctuation, '')
    .replaceAll(_whitespace, ' ')
    .toLowerCase();
