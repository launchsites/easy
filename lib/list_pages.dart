import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';
import 'workspace_data.dart' show spaceColor, spaceName;

const _softSurface = Color(0xFFF1F0E9);
const _overdueInk = Color(0xFF954A3D);

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
    this.category,
    this.noteToSelf = false,
  });

  final String id;
  final String title;
  final String body;
  final DateTime updated;
  final String? category;
  final bool noteToSelf;
}

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
              final task = tasks[index];
              final row = _TaskRow(
                key: ValueKey(task.id),
                task: task,
                group: group,
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
    required this.onToggle,
    required this.onTap,
    super.key,
  });

  final TaskItem task;
  final _TaskGroup group;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final date = group == _TaskGroup.today ? null : task.date?.toLocal();
    final category = task.category.trim();
    return Row(
      children: [
        Tooltip(
          message: task.done
              ? 'Reopen ${task.title}'
              : 'Complete ${task.title}',
          child: Checkbox(
            value: task.done,
            semanticLabel: task.title,
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
                      if (date != null || category.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 13,
                          runSpacing: 5,
                          children: [
                            if (category.isNotEmpty)
                              _CategoryLabel(name: category),
                            if (date != null)
                              Text(
                                date.year == DateTime.now().year
                                    ? localizations.formatMediumDate(date)
                                    : localizations.formatShortDate(date),
                                style: TextStyle(
                                  color: group == _TaskGroup.overdue
                                      ? _overdueInk
                                      : muted,
                                  fontSize: 12,
                                  height: 1.25,
                                ),
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
      actions: IconButton.outlined(
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
      slivers: (_) => [
        if (_searchOpen)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: (_) => setState(() {}),
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
              message: query.isEmpty ? 'No notes yet' : 'No matching notes',
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
              const Icon(Icons.description_outlined, size: 20, color: accent),
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
        final header = Semantics(
          header: true,
          child: Text(title, style: workspaceHeadingStyle(mobile)),
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
                children: [header, const SizedBox(height: 18), actions],
              );
        return CustomScrollView(
          key: scrollKey,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: EdgeInsetsDirectional.fromSTEB(
                horizontal,
                mobile ? 25 : 42,
                endInset,
                mobile ? 20 : 26,
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
