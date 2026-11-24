import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show listEquals;

import 'notes/note_model.dart';
import 'task_model.dart';
import 'ui_theme.dart';
import 'workspace_data.dart' show spaceColor, spaceName;

export 'notes/note_model.dart';
export 'task_model.dart';

const _softSurface = Color(0xFFF1F0E9);
const _overdueInk = Color(0xFF954A3D);

enum _TaskFilter {
  all('All'),
  open('Open'),
  completed('Completed');

  const _TaskFilter(this.label);

  final String label;
}

enum _TaskGroup {
  overdue('Overdue'),
  today('Today'),
  upcoming('Upcoming'),
  inbox('Inbox'),
  completed('Completed');

  const _TaskGroup(this.label);

  final String label;
}

class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.tasks,
    required this.onToggle,
    required this.onTaskTap,
    super.key,
  });

  final List<TaskItem> tasks;
  final ValueChanged<TaskItem> onToggle;
  final ValueChanged<TaskItem> onTaskTap;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  _TaskFilter _filter = _TaskFilter.all;
  final _collapsed = <String>{};

  Map<_TaskGroup, List<_TaskListRow>> _groupedTasks(DateTime today) {
    final groups = <_TaskGroup, List<TaskItem>>{
      for (final group in _TaskGroup.values) group: [],
    };
    final visible = {
      for (final task in widget.tasks)
        if (_filter == _TaskFilter.all ||
            (task.done
                ? _filter == _TaskFilter.completed
                : _filter == _TaskFilter.open))
          task.id: task,
    };
    final hierarchy = TaskHierarchy(visible.values);
    final children = <String, List<TaskItem>>{};
    for (final task in visible.values) {
      if (hierarchy.visibleParentOf(task) case final parent?) {
        (children[parent] ??= []).add(task);
      } else {
        groups[_groupFor(task, today)]!.add(task);
      }
    }
    for (final group in [_TaskGroup.overdue, _TaskGroup.upcoming]) {
      groups[group]!.sort(
        (a, b) => (a.dueAt ?? a.date!).compareTo(b.dueAt ?? b.date!),
      );
    }

    Iterable<_TaskListRow> rows(TaskItem task, int depth) sync* {
      final subtasks = children[task.id] ?? const <TaskItem>[];
      yield (task: task, depth: depth, childCount: subtasks.length);
      if (_collapsed.contains(task.id)) return;
      for (final child in subtasks) {
        yield* rows(child, depth + 1);
      }
    }

    return {
      for (final group in groups.entries)
        if (group.value.isNotEmpty)
          group.key: [for (final task in group.value) ...rows(task, 0)],
    };
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final groups = _groupedTasks(today);
    final labels = Theme.of(context).textTheme.labelLarge;
    return _ListPageLayout(
      title: 'Tasks',
      scrollKey: const PageStorageKey('tasks-scroll'),
      actions: Wrap(
        spacing: 4,
        children: [
          for (final filter in _TaskFilter.values)
            Semantics(
              selected: _filter == filter,
              child: TextButton(
                onPressed: () => setState(() => _filter = filter),
                style: TextButton.styleFrom(
                  foregroundColor: _filter == filter ? ink : muted,
                  backgroundColor: _filter == filter ? _softSurface : null,
                  minimumSize: const Size(48, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  side: _filter == filter
                      ? const BorderSide(color: line)
                      : BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  textStyle: labels?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(filter.label),
              ),
            ),
        ],
      ),
      slivers: (wide) => [
        if (groups.isEmpty)
          SliverToBoxAdapter(
            child: _EmptyList(
              message: switch (_filter) {
                _TaskFilter.all => 'No tasks yet',
                _TaskFilter.open => 'No open tasks',
                _TaskFilter.completed => 'No completed tasks yet',
              },
            ),
          ),
        for (final MapEntry(key: group, value: tasks) in groups.entries) ...[
          const SliverToBoxAdapter(child: Divider(height: 1, color: line)),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (!wide)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 5, 0, 6),
                child: _GroupLabel(
                  group: group,
                  count: tasks.length,
                  wide: false,
                ),
              ),
            ),
          SliverList.builder(
            itemCount: tasks.length,
            itemBuilder: (context, index) {
              final rowData = tasks[index];
              final task = rowData.task;
              final expanded = !_collapsed.contains(task.id);
              final row = _TaskRow(
                key: ValueKey(task.id),
                task: task,
                group: _groupFor(task, today),
                depth: rowData.depth,
                indentation: wide
                    ? rowData.depth * 16.0
                    : rowData.depth.clamp(0, 4) * 12.0,
                childCount: rowData.childCount,
                expanded: expanded,
                onDisclosure: () => setState(() {
                  if (expanded) {
                    _collapsed.add(task.id);
                  } else {
                    _collapsed.remove(task.id);
                  }
                }),
                onToggle: () => widget.onToggle(task),
                onTap: () => widget.onTaskTap(task),
              );
              if (!wide) return row;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 154,
                    child: index == 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 14, right: 16),
                            child: _GroupLabel(
                              group: group,
                              count: tasks.length,
                              wide: true,
                            ),
                          )
                        : null,
                  ),
                  Expanded(child: row),
                ],
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 21)),
        ],
      ],
    );
  }
}

typedef _TaskListRow = ({TaskItem task, int depth, int childCount});

_TaskGroup _groupFor(TaskItem task, DateTime today) {
  final date = (task.dueAt ?? task.date)?.toLocal();
  return switch ((task.done, date)) {
    (true, _) => _TaskGroup.completed,
    (false, null) => _TaskGroup.inbox,
    (false, final date?) when date.isBefore(today) => _TaskGroup.overdue,
    (false, final date?) when DateUtils.isSameDay(date, today) =>
      _TaskGroup.today,
    _ => _TaskGroup.upcoming,
  };
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({
    required this.group,
    required this.count,
    required this.wide,
  });

  final _TaskGroup group;
  final int count;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      direction: wide ? Axis.vertical : Axis.horizontal,
      spacing: wide ? 4 : 8,
      children: [
        Semantics(
          header: true,
          child: Text(
            group.label,
            style: TextStyle(
              color: group == _TaskGroup.overdue ? _overdueInk : ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.25,
            ),
          ),
        ),
        if (wide)
          Text(
            '$count ${count == 1 ? 'task' : 'tasks'}',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.group,
    required this.depth,
    required this.indentation,
    required this.childCount,
    required this.expanded,
    required this.onDisclosure,
    required this.onToggle,
    required this.onTap,
    super.key,
  });

  final TaskItem task;
  final _TaskGroup group;
  final int depth;
  final double indentation;
  final int childCount;
  final bool expanded;
  final VoidCallback onDisclosure;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final dueAt = task.dueAt?.toLocal();
    final date = depth == 0 && group == _TaskGroup.today
        ? null
        : dueAt ?? task.date?.toLocal();
    final dueTime = dueAt == null
        ? null
        : localizations.formatTimeOfDay(
            TimeOfDay.fromDateTime(dueAt),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    final dueLabel = [
      if (date != null)
        (date.year == DateTime.now().year
            ? localizations.formatMediumDate(date)
            : localizations.formatShortDate(date)),
      if (dueTime != null) (date == null ? 'Due $dueTime' : dueTime),
    ].join(' · ');
    final category = task.category.trim();
    final estimate = task.estimatedMinutes;
    final priority = task.priority;
    final showEstimate = estimate != null && estimate > 0;
    final showSubtasks = childCount > 0 && !expanded;
    const metadata = TextStyle(color: muted, fontSize: 12, height: 1.25);
    return Row(
      children: [
        if (indentation > 0) SizedBox(width: indentation),
        Tooltip(
          message: task.done
              ? 'Reopen ${task.title}'
              : 'Complete ${task.title}',
          child: Checkbox(
            value: task.done,
            semanticLabel: depth > 0 ? 'Subtask: ${task.title}' : task.title,
            onChanged: (_) => onToggle(),
            activeColor: accent,
            checkColor: Colors.white,
            side: const BorderSide(color: Color(0xFF899083), width: 1.35),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            visualDensity: VisualDensity.standard,
          ),
        ),
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(9),
              hoverColor: _softSurface,
              focusColor: softAccent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 58),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 9, 10, 9),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          color: task.done ? muted : ink,
                          fontSize: 16,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          decoration: task.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (dueLabel.isNotEmpty ||
                          category.isNotEmpty ||
                          showEstimate ||
                          priority != null ||
                          showSubtasks) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 13,
                          runSpacing: 5,
                          children: [
                            if (category.isNotEmpty)
                              _CategoryLabel(name: category),
                            if (dueLabel.isNotEmpty)
                              Text(
                                dueLabel,
                                style: group == _TaskGroup.overdue
                                    ? metadata.copyWith(color: _overdueInk)
                                    : metadata,
                              ),
                            if (showEstimate)
                              Text(
                                '$estimate min',
                                semanticsLabel: 'Estimated $estimate minutes',
                                style: metadata,
                              ),
                            if (priority != null)
                              Text(
                                '${priority.label} priority',
                                style: metadata,
                              ),
                            if (showSubtasks)
                              Text(
                                '$childCount ${childCount == 1 ? 'subtask' : 'subtasks'}',
                                style: metadata,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (childCount > 0)
          Semantics(
            expanded: expanded,
            child: IconButton(
              tooltip: '${expanded ? 'Collapse' : 'Expand'} ${task.title}',
              onPressed: onDisclosure,
              icon: Icon(
                expanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                color: muted,
              ),
            ),
          ),
      ],
    );
  }
}

class _CategoryLabel extends StatelessWidget {
  const _CategoryLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: spaceColor(name),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            spaceName(name),
            style: const TextStyle(color: muted, fontSize: 12, height: 1.25),
          ),
        ),
      ],
    );
  }
}

class NotesPage extends StatefulWidget {
  const NotesPage({required this.notes, required this.onNoteTap, super.key});

  final List<NoteItem> notes;
  final ValueChanged<NoteItem> onNoteTap;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  _NoteFilters _filters = const _NoteFilters();
  late List<NoteItem> _ordered;
  late List<NoteItem> _matching;
  late List<String> _folders;
  late List<String> _tags;
  late bool _hasPinned;

  @override
  void initState() {
    super.initState();
    _indexNotes();
  }

  @override
  void didUpdateWidget(covariant NotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.notes, oldWidget.notes)) _indexNotes();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _search.clear();
        _refreshMatches();
      }
    });
    if (_searchOpen) {
      _searchFocus.requestFocus();
    } else {
      _searchFocus.unfocus();
    }
  }

  void _indexNotes() {
    _ordered = [...widget.notes]
      ..sort((first, second) {
        final pinOrder = (second.pinned ? 1 : 0) - (first.pinned ? 1 : 0);
        return pinOrder != 0
            ? pinOrder
            : second.updated.compareTo(first.updated);
      });
    _folders = _filterChoices(_ordered.map((note) => note.folder).nonNulls);
    _tags = _filterChoices(_ordered.expand((note) => note.tags));
    _hasPinned = _ordered.any((note) => note.pinned);
    final current = _filters;
    _filters = _NoteFilters(
      pinned: current.pinned && _hasPinned,
      folder: _folders.contains(current.folder) ? current.folder : null,
      tag: _tags.contains(current.tag) ? current.tag : null,
    );
    _refreshMatches();
  }

  List<String> _filterChoices(Iterable<String> values) =>
      [
        ...{
          for (final value in values)
            if (value.trim().isNotEmpty) value.toLowerCase(): value,
        }.values,
      ]..sort(
        (first, second) => first.toLowerCase().compareTo(second.toLowerCase()),
      );

  void _refreshMatches() {
    final query = _search.text.trim().toLowerCase();
    final folder = _filters.folder?.toLowerCase();
    final tag = _filters.tag?.toLowerCase();
    if (query.isEmpty && !_filters.active) {
      _matching = _ordered;
      return;
    }
    _matching = [
      for (final note in _ordered)
        if ((!_filters.pinned || note.pinned) &&
            (folder == null || note.folder?.toLowerCase() == folder) &&
            (tag == null ||
                note.tags.any((value) => value.toLowerCase() == tag)) &&
            (query.isEmpty ||
                note.title.toLowerCase().contains(query) ||
                note.body.toLowerCase().contains(query) ||
                (note.folder?.toLowerCase().contains(query) ?? false) ||
                note.tags.any((value) => value.toLowerCase().contains(query))))
          note,
    ];
  }

  Future<void> _changeFilters() async {
    final selected = await showDialog<_NoteFilters>(
      context: context,
      builder: (context) => _NoteFilterDialog(
        initial: _filters,
        folders: _folders,
        tags: _tags,
        hasPinned: _hasPinned,
      ),
    );
    if (mounted && selected != null) {
      setState(() {
        _filters = selected;
        _refreshMatches();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filters.active || _search.text.trim().isNotEmpty;
    final notes = _matching;
    return _ListPageLayout(
      title: 'Notes',
      scrollKey: const PageStorageKey('notes-scroll'),
      inlineActions: true,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_folders.isNotEmpty || _tags.isNotEmpty || _hasPinned) ...[
            IconButton.outlined(
              tooltip: _filters.active ? 'Filters applied' : 'Filter notes',
              onPressed: _changeFilters,
              isSelected: _filters.active,
              style: IconButton.styleFrom(
                foregroundColor: ink,
                backgroundColor: _filters.active ? softAccent : raisedPaper,
                side: const BorderSide(color: line),
              ),
              icon: const Icon(Icons.filter_list_rounded, size: 20),
            ),
            const SizedBox(width: 5),
          ],
          IconButton.outlined(
            tooltip: _searchOpen ? 'Close note search' : 'Search notes',
            onPressed: _toggleSearch,
            style: IconButton.styleFrom(
              foregroundColor: ink,
              backgroundColor: _searchOpen ? softAccent : raisedPaper,
              side: const BorderSide(color: line),
            ),
            icon: Icon(
              _searchOpen ? Icons.close_rounded : Icons.search_rounded,
              size: 20,
            ),
          ),
        ],
      ),
      slivers: (_) => [
        if (_searchOpen)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: (_) => setState(_refreshMatches),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search notes',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  fillColor: raisedPaper,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: line),
                  ),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: Divider(height: 1, color: line)),
        if (notes.isEmpty)
          SliverToBoxAdapter(
            child: _EmptyList(
              message: filtered ? 'No matching notes' : 'No notes yet',
            ),
          ),
        SliverList.separated(
          itemCount: notes.length,
          separatorBuilder: (_, _) => const Divider(height: 1, color: line),
          itemBuilder: (context, index) {
            final note = notes[index];
            return _NoteRow(
              key: ValueKey(note.id),
              note: note,
              onTap: () => widget.onNoteTap(note),
            );
          },
        ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.onTap, super.key});

  final NoteItem note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final updated = MaterialLocalizations.of(context)
        .formatShortDate(note.updated.toLocal());
    final body = note.body.trimLeft();
    final firstBreak = body.indexOf('\n');
    final preview = (firstBreak == -1 ? body : body.substring(0, firstBreak))
        .trimRight();
    final title = note.title.trim();
    const metadata = TextStyle(color: muted, fontSize: 13, height: 1.3);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        hoverColor: _softSurface,
        focusColor: softAccent,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(5, 10, 7, 10),
          child: Row(
            children: [
              Icon(
                note.pinned
                    ? Icons.push_pin_outlined
                    : Icons.description_outlined,
                size: 20,
                color: accent,
                semanticLabel: note.pinned ? 'Pinned' : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? 'Untitled note' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: updated,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          if (note.folder case final folder?
                              when folder.isNotEmpty)
                            TextSpan(text: '  ·  $folder'),
                          if (preview.isNotEmpty)
                            TextSpan(text: '  ·  $preview'),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metadata,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoteFilters {
  const _NoteFilters({this.pinned = false, this.folder, this.tag});

  final bool pinned;
  final String? folder;
  final String? tag;

  bool get active => pinned || folder != null || tag != null;
}

class _NoteFilterDialog extends StatefulWidget {
  const _NoteFilterDialog({
    required this.initial,
    required this.folders,
    required this.tags,
    required this.hasPinned,
  });

  final _NoteFilters initial;
  final List<String> folders;
  final List<String> tags;
  final bool hasPinned;

  @override
  State<_NoteFilterDialog> createState() => _NoteFilterDialogState();
}

class _NoteFilterDialogState extends State<_NoteFilterDialog> {
  late bool _pinned = widget.initial.pinned;
  late String? _folder = widget.initial.folder;
  late String? _tag = widget.initial.tag;

  Widget _selection({
    required String title,
    required String allLabel,
    required String? initial,
    required List<String> options,
    required ValueChanged<String?> change,
  }) => DropdownButtonFormField<String>(
    initialValue: initial,
    decoration: InputDecoration(labelText: title),
    hint: Text(allLabel),
    isExpanded: true,
    items: [
      DropdownMenuItem(child: Text(allLabel)),
      for (final option in options)
        DropdownMenuItem(
          value: option,
          child: Text(option, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: change,
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Filter notes'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.hasPinned)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pinned only'),
            value: _pinned,
            onChanged: (value) => setState(() => _pinned = value),
          ),
        if (widget.folders.isNotEmpty)
          _selection(
            title: 'Folder',
            allLabel: 'All folders',
            initial: _folder,
            options: widget.folders,
            change: (value) => setState(() => _folder = value),
          ),
        if (widget.tags.isNotEmpty)
          _selection(
            title: 'Tag',
            allLabel: 'All tags',
            initial: _tag,
            options: widget.tags,
            change: (value) => setState(() => _tag = value),
          ),
      ],
    ),
    actions: [
      if (widget.initial.active || _pinned || _folder != null || _tag != null)
        TextButton(
          onPressed: () => Navigator.pop(context, const _NoteFilters()),
          child: const Text('Clear filters'),
        ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _NoteFilters(pinned: _pinned, folder: _folder, tag: _tag),
        ),
        child: const Text('Apply'),
      ),
    ],
  );
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(message, style: const TextStyle(color: muted, fontSize: 15)),
    );
  }
}

class _ListPageLayout extends StatelessWidget {
  const _ListPageLayout({
    required this.title,
    required this.scrollKey,
    required this.actions,
    required this.slivers,
    this.inlineActions = false,
  });

  final String title;
  final PageStorageKey<String> scrollKey;
  final Widget actions;
  final List<Widget> Function(bool wide) slivers;
  final bool inlineActions;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final horizontal = mobile ? 28.0 : 48.0;
    final bottom = mobile ? 104 + MediaQuery.paddingOf(context).bottom : 44.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - horizontal * 2;
        final endInset =
            horizontal + (availableWidth - 1030).clamp(0.0, double.infinity);
        final wide =
            availableWidth >= 625 &&
            MediaQuery.textScalerOf(context).scale(16) < 24;
        final shortLandscape =
            !inlineActions &&
            mobile &&
            constraints.maxHeight < 355 &&
            availableWidth >= 440 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18;
        final titleStyle = workspaceHeadingStyle(mobile);
        final header = Semantics(
          header: true,
          child: Text(
            title,
            style: shortLandscape
                ? titleStyle.copyWith(fontSize: 36, letterSpacing: -1.8)
                : titleStyle,
          ),
        );
        final head = wide || inlineActions || shortLandscape
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: header),
                  const SizedBox(width: 16),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [header, const SizedBox(height: 18), actions],
              );
        return CustomScrollView(
          key: scrollKey,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: EdgeInsetsDirectional.fromSTEB(
                horizontal,
                shortLandscape ? 12 : (mobile ? 25 : 42),
                endInset,
                shortLandscape ? 13 : (mobile ? 20 : 26),
              ),
              sliver: SliverToBoxAdapter(child: head),
            ),
            SliverPadding(
              padding: EdgeInsetsDirectional.only(
                start: horizontal,
                end: endInset,
              ),
              sliver: SliverMainAxisGroup(slivers: slivers(wide)),
            ),
            SliverToBoxAdapter(child: SizedBox(height: bottom)),
          ],
        );
      },
    );
  }
}
