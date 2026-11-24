import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'appearance/appearance.dart' show readableTint;
import 'calendar_page.dart';
import 'categories/category_palette.dart';
import 'list_pages.dart';
import 'ui_theme.dart';
import 'workspace_data.dart' show spaceName;

class MobileHome extends StatelessWidget {
  const MobileHome({
    required this.date,
    required this.mode,
    required this.modeControl,
    required this.note,
    required this.events,
    required this.tasks,
    required this.onNoteTap,
    required this.onCalendarTap,
    this.focusedContent,
    this.onPlanDay,
    this.onWhatFitsNow,
    this.modeName,
    this.notesAlreadyFiltered = false,
    this.showTasks,
    this.showSchedule,
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    super.key,
  });

  final DateTime date;
  final String? mode;
  final String? modeName;
  final Widget modeControl;
  final Widget? focusedContent;
  final VoidCallback? onPlanDay;
  final VoidCallback? onWhatFitsNow;
  final bool notesAlreadyFiltered;
  final bool? showTasks;
  final bool? showSchedule;
  final NoteItem? note;
  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final VoidCallback onNoteTap;
  final VoidCallback onCalendarTap;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<TaskItem> onTaskTap;
  final ValueChanged<TaskItem> onTaskToggle;

  List<CalendarEvent> _dayEvents(DateTime day, DateTime now) {
    final tomorrow = DateUtils.addDaysToDate(day, 1);
    return events.where((event) {
      final start = event.start;
      final end = event.end.isAfter(start) ? event.end : start;
      final occursOnDay =
          start.isBefore(tomorrow) && (end.isAfter(day) || start == day);
      return occursOnDay &&
          (event.allDay || !DateUtils.isSameDay(day, now) || end.isAfter(now));
    }).toList()..sort((first, second) => first.start.compareTo(second.start));
  }

  List<TaskItem> _objectives(DateTime day) {
    final result = <TaskItem>[];
    final completed = <TaskItem>[];
    final tomorrow = DateUtils.addDaysToDate(day, 1);
    for (final task in tasks) {
      final taskDay = (task.dueAt ?? task.date)?.toLocal();
      final dueToday = DateUtils.isSameDay(taskDay, day);
      if (task.done) {
        if (dueToday) completed.add(task);
      } else if (dueToday ||
          (mode != null && (taskDay == null || taskDay.isBefore(tomorrow)))) {
        result.add(task);
      }
    }
    return [...result, ...completed];
  }

  @override
  Widget build(BuildContext context) {
    final day = DateUtils.dateOnly(date);
    final now = DateTime.now();
    final activeMode = mode;
    final isToday = DateUtils.isSameDay(day, now);
    final localizations = MaterialLocalizations.of(context);
    final dayLabel = localizations.formatMediumDate(day);
    final fullDate = localizations.formatFullDate(day);
    final note =
        notesAlreadyFiltered ||
            activeMode == null ||
            this.note?.category?.toLowerCase() == activeMode.toLowerCase()
        ? this.note
        : null;
    final showTaskSection = showTasks ?? focusedContent == null;
    final showScheduleSection = showSchedule ?? focusedContent == null;
    final dayEvents = showScheduleSection
        ? _dayEvents(day, now)
        : const <CalendarEvent>[];
    const eventLimit = 3;
    final remainingEvents = dayEvents.length - eventLimit;
    final objectives = showTaskSection ? _objectives(day) : const <TaskItem>[];
    final schedule = _HomeSection(
      title: isToday ? 'Upcoming today' : 'Schedule',
      children: [
        if (dayEvents.isEmpty)
          _EmptySection(
            isToday ? 'No more events today.' : 'Nothing scheduled.',
          ),
        for (final (index, event) in dayEvents.take(eventLimit).indexed)
          _HomeEvent(
            event: event,
            day: day,
            showDivider: index < math.min(eventLimit, dayEvents.length) - 1,
            onTap: () => onEventTap(event),
          ),
        if (remainingEvents > 0)
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: _timeColumnWidth(context),
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: onCalendarTap,
                child: Text(
                  '+$remainingEvents more',
                  semanticsLabel:
                      '$remainingEvents more ${remainingEvents == 1 ? 'event' : 'events'}. Open Calendar.',
                ),
              ),
            ),
          ),
      ],
    );
    final taskAction = onWhatFitsNow ?? onPlanDay;
    final taskHeading = _HomeSection(
      action: taskAction == null
          ? null
          : (onWhatFitsNow == null ? 'Plan day' : 'What fits now', taskAction),
      title: activeMode != null
          ? 'Objectives'
          : isToday
          ? 'Tasks due today'
          : 'Tasks due',
      children: [
        if (objectives.isEmpty)
          _EmptySection(
            activeMode != null
                ? 'No open objectives.'
                : isToday
                ? 'No tasks due today.'
                : 'No tasks due.',
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final gutter = math.max(
          compact ? 20.0 : 28.0,
          (constraints.maxWidth - 620) / 2,
        );
        final gap = SizedBox(height: compact ? 15 : 27);
        Widget block(Widget child) => SliverToBoxAdapter(child: child);
        return CustomScrollView(
          key: PageStorageKey(('mobile-home', activeMode)),
          slivers: [
            SliverPadding(
              padding: EdgeInsetsDirectional.fromSTEB(
                gutter,
                compact ? 20 : 28,
                gutter,
                110 + MediaQuery.paddingOf(context).bottom,
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  block(
                    _HomeHeading(
                      compact: compact,
                      mode: activeMode,
                      modeName: modeName,
                      modeControl: modeControl,
                      dayLabel: dayLabel,
                      fullDate: fullDate,
                    ),
                  ),
                  block(SizedBox(height: compact ? 16 : 32)),
                  if (note != null || activeMode == null) ...[
                    block(
                      _HomeSection(
                        title: 'Note to self',
                        children: [
                          _HomeNote(
                            note: note,
                            onTap: onNoteTap,
                            compact: compact,
                          ),
                        ],
                      ),
                    ),
                    block(SizedBox(height: compact ? 12 : 28)),
                  ],
                  if (focusedContent case final content?) ...[
                    block(content),
                    block(gap),
                  ],
                  if (activeMode == null && showScheduleSection) ...[
                    block(schedule),
                    block(gap),
                  ],
                  if (showTaskSection) ...[
                    block(taskHeading),
                    if (objectives.isNotEmpty)
                      SliverList.separated(
                        itemCount: objectives.length,
                        itemBuilder: (_, index) {
                          final task = objectives[index];
                          return _HomeTask(
                            key: ValueKey(task.id),
                            task: task,
                            showCategory: activeMode == null,
                            onTap: () => onTaskTap(task),
                            onToggle: () => onTaskToggle(task),
                          );
                        },
                        separatorBuilder: (_, _) => const Divider(indent: 49),
                      ),
                    block(gap),
                  ],
                  if (activeMode != null &&
                      showScheduleSection &&
                      (dayEvents.isNotEmpty || !showTaskSection)) ...[
                    block(schedule),
                    block(gap),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeHeading extends StatelessWidget {
  const _HomeHeading({
    required this.compact,
    required this.mode,
    required this.modeName,
    required this.modeControl,
    required this.dayLabel,
    required this.fullDate,
  });

  final bool compact;
  final String? mode;
  final String? modeName;
  final Widget modeControl;
  final String dayLabel;
  final String fullDate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selectedMode = mode;
    final fontSize = switch ((selectedMode != null, compact)) {
      (true, true) => 42.0,
      (true, false) => 48.0,
      (false, true) => 33.0,
      (false, false) => 40.0,
    };
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            selectedMode == null
                ? dayLabel
                : modeName ?? spaceName(selectedMode),
            semanticsLabel: selectedMode == null ? fullDate : null,
            style: workspaceHeadingStyle(true).copyWith(
              color: colors.onSurface,
              fontSize: fontSize,
              letterSpacing: -fontSize * .051,
            ),
          ),
        ),
        if (selectedMode != null) ...[
          const SizedBox(height: 7),
          Text(
            dayLabel,
            semanticsLabel: fullDate,
            style: contentMetadataStyle.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
    if (MediaQuery.textScalerOf(context).scale(13) > 18) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(alignment: AlignmentDirectional.centerEnd, child: modeControl),
          heading,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: heading),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: modeControl,
        ),
      ],
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.children,
    this.action,
  });

  final String title;
  final List<Widget> children;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final heading = Semantics(
      header: true,
      child: Text(
        title,
        style: sectionHeadingStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (action case (final label, final callback))
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              heading,
              TextButton(onPressed: callback, child: Text(label)),
            ],
          )
        else
          heading,
        SizedBox(height: MediaQuery.sizeOf(context).width < 360 ? 10 : 12),
        ...children,
      ],
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Text(
        message,
        style: contentMetadataStyle.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HomeNote extends StatelessWidget {
  const _HomeNote({
    required this.note,
    required this.onTap,
    required this.compact,
  });

  final NoteItem? note;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final titleStyle = contentTitleStyle.copyWith(color: colors.onSurface);
    final metadata = contentMetadataStyle.copyWith(
      color: colors.onSurfaceVariant,
    );
    final title = note?.title.trim() ?? '';
    final body = note?.body.trim() ?? '';
    final showTitle = title.isNotEmpty && title.toLowerCase() != 'note to self';
    final isEmpty = !showTitle && body.isEmpty;
    final iconSize = compact ? 31.0 : 35.0;
    final verticalInset = compact ? 10.0 : 13.0;
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: colors.outlineVariant),
      borderRadius: contentSurfaceRadius,
    );
    return Material(
      color: colors.surfaceContainerLow,
      elevation: .6,
      shadowColor: colors.shadow.withAlpha(0x24),
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              13,
              verticalInset,
              10,
              verticalInset,
            ),
            child: Row(
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: const BorderRadius.all(Radius.circular(9)),
                  ),
                  child: Icon(
                    isEmpty ? Icons.edit_outlined : Icons.notes_rounded,
                    color: readableTint(
                      colors.primary,
                      surface: colors.primaryContainer,
                      foreground: colors.onPrimaryContainer,
                      minimumContrast: 3,
                    ),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showTitle)
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      if (showTitle && body.isNotEmpty)
                        const SizedBox(height: 3),
                      if (body.isNotEmpty || !showTitle)
                        Text(
                          body.isEmpty ? 'Write a note' : body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: isEmpty
                              ? titleStyle.copyWith(color: colors.primary)
                              : metadata,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colors.onSurfaceVariant,
                  size: 17,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

double _timeColumnWidth(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(12) * 5.6).clamp(62.0, 104.0);

class _HomeEvent extends StatelessWidget {
  const _HomeEvent({
    required this.event,
    required this.day,
    required this.showDivider,
    required this.onTap,
  });

  final CalendarEvent event;
  final DateTime day;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final format = MaterialLocalizations.of(context);
    final tone = readableTint(
      event.color ?? WorkspaceCategoryPalette.colorFor(context, event.category),
      surface: colors.surface,
      foreground: colors.onSurface,
      minimumContrast: 3,
    );
    final metadata = contentMetadataStyle.copyWith(
      color: colors.onSurfaceVariant,
    );
    final compact = MediaQuery.sizeOf(context).width < 360;
    final time = event.allDay
        ? 'All day'
        : event.start.isBefore(day)
        ? 'Continued'
        : format.formatTimeOfDay(
            TimeOfDay.fromDateTime(event.start.toLocal()),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    final location = event.location?.trim();
    final timeWidth = _timeColumnWidth(context);
    return Column(
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: contentControlShape,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: compact ? 51 : 55),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: compact ? 6 : 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: timeWidth,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 9),
                        child: Text(
                          time,
                          style: metadata.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: tone,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 7),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.title,
                            style: contentTitleStyle.copyWith(
                              color: colors.onSurface,
                            ),
                          ),
                          if (location?.isNotEmpty ?? false) ...[
                            const SizedBox(height: 2),
                            Text(location!, style: metadata),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider) Divider(indent: timeWidth + 19),
      ],
    );
  }
}

class _HomeTask extends StatelessWidget {
  const _HomeTask({
    required this.task,
    required this.showCategory,
    required this.onTap,
    required this.onToggle,
    super.key,
  });

  final TaskItem task;
  final bool showCategory;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Checkbox(
          value: task.done,
          semanticLabel: task.done
              ? 'Reopen ${task.title}'
              : 'Complete ${task.title}',
          onChanged: (_) => onToggle(),
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(1, 5, 8, 5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: contentTitleStyle.copyWith(
                        color: task.done
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                        decoration: task.done
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    if (showCategory && task.category.trim().isNotEmpty)
                      Text(
                        WorkspaceCategoryPalette.labelFor(
                          context,
                          task.category,
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: readableTint(
                            Color.lerp(
                              WorkspaceCategoryPalette.colorFor(
                                context,
                                task.category,
                              ),
                              colors.onSurface,
                              .2,
                            )!,
                            surface: colors.surface,
                            foreground: colors.onSurface,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
