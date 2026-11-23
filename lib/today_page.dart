import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'workspace_data.dart';

class TodayPage extends StatelessWidget {
  const TodayPage({
    required this.date,
    required this.events,
    required this.tasks,
    required this.onDateChanged,
    required this.onEventTap,
    required this.onTaskTap,
    required this.onTaskToggle,
    super.key,
  });

  final DateTime date;
  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<CalendarEvent> onEventTap;
  final ValueChanged<TaskItem> onTaskTap;
  final ValueChanged<TaskItem> onTaskToggle;

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final localizations = MaterialLocalizations.of(context);
    final dayEvents = events.where((event) {
      return event.start.isBefore(plusDays(date, 1)) &&
          (event.end.isAfter(date) || sameDay(event.start, date));
    }).toList()..sort((a, b) => a.start.compareTo(b.start));
    final dayTasks = tasks.where((task) {
      return task.date != null && sameDay(task.date!, date);
    }).toList()..sort((a, b) => (a.done ? 1 : 0).compareTo(b.done ? 1 : 0));
    final remaining = dayTasks.where((task) => !task.done).length;
    final isToday = sameDay(today, date);
    final text = Theme.of(context).textTheme;
    final firstDay = plusDays(date, -(date.weekday - DateTime.monday));

    return ListView(
      key: const PageStorageKey('today'),
      padding: EdgeInsets.fromLTRB(
        mobile ? 22 : 44,
        mobile ? 22 : 41,
        mobile ? 22 : 44,
        mobile ? MediaQuery.paddingOf(context).bottom + 107 : 38,
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
                      'Today',
                      style: text.headlineLarge?.copyWith(
                        fontSize: mobile ? 36 : 42,
                        height: 1.06,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1.7,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    localizations.formatFullDate(date),
                    style: text.bodyMedium?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DateArrow(
                  icon: Icons.chevron_left_rounded,
                  label: 'Previous day',
                  onPressed: () => onDateChanged(plusDays(date, -1)),
                ),
                const SizedBox(width: 4),
                _DateArrow(
                  icon: Icons.chevron_right_rounded,
                  label: 'Next day',
                  onPressed: () => onDateChanged(plusDays(date, 1)),
                ),
              ],
            ),
          ],
        ),
        SizedBox(height: mobile ? 26 : 32),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Row(
              children: [
                for (var index = 0; index < 7; index++)
                  Expanded(
                    child: _DateTile(
                      date: plusDays(firstDay, index),
                      selected: sameDay(plusDays(firstDay, index), date),
                      isToday: sameDay(plusDays(firstDay, index), today),
                      onPressed: () => onDateChanged(plusDays(firstDay, index)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: mobile ? 22 : 27),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: mobile ? 13 : 16,
            vertical: 13,
          ),
          decoration: BoxDecoration(
            color: const Color(0xfff0f0ea),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              const Icon(Icons.wb_twilight_outlined, size: 19, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${dayEvents.length} ${dayEvents.length == 1 ? 'event' : 'events'} · '
                  '$remaining ${remaining == 1 ? 'task' : 'tasks'} left',
                  style: text.bodyMedium?.copyWith(
                    color: const Color(0xff4f5c51),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!isToday)
                TextButton(
                  onPressed: () => onDateChanged(today),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Back to today'),
                ),
            ],
          ),
        ),
        SizedBox(height: mobile ? 26 : 33),
        const _SectionTitle('Schedule'),
        const SizedBox(height: 11),
        if (dayEvents.isEmpty)
          const _EmptyRow('Nothing scheduled for this day.'),
        for (final event in dayEvents)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ScheduleRow(
              event: event,
              date: date,
              mobile: mobile,
              onTap: () => onEventTap(event),
            ),
          ),
        SizedBox(height: mobile ? 22 : 27),
        const _SectionTitle('Tasks'),
        const SizedBox(height: 6),
        if (dayTasks.isEmpty) const _EmptyRow('No tasks due this day.'),
        for (final task in dayTasks)
          _TodayTask(
            task: task,
            onToggle: () => onTaskToggle(task),
            onTap: () => onTaskTap(task),
          ),
      ],
    );
  }
}

class _DateArrow extends StatelessWidget {
  const _DateArrow({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xffefefe9),
        foregroundColor: const Color(0xff50594f),
      ),
      onPressed: onPressed,
    );
  }
}

class _DateTile extends StatelessWidget {
  const _DateTile({
    required this.date,
    required this.selected,
    required this.isToday,
    required this.onPressed,
  });

  final DateTime date;
  final bool selected;
  final bool isToday;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final weekday = localizations.narrowWeekdays[date.weekday % 7];
    final weekdayLabel =
        MediaQuery.textScalerOf(context).scale(12) > 17 ||
            MediaQuery.sizeOf(context).width < 350
        ? weekday
        : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday -
              1];
    final foreground = selected ? Colors.white : ink;

    return Semantics(
      label: localizations.formatFullDate(date),
      button: true,
      selected: selected,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: selected ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: [
                    Text(
                      weekdayLabel,
                      style: TextStyle(
                        color: selected ? const Color(0xffe7eee8) : muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${date.day}',
                      style: TextStyle(
                        color: foreground,
                        fontSize: 18,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 3,
                      width: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isToday ? foreground : Colors.transparent,
                      ),
                    ),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -.35,
        ),
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: const TextStyle(color: muted)),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.event,
    required this.date,
    required this.mobile,
    required this.onTap,
  });
  final CalendarEvent event;
  final DateTime date;
  final bool mobile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = spaceColor(event.category);
    final localizations = MaterialLocalizations.of(context);
    String time(DateTime value) =>
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value));
    final start = event.allDay
        ? 'All day'
        : (event.start.isBefore(date) ? 'Continued' : time(event.start));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: mobile ? 68 : 91,
          child: Text(
            start,
            style: const TextStyle(
              color: muted,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Material(
            color: Color.alphaBlend(color.withValues(alpha: .10), paper),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColoredBox(color: color, child: const SizedBox(width: 3)),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    event.title,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (event.location?.isNotEmpty ?? false)
                                    Text(
                                      event.location!,
                                      style: TextStyle(
                                        color: color,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (!mobile && !event.allDay)
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: Text(
                                  'Until ${time(event.end)}',
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
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
    final color = spaceColor(task.category);
    return Row(
      children: [
        SizedBox(
          width: 42,
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
            borderRadius: BorderRadius.circular(7),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: TextStyle(
                      fontSize: 15,
                      color: task.done ? muted : ink,
                      fontWeight: FontWeight.w500,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    spaceName(task.category),
                    style: TextStyle(color: color, fontSize: 12),
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
