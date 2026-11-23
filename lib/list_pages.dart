import 'package:material_ui/material_ui.dart';

const _paper = Color(0xFFFAF9F6);
const _ink = Color(0xFF202521);
const _muted = Color(0xFF696E66);
const _line = Color(0xFFE9E8E1);
const _accent = Color(0xFF466955);
const _softAccent = Color(0xFFE9EFE8);

class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    required this.category,
    this.date,
    this.done = false,
  });

  final String id;
  final String title;
  final String category;
  final DateTime? date;
  final bool done;
}

class NoteItem {
  const NoteItem({
    required this.id,
    required this.title,
    required this.body,
    required this.updated,
  });

  final String id;
  final String title;
  final String body;
  final DateTime updated;
}

enum _TaskFilter {
  all('All'),
  open('Open'),
  completed('Completed');

  const _TaskFilter(this.label);

  final String label;
}

enum _TaskGroup {
  inbox('Inbox'),
  overdue('Overdue'),
  today('Today'),
  upcoming('Upcoming'),
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

  Map<_TaskGroup, List<TaskItem>> _groupedTasks() {
    final today = DateUtils.dateOnly(DateTime.now());
    final groups = <_TaskGroup, List<TaskItem>>{
      for (final group in _TaskGroup.values) group: [],
    };
    for (final task in widget.tasks) {
      if (_filter == _TaskFilter.open && task.done ||
          _filter == _TaskFilter.completed && !task.done) {
        continue;
      }
      final date = task.date == null
          ? null
          : DateUtils.dateOnly(task.date!.toLocal());
      final group = switch ((task.done, date)) {
        (true, _) => _TaskGroup.completed,
        (false, null) => _TaskGroup.inbox,
        (false, final date?) when date.isBefore(today) => _TaskGroup.overdue,
        (false, final date?) when date == today => _TaskGroup.today,
        _ => _TaskGroup.upcoming,
      };
      groups[group]!.add(task);
    }
    for (final group in [_TaskGroup.overdue, _TaskGroup.upcoming]) {
      groups[group]!.sort((a, b) => a.date!.compareTo(b.date!));
    }
    groups.removeWhere((_, entries) => entries.isEmpty);
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupedTasks();
    return _ListPageLayout(
      title: 'Tasks',
      scrollKey: const PageStorageKey('tasks-scroll'),
      actions: Wrap(
        spacing: 3,
        children: [
          for (final filter in _TaskFilter.values)
            Semantics(
              selected: _filter == filter,
              child: TextButton(
                onPressed: () => setState(() => _filter = filter),
                style: TextButton.styleFrom(
                  foregroundColor: _filter == filter ? _ink : _muted,
                  backgroundColor: _filter == filter ? _softAccent : null,
                  minimumSize: const Size(48, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
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
          const SliverToBoxAdapter(child: Divider(height: 1, color: _line)),
          const SliverToBoxAdapter(child: SizedBox(height: 9)),
          if (!wide)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 0, 3),
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
              final task = tasks[index];
              final row = _TaskRow(
                task: task,
                overdue: group == _TaskGroup.overdue,
                onToggle: () => widget.onToggle(task),
                onTap: () => widget.onTaskTap(task),
              );
              if (!wide) return row;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
                    child: index == 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
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
          const SliverToBoxAdapter(child: SizedBox(height: 17)),
        ],
      ],
    );
  }
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
            style: const TextStyle(
              color: _ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (wide)
          Text(
            '$count ${count == 1 ? 'task' : 'tasks'}',
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.overdue,
    required this.onToggle,
    required this.onTap,
  });

  final TaskItem task;
  final bool overdue;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final date = task.date?.toLocal();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: task.done
              ? 'Mark ${task.title} open'
              : 'Complete ${task.title}',
          child: Checkbox(
            value: task.done,
            semanticLabel: task.title,
            onChanged: (_) => onToggle(),
            activeColor: _accent,
            checkColor: Colors.white,
            side: const BorderSide(color: Color(0xFF858C81), width: 1.2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            visualDensity: VisualDensity.standard,
          ),
        ),
        Expanded(
          child: _ListHitTarget(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(1, 11, 10, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: TextStyle(
                      color: task.done ? _muted : _ink,
                      fontSize: 15,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (date != null || task.category.trim().isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 10,
                      runSpacing: 5,
                      children: [
                        if (date != null)
                          Text(
                            localizations.formatMediumDate(date),
                            style: TextStyle(
                              color: overdue ? const Color(0xFF9A4D3F) : _muted,
                              fontSize: 12,
                            ),
                          ),
                        if (task.category.trim().isNotEmpty)
                          _CategoryLabel(name: task.category.trim()),
                      ],
                    ),
                  ],
                ],
              ),
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
    final (dot, label) = switch (name.toLowerCase()) {
      'work' => (const Color(0xFF778794), 'Work'),
      'study' => (const Color(0xFF857BB0), 'Study'),
      'health' => (const Color(0xFF7D9B80), 'Health'),
      'fitness' => (const Color(0xFF7D9B80), 'Fitness'),
      'personal' => (const Color(0xFFB58C72), 'Personal'),
      _ => (const Color(0xFF939990), name),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(color: _muted, fontSize: 12),
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

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      _searchFocus.requestFocus();
    } else {
      _search.clear();
      _searchFocus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final notes =
        widget.notes
            .where(
              (note) =>
                  note.title.toLowerCase().contains(query) ||
                  note.body.toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) => b.updated.compareTo(a.updated));
    return _ListPageLayout(
      title: 'Notes',
      scrollKey: const PageStorageKey('notes-scroll'),
      inlineActions: true,
      actions: IconButton(
        tooltip: _searchOpen ? 'Close note search' : 'Search notes',
        onPressed: _toggleSearch,
        color: _muted,
        icon: Icon(_searchOpen ? Icons.close_rounded : Icons.search_rounded),
      ),
      slivers: (_) => [
        if (_searchOpen)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search notes',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  fillColor: _paper,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: _line),
                  ),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: Divider(height: 1, color: _line)),
        if (notes.isEmpty)
          SliverToBoxAdapter(
            child: _EmptyList(
              message: query.isEmpty ? 'No notes yet' : 'No matching notes',
            ),
          ),
        SliverList.builder(
          itemCount: notes.length,
          itemBuilder: (context, index) {
            final note = notes[index];
            return Column(
              children: [
                _NoteRow(note: note, onTap: () => widget.onNoteTap(note)),
                const Divider(height: 1, color: _line),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.onTap});

  final NoteItem note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final updated = MaterialLocalizations.of(context)
        .formatMediumDate(note.updated.toLocal());
    final preview = note.body.trim().replaceAll(RegExp(r'\s+'), ' ');
    return _ListHitTarget(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.description_outlined,
                size: 19,
                color: _accent.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title.isEmpty ? 'Untitled note' : note.title,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 16,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Text(
                    updated,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.chevron_right_rounded, color: _muted, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListHitTarget extends StatelessWidget {
  const _ListHitTarget({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: _paper,
        focusColor: _softAccent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: child,
        ),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(message, style: const TextStyle(color: _muted, fontSize: 15)),
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
    final horizontal = mobile ? 24.0 : 44.0;
    final bottom = mobile ? 104 + MediaQuery.paddingOf(context).bottom : 44.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 650 &&
            MediaQuery.textScalerOf(context).scale(16) < 24;
        final header = Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              color: _ink,
              fontSize: mobile ? 32 : 36,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
              height: 1.15,
            ),
          ),
        );
        final head = wide || inlineActions
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
                children: [header, const SizedBox(height: 11), actions],
              );
        return CustomScrollView(
          key: scrollKey,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontal,
                mobile ? 24 : 42,
                horizontal,
                19,
              ),
              sliver: SliverToBoxAdapter(child: head),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontal),
              sliver: SliverMainAxisGroup(slivers: slivers(wide)),
            ),
            SliverToBoxAdapter(child: SizedBox(height: bottom)),
          ],
        );
      },
    );
  }
}
