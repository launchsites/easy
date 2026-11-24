import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'workspace_data.dart';

class TodayPage extends StatelessWidget {
  const TodayPage({
    required this.date,
    required this.events,
    required this.tasks,
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    this.onPlanDay,
    this.title = 'Today',
    this.showSchedule = true,
    this.showTasks = true,
    this.focusedContent,
    super.key,
  });

  final DateTime date;
  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<TaskItem> onTaskTap;
  final ValueChanged<TaskItem> onTaskToggle;
  final VoidCallback? onPlanDay;
  final String title;
  final bool showSchedule;
  final bool showTasks;
  final Widget? focusedContent;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final localizations = MaterialLocalizations.of(context);
    final tomorrow = plusDays(date, 1);
    final dayEvents =
        events
            .where(
              (event) =>
                  event.start.isBefore(tomorrow) &&
                  (event.end.isAfter(date) || sameDay(event.start, date)),
            )
            .toList()
          ..sort((first, second) => first.start.compareTo(second.start));
    final dayTasks = tasks.where(
      (task) => task.date != null && sameDay(task.date!, date),
    );
    final bottom = mobile ? MediaQuery.paddingOf(context).bottom + 110.0 : 52.0;

    return ListView(
      key: const PageStorageKey('today'),
      padding: EdgeInsets.fromLTRB(
        mobile ? 28 : 48,
        mobile ? 23 : 50,
        mobile ? 28 : 48,
        bottom,
      ),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 970),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: workspaceHeadingStyle(mobile)),
                ),
                const SizedBox(height: 8),
                Text(
                  localizations.formatFullDate(date),
                  style: TextStyle(
                    color: muted,
                    fontSize: mobile ? 13.5 : 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: mobile ? 32 : 45),
                if (focusedContent case final content?) ...[
                  content,
                  if (showTasks || showSchedule) const SizedBox(height: 33),
                ],
                if (showSchedule) ...[
                  const _SectionHeading('Schedule'),
                  const SizedBox(height: 14),
                  if (dayEvents.isEmpty)
                    const _EmptyMessage('Nothing scheduled for today.'),
                  for (final event in dayEvents)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ScheduleItem(
                        event: event,
                        date: date,
                        narrow: mobile,
                        onTap: () => onEventTap(event),
                      ),
                    ),
                  if (showTasks) SizedBox(height: mobile ? 23 : 33),
                ],
                if (showTasks) ...[
                  Row(
                    children: [
                      const Expanded(child: _SectionHeading('Tasks')),
                      if (onPlanDay != null)
                        TextButton(
                          onPressed: onPlanDay,
                          child: const Text('Plan day'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (dayTasks.isEmpty)
                    const _EmptyMessage('No tasks due today.'),
                  for (final task in [
                    ...dayTasks.where((task) => !task.done),
                    ...dayTasks.where((task) => task.done),
                  ])
                    _TodayTask(
                      task: task,
                      onToggle: () => onTaskToggle(task),
                      onTap: () => onTaskTap(task),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: Text(title, style: sectionHeadingStyle));
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(message, style: const TextStyle(color: muted, fontSize: 14)),
  );
}

class _ScheduleItem extends StatelessWidget {
  const _ScheduleItem({
    required this.event,
    required this.date,
    required this.narrow,
    required this.onTap,
  });

  final CalendarEvent event;
  final DateTime date;
  final bool narrow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = spaceColor(event.category);
    final localizations = MaterialLocalizations.of(context);
    final use24Hours = MediaQuery.alwaysUse24HourFormatOf(context);
    String time(DateTime value) => localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: use24Hours,
    );
    final start = event.allDay
        ? 'All day'
        : event.start.isBefore(date)
        ? 'Continued'
        : time(event.start);
    final place = event.location?.trim();
    final contextLabel = place == null || place.isEmpty
        ? spaceName(event.category)
        : place;
    final shape = BorderRadius.circular(11);
    final fill = Color.alphaBlend(tone.withValues(alpha: .09), paper);
    final textScale = MediaQuery.textScalerOf(context);
    final compact = narrow || textScale.scale(14) > 18;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: narrow ? 75 : 104,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: Text(
              start,
              style: const TextStyle(
                color: muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Expanded(
          child: Material(
            color: fill,
            borderRadius: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              borderRadius: shape,
              child: Stack(
                children: [
                  PositionedDirectional(
                    start: 0,
                    top: 11,
                    bottom: 11,
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: tone,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: narrow ? 58 : 64),
                    child: Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        narrow ? 14 : 17,
                        10,
                        narrow ? 12 : 17,
                        10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  event.title,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -.22,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  contextLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Color.lerp(tone, ink, .22),
                                    height: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!compact && !event.allDay) ...[
                            const SizedBox(width: 12),
                            Text(
                              'Until ${time(event.end)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: muted,
                                fontFeatures: [FontFeature.tabularFigures()],
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
      ],
    );
  }
}

class _TodayTask extends StatelessWidget {
  const _TodayTask({
    required this.task,
    required this.onToggle,
    required this.onTap,
  });

  final TaskItem task;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 43,
              child: Checkbox(
                value: task.done,
                semanticLabel: task.done
                    ? 'Mark ${task.title} incomplete'
                    : 'Complete ${task.title}',
                onChanged: (_) => onToggle(),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 15,
                          color: task.done ? muted : ink,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.2,
                          decoration: task.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        spaceName(task.category),
                        style: TextStyle(
                          color: Color.lerp(
                            spaceColor(task.category),
                            ink,
                            .16,
                          ),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const Divider(indent: 47),
      ],
    );
  }
}
