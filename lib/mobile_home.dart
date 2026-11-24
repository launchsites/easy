import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'ui_theme.dart';
import 'workspace_data.dart' show spaceColor, spaceName;

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
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    super.key,
  });

  final DateTime date;
  final String? mode;
  final Widget modeControl;
  final Widget? focusedContent;
  final VoidCallback? onPlanDay;
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
      final taskDay = task.date?.toLocal();
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
        activeMode == null ||
            this.note?.category?.toLowerCase() == activeMode.toLowerCase()
        ? this.note
        : null;
    final dayEvents = _dayEvents(day, now);
    const eventLimit = 3;
    final remainingEvents = dayEvents.length - eventLimit;
    final objectives = _objectives(day);
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
    final taskList = _HomeSection(
      onPlanDay: onPlanDay,
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
        for (final (index, task) in objectives.indexed) ...[
          _HomeTask(
            key: ValueKey(task.id),
            task: task,
            showCategory: activeMode == null,
            onTap: () => onTaskTap(task),
            onToggle: () => onTaskToggle(task),
          ),
          if (index < objectives.length - 1) const Divider(indent: 49),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final gutter = math.max(
          compact ? 20.0 : 28.0,
          (constraints.maxWidth - 620) / 2,
        );
        return ListView(
          key: PageStorageKey(('mobile-home', activeMode)),
          padding: EdgeInsetsDirectional.fromSTEB(
            gutter,
            compact ? 20 : 28,
            gutter,
            110 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _HomeHeading(
              compact: compact,
              mode: activeMode,
              modeControl: modeControl,
              dayLabel: dayLabel,
              fullDate: fullDate,
            ),
            SizedBox(height: compact ? 22 : 32),
            if (note != null || activeMode == null) ...[
              _HomeSection(
                title: 'Note to self',
                children: [
                  _HomeNote(note: note, onTap: onNoteTap, compact: compact),
                ],
              ),
              SizedBox(height: compact ? 20 : 28),
            ],
            if (focusedContent case final content?)
              content
            else if (activeMode == null) ...[
              schedule,
              const SizedBox(height: 27),
              taskList,
            ] else ...[
              taskList,
              if (dayEvents.isNotEmpty) ...[
                const SizedBox(height: 27),
                schedule,
              ],
            ],
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
    required this.modeControl,
    required this.dayLabel,
    required this.fullDate,
  });

  final bool compact;
  final String? mode;
  final Widget modeControl;
  final String dayLabel;
  final String fullDate;

  @override
  Widget build(BuildContext context) {
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
            selectedMode == null ? dayLabel : spaceName(selectedMode),
            semanticsLabel: selectedMode == null ? fullDate : null,
            style: workspaceHeadingStyle(true)
                .copyWith(fontSize: fontSize, letterSpacing: -fontSize * .051),
          ),
        ),
        if (selectedMode != null) ...[
          const SizedBox(height: 7),
          Text(
            dayLabel,
            semanticsLabel: fullDate,
            style: contentMetadataStyle.copyWith(fontWeight: FontWeight.w500),
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
    this.onPlanDay,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback? onPlanDay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onPlanDay == null)
          Semantics(
            header: true,
            child: Text(title, style: sectionHeadingStyle),
          )
        else
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: sectionHeadingStyle),
                ),
              ),
              TextButton(onPressed: onPlanDay, child: const Text('Plan day')),
            ],
          ),
        const SizedBox(height: 12),
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
      child: Text(message, style: contentMetadataStyle),
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
    final title = note?.title.trim() ?? '';
    final body = note?.body.trim() ?? '';
    final showTitle = title.isNotEmpty && title.toLowerCase() != 'note to self';
    final isEmpty = !showTitle && body.isEmpty;
    final iconSize = compact ? 31.0 : 35.0;
    final verticalInset = compact ? 10.0 : 13.0;
    const shape = RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    );
    return Material(
      color: raisedPaper,
      elevation: .6,
      shadowColor: const Color(0x24373b2f),
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
                  decoration: const BoxDecoration(
                    color: softAccent,
                    borderRadius: BorderRadius.all(Radius.circular(9)),
                  ),
                  child: Icon(
                    isEmpty ? Icons.edit_outlined : Icons.notes_rounded,
                    color: accent,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showTitle) Text(title, style: contentTitleStyle),
                      if (showTitle && body.isNotEmpty)
                        const SizedBox(height: 3),
                      if (body.isNotEmpty || !showTitle)
                        Text(
                          body.isEmpty ? 'Write a note' : body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: isEmpty
                              ? contentTitleStyle.copyWith(color: accent)
                              : contentMetadataStyle,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                const Icon(Icons.chevron_right_rounded, color: muted, size: 17),
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
    final format = MaterialLocalizations.of(context);
    final tone = spaceColor(event.category);
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
              constraints: const BoxConstraints(minHeight: 55),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: timeWidth,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 9),
                        child: Text(
                          time,
                          style: contentMetadataStyle.copyWith(
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
                          Text(event.title, style: contentTitleStyle),
                          if (location?.isNotEmpty ?? false) ...[
                            const SizedBox(height: 2),
                            Text(location!, style: contentMetadataStyle),
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
                      style: task.done
                          ? contentTitleStyle.copyWith(
                              color: muted,
                              decoration: TextDecoration.lineThrough,
                            )
                          : contentTitleStyle,
                    ),
                    if (showCategory && task.category.trim().isNotEmpty)
                      Text(
                        spaceName(task.category),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: Color.lerp(spaceColor(task.category), ink, .2),
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
