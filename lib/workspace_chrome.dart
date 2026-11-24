part of 'main.dart';

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
    required this.modes,
    required this.displayBrand,
    required this.onSpaceChanged,
    required this.onSearch,
    required this.onSettings,
  });

  final String? space;
  final List<FocusMode> modes;
  final bool displayBrand;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 146),
            child: _ModeControl(
              mode: space,
              modes: modes,
              onModeChanged: onSpaceChanged,
              onSettings: onSettings,
            ),
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

class _ModeControl extends StatelessWidget {
  const _ModeControl({
    required this.mode,
    required this.modes,
    required this.onModeChanged,
    required this.onSettings,
    this.showCurrentMode = true,
  });

  final String? mode;
  final List<FocusMode> modes;
  final ValueChanged<String?> onModeChanged;
  final VoidCallback onSettings;
  final bool showCurrentMode;

  @override
  Widget build(BuildContext context) {
    final current = mode;
    final profile = modes.where((item) => item.id == current).firstOrNull;
    final foreground = profile == null ? muted : Color(profile.color);
    return MenuAnchor(
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.expand_more_rounded, size: 17),
        iconAlignment: IconAlignment.end,
        label: Text(
          showCurrentMode && profile != null ? profile.name : 'Mode',
          overflow: TextOverflow.ellipsis,
        ),
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => onModeChanged(null),
          trailingIcon: current == null
              ? const Icon(Icons.check, size: 18)
              : null,
          child: const Text('No mode'),
        ),
        for (final mode in modes)
          MenuItemButton(
            onPressed: () => onModeChanged(mode.id),
            leadingIcon: Icon(Icons.circle, color: Color(mode.color), size: 8),
            trailingIcon: current == mode.id
                ? const Icon(Icons.check, size: 18)
                : null,
            child: Text(
              mode.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const Divider(),
        MenuItemButton(
          onPressed: onSettings,
          leadingIcon: const Icon(Icons.settings_outlined, size: 18),
          child: const Text('Settings'),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destination,
    required this.compact,
    required this.space,
    required this.modes,
    required this.onNavigate,
    required this.onSpaceChanged,
    required this.onSettings,
  });

  final _Destination destination;
  final bool compact;
  final String? space;
  final List<FocusMode> modes;
  final ValueChanged<_Destination> onNavigate;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSettings;

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
                'Focus modes',
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
          for (final mode in modes)
            _SidebarButton(
              label: mode.name,
              icon: Icons.circle,
              color: Color.lerp(Color(mode.color), sidebarText, .43)!,
              selected: space == mode.id,
              compact: compact,
              onTap: () => onSpaceChanged(mode.id),
            ),
          const SizedBox(height: 20),
          _SidebarButton(
            label: 'Settings',
            icon: Icons.settings_outlined,
            color: sidebarText,
            selected: false,
            compact: compact,
            onTap: onSettings,
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
    this.noteTargets = const [],
    this.onOpenNoteLink,
    this.onEstimate,
    this.onAppleCopy,
    this.onRepeat,
    this.repeatingTask = false,
    this.onAssignPlace,
    this.onAddSubtask,
    this.onBreakdown,
    this.onReminder,
    this.reminderSet = false,
    this.onSchedule,
  });

  final Object record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onClose;
  final List<NoteTarget> noteTargets;
  final ValueChanged<NoteLink>? onOpenNoteLink;
  final VoidCallback? onEstimate;
  final VoidCallback? onAppleCopy;
  final VoidCallback? onRepeat;
  final bool repeatingTask;
  final VoidCallback? onAssignPlace;
  final VoidCallback? onAddSubtask;
  final VoidCallback? onBreakdown;
  final VoidCallback? onReminder;
  final bool reminderSet;
  final VoidCallback? onSchedule;

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
        (
          Icons.circle_outlined,
          item.sourceLabel ??
              WorkspaceCategoryPalette.labelFor(context, item.category),
        ),
      ],
      TaskItem() => [
        (Icons.check_box_outlined, item.done ? 'Completed' : 'Open'),
        if (repeatingTask) (Icons.repeat_rounded, 'Repeating task'),
        if (item.date != null) (Icons.calendar_today_outlined, day(item.date!)),
        (
          Icons.circle_outlined,
          WorkspaceCategoryPalette.labelFor(context, item.category),
        ),
        if (item.estimatedMinutes case final minutes?)
          (Icons.timer_outlined, '$minutes min estimate'),
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
            if (item is NoteItem &&
                (item.body.trim().isNotEmpty || item.links.isNotEmpty)) ...[
              const Divider(),
              const SizedBox(height: 14),
              NotePreview(
                note: item,
                targets: noteTargets,
                onOpenLink: onOpenNoteLink,
              ),
            ],
            if (item case CalendarEvent(description: final description?)) ...[
              const Divider(),
              const SizedBox(height: 14),
              SelectableText(
                description,
                style: const TextStyle(height: 1.6, fontSize: 14),
              ),
            ],
            if (item is! CalendarEvent || !item.isReadOnly) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  if (item is! TaskItem || !repeatingTask || !item.done) ...[
                    FilledButton.tonal(
                      onPressed: onEdit,
                      child: Text(
                        item is CalendarEvent && item.plannedTaskId != null
                            ? 'Move block'
                            : 'Edit',
                      ),
                    ),
                    TextButton(
                      onPressed: onDelete,
                      style: TextButton.styleFrom(foregroundColor: muted),
                      child: Text(
                        repeatingTask ||
                                item is CalendarEvent &&
                                    item.recurringSeriesId != null
                            ? 'Skip'
                            : 'Delete',
                      ),
                    ),
                  ],
                  if (onEstimate != null)
                    TextButton(
                      onPressed: onEstimate,
                      child: const Text('Suggest duration'),
                    ),
                  if (onAppleCopy != null)
                    TextButton(
                      onPressed: onAppleCopy,
                      child: const Text('Copy to Apple Calendar'),
                    ),
                  if (onRepeat != null)
                    TextButton(
                      onPressed: onRepeat,
                      child: Text(
                        repeatingTask ||
                                item is CalendarEvent &&
                                    item.recurringSeriesId != null
                            ? 'Repeat rule'
                            : 'Repeat',
                      ),
                    ),
                  if (onAssignPlace != null)
                    TextButton(
                      onPressed: onAssignPlace,
                      child: const Text('Travel place'),
                    ),
                  if (onAddSubtask != null)
                    TextButton(
                      onPressed: onAddSubtask,
                      child: const Text('Add subtask'),
                    ),
                  if (onBreakdown != null)
                    TextButton(
                      onPressed: onBreakdown,
                      child: const Text('Break down'),
                    ),
                  if (onReminder != null)
                    TextButton(
                      onPressed: onReminder,
                      child: Text(
                        reminderSet ? 'Edit reminder' : 'Set reminder',
                      ),
                    ),
                  if (onSchedule != null)
                    TextButton(
                      onPressed: onSchedule,
                      child: const Text('Schedule'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
