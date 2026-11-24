import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'orbit_navigation.dart';
import 'record_editor.dart';
import 'today_page.dart';
import 'workspace_data.dart';

const appName = String.fromEnvironment('APP_NAME', defaultValue: 'Easy');

void main() => runApp(const EasyApp());

class EasyApp extends StatelessWidget {
  const EasyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: easyTheme(),
      home: const _Workspace(),
    );
  }
}

enum _Destination {
  today('Today', Icons.wb_sunny_outlined),
  calendar('Calendar', Icons.calendar_today_outlined),
  tasks('Tasks', Icons.check_box_outlined),
  notes('Notes', Icons.notes_rounded);

  const _Destination(this.label, this.icon);

  final String label;
  final IconData icon;
}

const _storageKey = 'easy.workspace.v1';

class _Workspace extends StatefulWidget {
  const _Workspace();

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  final _storage = SharedPreferencesAsync();
  Future<void> _pendingSave = Future.value();
  late WorkspaceData _data;
  var _calendarDate = dateOnly(DateTime.now());
  DateTime get _today => dateOnly(DateTime.now());
  var _destination = _Destination.today;
  String? _space;
  Object? _inspected;
  var _loading = true;
  var _loadFailed = false;
  final _pageStorage = PageStorageBucket();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final raw = await _storage.getString(_storageKey);
      final data = raw == null
          ? WorkspaceData.samples(_today)
          : WorkspaceData.decode(raw);
      if (raw == null) await _storage.setString(_storageKey, data.encode());
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  void _update(WorkspaceData data) {
    setState(() => _data = data);
    final snapshot = data.encode();
    _pendingSave = _pendingSave.then((_) async {
      try {
        await _storage.setString(_storageKey, snapshot);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Changes could not be saved on this device.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _update(_data),
            ),
          ),
        );
      }
    });
  }

  void _navigate(_Destination destination) {
    setState(() {
      _destination = destination;
      _inspected = null;
    });
  }

  void _changeDate(DateTime date) {
    final day = dateOnly(date);
    if (day != _calendarDate) setState(() => _calendarDate = day);
  }

  void _changeSpace(String? space) {
    setState(() {
      _space = space;
      _inspected = null;
    });
  }

  void _toggleTask(TaskItem task) {
    final done = !task.done;
    _setTaskDone(task.id, done);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done ? 'Task completed' : 'Task reopened'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _setTaskDone(task.id, task.done),
        ),
      ),
    );
  }

  void _setTaskDone(String id, bool done) {
    final task = _data.tasks.where((task) => task.id == id).firstOrNull;
    if (task == null || task.done == done) return;
    _saveRecord(
      TaskItem(
        id: task.id,
        title: task.title,
        category: task.category,
        date: task.date,
        done: done,
      ),
    );
  }

  List<T> _upsert<T>(List<T> records, T updated, String Function(T) id) => [
    for (final existing in records)
      if (id(existing) == id(updated)) updated else existing,
    if (!records.any((existing) => id(existing) == id(updated))) updated,
  ];

  void _saveRecord(Object record) {
    final data = switch (record) {
      CalendarEvent event => WorkspaceData(
        events: _upsert(_data.events, event, (value) => value.id),
        tasks: _data.tasks,
        notes: _data.notes,
      ),
      TaskItem task => WorkspaceData(
        events: _data.events,
        tasks: _upsert(_data.tasks, task, (value) => value.id),
        notes: _data.notes,
      ),
      NoteItem note => WorkspaceData(
        events: _data.events,
        tasks: _data.tasks,
        notes: _upsert(_data.notes, note, (value) => value.id),
      ),
      _ => _data,
    };
    if (_inspected != null && _recordId(_inspected!) == _recordId(record)) {
      _inspected = record;
    }
    _update(data);
  }

  Future<void> _deleteRecord(Object record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_recordKind(record).name}?'),
        content: Text(_recordTitle(record)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_inspected == record) _inspected = null;
    final id = _recordId(record);
    _update(
      WorkspaceData(
        events: _data.events.where((record) => record.id != id).toList(),
        tasks: _data.tasks.where((record) => record.id != id).toList(),
        notes: _data.notes.where((record) => record.id != id).toList(),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${spaceName(_recordKind(record).name)} deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _saveRecord(record),
        ),
      ),
    );
  }

  Future<void> _editRecord([Object? existing]) async {
    final kind = existing == null
        ? switch (_destination) {
            _Destination.calendar => RecordKind.event,
            _Destination.notes => RecordKind.note,
            _ => RecordKind.task,
          }
        : _recordKind(existing);
    final editor = RecordEditor(
      date: _destination == _Destination.calendar ? _calendarDate : _today,
      kind: kind,
      initialTaskDate: _destination == _Destination.today ? _today : null,
      initialCategory: _space,
      event: existing is CalendarEvent ? existing : null,
      task: existing is TaskItem ? existing : null,
      note: existing is NoteItem ? existing : null,
    );
    final result = MediaQuery.sizeOf(context).width < 720
        ? await showModalBottomSheet<Object>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            backgroundColor: paper,
            builder: (_) => editor,
          )
        : await showDialog<Object>(
            context: context,
            builder: (_) => Dialog(backgroundColor: paper, child: editor),
          );
    if (result != null && mounted) _saveRecord(result);
  }

  Future<void> _openRecord(Object record) async {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => _inspected = record);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: paper,
      showDragHandle: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .68,
        ),
        child: _RecordDetails(
          record: record,
          onEdit: () => Navigator.pop(context, 'edit'),
          onDelete: () => Navigator.pop(context, 'delete'),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') await _editRecord(record);
    if (action == 'delete') await _deleteRecord(record);
  }

  Future<void> _search() async {
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _SearchDialog(
        records: [..._data.events, ..._data.tasks, ..._data.notes],
      ),
    );
    if (result == null || !mounted) return;
    _navigate(switch (result) {
      CalendarEvent() => _Destination.calendar,
      TaskItem() => _Destination.tasks,
      _ => _Destination.notes,
    });
    _changeSpace(null);
    if (result is CalendarEvent) _changeDate(result.start);
    await _openRecord(result);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(
          child: _loadFailed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Your workspace could not be opened.'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Retry'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < 720;
    final compact = width < 900;
    final space = _space;
    final events = space == null
        ? _data.events
        : _data.events
              .where((item) => item.category.toLowerCase() == space)
              .toList();
    final tasks = space == null
        ? _data.tasks
        : _data.tasks
              .where((item) => item.category.toLowerCase() == space)
              .toList();
    final page = PageStorage(
      bucket: _pageStorage,
      child: IndexedStack(
        index: _destination.index,
        sizing: StackFit.expand,
        children: [
          TodayPage(
            date: _today,
            events: events,
            tasks: tasks,
            onEventTap: _openRecord,
            onTaskTap: _openRecord,
            onTaskToggle: _toggleTask,
          ),
          CalendarPage(
            date: _calendarDate,
            events: events,
            onDateChanged: _changeDate,
            onEventTap: _openRecord,
          ),
          TasksPage(
            tasks: tasks,
            onToggle: _toggleTask,
            onTaskTap: _openRecord,
          ),
          NotesPage(notes: _data.notes, onNoteTap: _openRecord),
        ],
      ),
    );
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
    };
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: mobile ? paper : shell,
          body: SafeArea(
            bottom: !mobile,
            child: mobile
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Column(
                        children: [
                          if (_destination != _Destination.calendar ||
                              space != null)
                            _MobileHeader(
                              space: space,
                              displayBrand:
                                  _destination != _Destination.calendar,
                              onSpaceChanged: _changeSpace,
                              onSearch: _search,
                            ),
                          Expanded(child: page),
                        ],
                      ),
                      Positioned(
                        right: 20,
                        bottom: MediaQuery.paddingOf(context).bottom + 20,
                        child: FloatingActionButton(
                          heroTag: 'capture',
                          tooltip: 'Add item',
                          onPressed: _editRecord,
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          shape: const CircleBorder(),
                          elevation: 3,
                          highlightElevation: 1,
                          hoverElevation: 5,
                          child: const Icon(Icons.add_rounded, size: 27),
                        ),
                      ),
                      Positioned.fill(
                        child: OrbitNavigation(
                          destinations: [
                            for (final destination in _Destination.values)
                              OrbitDestination(
                                destination.label,
                                destination.icon,
                              ),
                          ],
                          selectedIndex: _destination.index,
                          onSelected: (index) =>
                              _navigate(_Destination.values[index]),
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      _DesktopHeader(onSearch: _search, onCapture: _editRecord),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 14, 14),
                          child: Row(
                            children: [
                              _Sidebar(
                                destination: _destination,
                                compact: compact,
                                space: space,
                                onNavigate: _navigate,
                                onSpaceChanged: _changeSpace,
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: _Surface(child: page)),
                              if (_inspected != null && width >= 1000) ...[
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: width >= 1250 ? 294 : 264,
                                  child: _Surface(
                                    child: _RecordDetails(
                                      record: _inspected!,
                                      onClose: () =>
                                          setState(() => _inspected = null),
                                      onEdit: () => _editRecord(_inspected),
                                      onDelete: () =>
                                          _deleteRecord(_inspected!),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: paper,
      borderRadius: BorderRadius.circular(19),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? const Color(0xffdcead9) : accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wb_twilight_outlined, size: 23, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              letterSpacing: -.7,
              color: dark ? const Color(0xfff5f7f1) : ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopHeader extends StatelessWidget {
  const _DesktopHeader({required this.onSearch, required this.onCapture});

  final VoidCallback onSearch;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final shortcut = Theme.of(context).platform == TargetPlatform.macOS
        ? '⌘ K'
        : 'Ctrl K';
    return SizedBox(
      height: 70,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        child: Row(
          children: [
            const Expanded(child: _Brand(dark: true)),
            Expanded(
              flex: 2,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 370),
                  child: Material(
                    color: shellSurface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Color(0xff343d34)),
                    ),
                    child: InkWell(
                      onTap: onSearch,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: sidebarText,
                            ),
                            const SizedBox(width: 9),
                            const Expanded(
                              child: Text(
                                'Search workspace',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: sidebarText,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: const Color(0xff3d473c),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                child: Text(
                                  shortcut,
                                  style: const TextStyle(
                                    color: sidebarText,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onCapture,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffe3ebdf),
                    foregroundColor: const Color(0xff283d31),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 17,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.space,
    required this.displayBrand,
    required this.onSpaceChanged,
    required this.onSearch,
  });

  final String? space;
  final bool displayBrand;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: displayBrand
                ? const _Brand(dark: false)
                : const SizedBox.shrink(),
          ),
          MenuAnchor(
            builder: (context, controller, _) => TextButton.icon(
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: Icon(
                Icons.expand_more_rounded,
                size: 17,
                color: space == null ? muted : spaceColor(space!),
              ),
              iconAlignment: IconAlignment.end,
              label: Text(
                space == null ? 'All spaces' : spaceName(space!),
                overflow: TextOverflow.ellipsis,
              ),
              style: TextButton.styleFrom(
                foregroundColor: space == null ? muted : spaceColor(space!),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            menuChildren: [
              MenuItemButton(
                onPressed: () => onSpaceChanged(null),
                child: const Text('All spaces'),
              ),
              for (final category in spaceColors.keys)
                MenuItemButton(
                  onPressed: () => onSpaceChanged(category),
                  child: Text(spaceName(category)),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Search workspace',
            onPressed: onSearch,
            icon: const Icon(Icons.search_rounded, size: 21),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destination,
    required this.compact,
    required this.space,
    required this.onNavigate,
    required this.onSpaceChanged,
  });

  final _Destination destination;
  final bool compact;
  final String? space;
  final ValueChanged<_Destination> onNavigate;
  final ValueChanged<String?> onSpaceChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 54 : 206,
      child: ListView(
        padding: EdgeInsets.only(
          left: compact ? 0 : 2,
          top: 9,
          right: compact ? 0 : 8,
        ),
        children: [
          for (final item in _Destination.values)
            _SidebarButton(
              label: item.label,
              icon: item.icon,
              color: sidebarText,
              selected: item == destination,
              compact: compact,
              onTap: () => onNavigate(item),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 12,
              19,
              compact ? 4 : 10,
              16,
            ),
            child: const Divider(color: Color(0xff323b33)),
          ),
          if (!compact)
            const Padding(
              padding: EdgeInsets.fromLTRB(13, 4, 0, 8),
              child: Text(
                'Spaces',
                style: TextStyle(
                  color: Color(0xffa7b0a4),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          _SidebarButton(
            label: 'All spaces',
            icon: Icons.grid_view_rounded,
            color: sidebarText,
            selected: space == null,
            compact: compact,
            onTap: () => onSpaceChanged(null),
          ),
          for (final category in spaceColors.keys)
            _SidebarButton(
              label: spaceName(category),
              icon: Icons.circle,
              color: Color.lerp(spaceColor(category), sidebarText, .43)!,
              selected: space == category,
              compact: compact,
              onTap: () => onSpaceChanged(category),
            ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: compact ? label : null,
      selected: selected,
      button: true,
      child: Tooltip(
        message: compact ? label : '',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Material(
            color: selected ? const Color(0xff2a342b) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 0 : 12,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Icon(
                        icon,
                        size: icon == Icons.circle ? 8 : 18,
                        color: selected && icon != Icons.circle
                            ? const Color(0xffd0dfd1)
                            : color,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xfff0f5ec)
                                : sidebarText,
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _recordId(Object record) => switch (record) {
  CalendarEvent() => record.id,
  TaskItem() => record.id,
  NoteItem() => record.id,
  _ => throw ArgumentError.value(record),
};

String _recordTitle(Object record) => switch (record) {
  CalendarEvent() => record.title,
  TaskItem() => record.title,
  NoteItem() => record.title,
  _ => throw ArgumentError.value(record),
};

RecordKind _recordKind(Object record) => switch (record) {
  CalendarEvent() => RecordKind.event,
  TaskItem() => RecordKind.task,
  NoteItem() => RecordKind.note,
  _ => throw ArgumentError.value(record),
};

class _RecordDetails extends StatelessWidget {
  const _RecordDetails({
    required this.record,
    required this.onEdit,
    required this.onDelete,
    this.onClose,
  });

  final Object record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final item = record;
    final localizations = MaterialLocalizations.of(context);
    String day(DateTime date) => localizations.formatFullDate(date);
    String time(DateTime date) =>
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));
    final rows = switch (item) {
      CalendarEvent() => [
        (Icons.calendar_today_outlined, day(item.start)),
        if (item.allDay)
          (Icons.schedule_outlined, 'All day')
        else
          (
            Icons.schedule_outlined,
            sameDay(item.start, item.end)
                ? '${time(item.start)} – ${time(item.end)}'
                : '${time(item.start)} – ${day(item.end)}, ${time(item.end)}',
          ),
        if (item.location?.isNotEmpty ?? false)
          (Icons.place_outlined, item.location!),
        (Icons.circle_outlined, spaceName(item.category)),
      ],
      TaskItem() => [
        (Icons.check_box_outlined, item.done ? 'Completed' : 'Open'),
        if (item.date != null) (Icons.calendar_today_outlined, day(item.date!)),
        (Icons.circle_outlined, spaceName(item.category)),
      ],
      NoteItem() => [
        (
          Icons.schedule_outlined,
          'Edited ${localizations.formatMediumDate(item.updated)}',
        ),
      ],
      _ => <(IconData, String)>[],
    };
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(25, onClose == null ? 11 : 22, 25, 27),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _recordTitle(record),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.8,
                      height: 1.15,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: 'Close details',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            for (final (icon, label) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(icon, color: muted, size: 17),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            if (item is NoteItem && item.body.trim().isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 14),
              SelectableText(
                item.body,
                style: const TextStyle(height: 1.6, fontSize: 14),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: onEdit,
                  child: const Text('Edit'),
                ),
                TextButton(
                  onPressed: onDelete,
                  style: TextButton.styleFrom(foregroundColor: muted),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.records});

  final List<Object> records;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final results = widget.records
        .where(
          (record) =>
              _recordTitle(record)
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase()),
        )
        .take(30)
        .toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: (_) {
                  if (results.isNotEmpty) Navigator.pop(context, results.first);
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Search workspace',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            Flexible(
              child: results.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No matching items.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final kind = _recordKind(result);
                        return ListTile(
                          leading: Icon(switch (kind) {
                            RecordKind.event => Icons.calendar_today_outlined,
                            RecordKind.task => Icons.check_box_outlined,
                            RecordKind.note => Icons.notes_rounded,
                          }),
                          title: Text(_recordTitle(result)),
                          subtitle: Text(spaceName(kind.name)),
                          onTap: () => Navigator.pop(context, result),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
