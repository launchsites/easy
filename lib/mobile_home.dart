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
    this.modeAction,
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    super.key,
  });

  final DateTime date;
  final String? mode;
  final Widget modeControl;
  final Widget? modeAction;
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
        for (final event in dayEvents.take(eventLimit))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: _HomeEvent(
              event: event,
              day: day,
              onTap: () => onEventTap(event),
            ),
          ),
        if (remainingEvents > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 70),
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
        for (final task in objectives)
          _HomeTask(
            key: ValueKey(task.id),
            task: task,
            showCategory: activeMode == null,
            onTap: () => onTaskTap(task),
            onToggle: () => onTaskToggle(task),
          ),
      ],
    );

    return ListView(
      key: PageStorageKey(('mobile-home', activeMode)),
      padding: EdgeInsetsDirectional.fromSTEB(
        28,
        20,
        28,
        110 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      activeMode == null ? dayLabel : spaceName(activeMode),
                      semanticsLabel: activeMode == null ? fullDate : null,
                      style: workspaceHeadingStyle(true).copyWith(
                        fontSize: activeMode == null ? 36 : 44,
                        letterSpacing: activeMode == null ? -1.9 : -2.5,
                      ),
                    ),
                  ),
                  if (activeMode != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      dayLabel,
                      semanticsLabel: fullDate,
                      style: const TextStyle(
                        fontSize: 13,
                        color: muted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 116),
              child: modeControl,
            ),
          ],
        ),
        const SizedBox(height: 28),
        if (note != null || activeMode == null) ...[
          _HomeSection(
            title: 'Note to self',
            children: [_HomeNote(note: note, onTap: onNoteTap)],
          ),
          const SizedBox(height: 24),
        ],
        if (activeMode == null) ...[
          schedule,
          const SizedBox(height: 23),
          taskList,
        ] else ...[
          if (modeAction case final action?) ...[
            action,
            const SizedBox(height: 24),
          ],
          taskList,
          if (dayEvents.isNotEmpty) ...[const SizedBox(height: 23), schedule],
        ],
      ],
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text(title, style: sectionHeadingStyle)),
        const SizedBox(height: 10),
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
      child: Text(message, style: const TextStyle(color: muted, fontSize: 14)),
    );
  }
}

class _HomeNote extends StatelessWidget {
  const _HomeNote({required this.note, required this.onTap});

  final NoteItem? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = note?.title.trim() ?? '';
    final body = note?.body.trim() ?? '';
    final showTitle = title.isNotEmpty && title.toLowerCase() != 'note to self';
    const shape = RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: BorderRadius.all(Radius.circular(11)),
    );
    return Material(
      color: raisedPaper,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 51),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(
                  body.isEmpty ? Icons.edit_outlined : Icons.notes_rounded,
                  color: accent,
                  size: 17,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showTitle) Text(title, style: _entryTitle),
                      if (body.isNotEmpty || !showTitle)
                        Text(
                          body.isEmpty ? 'Write a note' : body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: body.isEmpty ? accent : muted,
                            fontWeight: FontWeight.w500,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                    ],
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

const _entryTitle = TextStyle(
  color: ink,
  fontSize: 15,
  fontWeight: FontWeight.w600,
  height: 1.33,
  letterSpacing: -.22,
);

class _HomeEvent extends StatelessWidget {
  const _HomeEvent({
    required this.event,
    required this.day,
    required this.onTap,
  });

  final CalendarEvent event;
  final DateTime day;
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
    const radius = BorderRadius.all(Radius.circular(9));
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 51),
          child: Row(
            children: [
              SizedBox(
                width: 70,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Text(
                    time,
                    style: const TextStyle(
                      color: muted,
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      height: 1.15,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Ink(
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(tone.withValues(alpha: .09), paper),
                    borderRadius: radius,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 51),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(event.title, style: _entryTitle),
                          if (location?.isNotEmpty ?? false)
                            Text(
                              location!,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
                          ? _entryTitle.copyWith(
                              color: muted,
                              decoration: TextDecoration.lineThrough,
                            )
                          : _entryTitle,
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
