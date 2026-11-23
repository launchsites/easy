import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.category,
    this.allDay = false,
    this.location,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String category;
  final bool allDay;
  final String? location;
}

enum CalendarView {
  day('Day'),
  week('Week'),
  month('Month');

  const CalendarView(this.label);

  final String label;
}

enum _MobileDateAction {
  today('Today'),
  previous('Previous day'),
  next('Next day'),
  jump('Jump to date');

  const _MobileDateAction(this.label);

  final String label;
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.date,
    required this.onDateChanged,
    required this.events,
    required this.onEventTap,
    super.key,
  });

  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  CalendarView? _selectedView;
  bool _dayShowsAgenda = false;
  bool _weekShowsAgenda = false;
  double _swipeDistance = 0;

  DateTime get _date => DateUtils.dateOnly(widget.date);

  List<CalendarEvent> _eventsOn(DateTime day) {
    final nextDay = DateUtils.addDaysToDate(day, 1);
    return widget.events.where((event) {
      if (!event.end.isAfter(event.start)) {
        return DateUtils.isSameDay(event.start.toLocal(), day);
      }
      return event.start.isBefore(nextDay) && event.end.isAfter(day);
    }).toList()..sort((first, second) {
      if (first.allDay != second.allDay) return first.allDay ? -1 : 1;
      return first.start.compareTo(second.start);
    });
  }

  void _advance(CalendarView view, int step) {
    final date = switch (view) {
      CalendarView.day => DateUtils.addDaysToDate(_date, step),
      CalendarView.week => DateUtils.addDaysToDate(_date, step * 7),
      CalendarView.month => _otherMonth(step),
    };
    widget.onDateChanged(date);
  }

  DateTime _otherMonth(int step) {
    final month = DateTime(_date.year, _date.month + step);
    final lastDay = DateUtils.getDaysInMonth(month.year, month.month);
    return DateTime(month.year, month.month, math.min(_date.day, lastDay));
  }

  Future<void> _jumpToDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 100),
      lastDate: DateTime(_date.year + 100, 12, 31),
    );
    if (mounted && date != null) widget.onDateChanged(date);
  }

  void _openDay(DateTime day) {
    setState(() => _selectedView = CalendarView.day);
    widget.onDateChanged(day);
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final view =
        _selectedView ?? (mobile ? CalendarView.day : CalendarView.week);
    final colors = _CalendarColors.of(context);
    if (mobile && view == CalendarView.day) {
      final allDay = _eventsOn(_date).where((event) => event.allDay);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mobileDayHeader(context, colors),
          if (allDay.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  child: _allDayStrip(colors, allDay),
                ),
              ),
            ),
          Expanded(
            child: _ContinuousDayTimeline(
              date: _date,
              onDateChanged: widget.onDateChanged,
              eventsOn: _eventsOn,
              section: (context, date, timelineKey) =>
                  _mobileDaySection(context, colors, date, timelineKey),
            ),
          ),
        ],
      );
    }
    final week = _weekContaining(_date);
    final inset = mobile ? 22.0 : 44.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final canShowWeekTimeline =
            !mobile && constraints.maxWidth - 2 * inset >= 660;
        return SingleChildScrollView(
          key: PageStorageKey('calendar-${view.name}'),
          padding: EdgeInsets.fromLTRB(
            inset,
            mobile ? 22 : 41,
            inset,
            mobile ? 107 + MediaQuery.paddingOf(context).bottom : 38,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, colors, view, mobile, canShowWeekTimeline),
              const SizedBox(height: 18),
              if (view == CalendarView.day) ...[
                _dateStrip(context, colors, week),
                const SizedBox(height: 16),
              ],
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _swipeDistance = 0,
                onHorizontalDragUpdate: (details) {
                  _swipeDistance += details.delta.dx;
                },
                onHorizontalDragEnd: (_) {
                  if (_swipeDistance.abs() >= 48) {
                    _advance(view, _swipeDistance < 0 ? 1 : -1);
                  }
                },
                child: switch (view) {
                  CalendarView.day => _day(context, colors, mobile),
                  CalendarView.week =>
                    _weekShowsAgenda || !canShowWeekTimeline
                        ? _weekAgenda(context, colors, week)
                        : _timeline(context, colors, week, mobile: false),
                  CalendarView.month => _month(context, colors, mobile),
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _mobileDayHeader(BuildContext context, _CalendarColors colors) {
    final dateLabel = MaterialLocalizations.of(context).formatMediumDate(_date);

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 5, 22, 6),
      child: Row(
        children: [
          Expanded(
            child: PopupMenuButton<_MobileDateAction>(
              tooltip: 'Calendar date options',
              onSelected: (action) {
                switch (action) {
                  case _MobileDateAction.today:
                    widget.onDateChanged(DateUtils.dateOnly(DateTime.now()));
                  case _MobileDateAction.previous:
                    _advance(CalendarView.day, -1);
                  case _MobileDateAction.next:
                    _advance(CalendarView.day, 1);
                  case _MobileDateAction.jump:
                    _jumpToDate();
                }
              },
              itemBuilder: (_) => [
                for (final action in _MobileDateAction.values)
                  PopupMenuItem(value: action, child: Text(action.label)),
              ],
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        dateLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          letterSpacing: -.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 19,
                      color: colors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<CalendarView>(
            tooltip: 'Calendar view',
            initialValue: CalendarView.day,
            onSelected: (view) => setState(() => _selectedView = view),
            itemBuilder: (_) => [
              for (final view in CalendarView.values)
                PopupMenuItem(value: view, child: Text(view.label)),
            ],
            child: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Day',
                    style: TextStyle(
                      color: colors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 17,
                    color: colors.muted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileDaySection(
    BuildContext context,
    _CalendarColors colors,
    DateTime date,
    GlobalKey timelineKey,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
            child: Semantics(
              header: true,
              child: Text(
                MaterialLocalizations.of(context).formatFullDate(date),
                style: TextStyle(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          _day(context, colors, true, date: date, timelineKey: timelineKey),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    _CalendarColors colors,
    CalendarView view,
    bool mobile,
    bool canShowWeekTimeline,
  ) {
    final localizations = MaterialLocalizations.of(context);
    final dateLabel = switch (view) {
      CalendarView.day => localizations.formatMediumDate(_date),
      CalendarView.week ||
      CalendarView.month => localizations.formatMonthYear(_date),
    };
    final title = Semantics(
      header: true,
      child: Text(
        'Calendar',
        style: TextStyle(
          color: colors.ink,
          fontSize: mobile ? 32 : 36,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
          height: 1.15,
        ),
      ),
    );
    final date = Tooltip(
      message: 'Jump to date',
      child: TextButton(
        onPressed: _jumpToDate,
        style: TextButton.styleFrom(
          foregroundColor: colors.ink,
          padding: const EdgeInsetsDirectional.only(end: 7),
          alignment: AlignmentDirectional.centerStart,
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                dateLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 5),
            Icon(Icons.expand_more, size: 17, color: colors.muted),
          ],
        ),
      ),
    );
    final navigationActions = [
      TextButton(
        onPressed: () =>
            widget.onDateChanged(DateUtils.dateOnly(DateTime.now())),
        style: TextButton.styleFrom(
          foregroundColor: colors.accent,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          minimumSize: const Size(0, 44),
        ),
        child: const Text('Today'),
      ),
      IconButton(
        tooltip: 'Previous ${view.name}',
        onPressed: () => _advance(view, -1),
        icon: const Icon(Icons.chevron_left_rounded, size: 22),
        color: colors.ink,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      ),
      IconButton(
        tooltip: 'Next ${view.name}',
        onPressed: () => _advance(view, 1),
        icon: const Icon(Icons.chevron_right_rounded, size: 22),
        color: colors.ink,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      ),
    ];
    final largeMobileText =
        mobile && MediaQuery.textScalerOf(context).scale(15) > 23;
    final dateNavigation = largeMobileText
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              date,
              Wrap(alignment: WrapAlignment.end, children: navigationActions),
            ],
          )
        : Row(
            children: [
              Expanded(child: date),
              ...navigationActions,
            ],
          );
    final viewPicker = _viewPicker(colors, view);
    final canSwitchAgenda =
        view == CalendarView.day ||
        (view == CalendarView.week && canShowWeekTimeline);
    final showsAgenda = view == CalendarView.day
        ? _dayShowsAgenda
        : _weekShowsAgenda;
    final agendaButton = IconButton(
      tooltip: showsAgenda ? 'Show timeline' : 'Show agenda',
      onPressed: () => setState(() {
        if (view == CalendarView.day) {
          _dayShowsAgenda = !_dayShowsAgenda;
        } else {
          _weekShowsAgenda = !_weekShowsAgenda;
        }
      }),
      icon: Icon(
        showsAgenda ? Icons.schedule_rounded : Icons.view_list_outlined,
        size: 21,
      ),
      color: colors.muted,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mobile) ...[
          title,
          const SizedBox(height: 12),
          dateNavigation,
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: viewPicker),
              if (canSwitchAgenda) ...[const SizedBox(width: 8), agendaButton],
            ],
          ),
        ] else ...[
          Row(
            children: [
              Expanded(child: title),
              SizedBox(width: 207, child: viewPicker),
              if (canSwitchAgenda) ...[const SizedBox(width: 6), agendaButton],
            ],
          ),
          const SizedBox(height: 14),
          dateNavigation,
        ],
      ],
    );
  }

  Widget _viewPicker(_CalendarColors colors, CalendarView view) {
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: CalendarView.values.map((value) {
            final selected = value == view;
            return Expanded(
              child: Semantics(
                selected: selected,
                child: TextButton(
                  onPressed: () => setState(() => _selectedView = value),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    foregroundColor: selected ? colors.accent : colors.muted,
                    backgroundColor: selected
                        ? colors.accentFill
                        : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: Text(value.label),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _dateStrip(
    BuildContext context,
    _CalendarColors colors,
    List<DateTime> days,
  ) {
    final localizations = MaterialLocalizations.of(context);
    return Row(
      children: days.map((day) {
        final selected = DateUtils.isSameDay(day, _date);
        final hasEvents = _eventsOn(day).isNotEmpty;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Semantics(
              selected: selected,
              child: Tooltip(
                message: localizations.formatFullDate(day),
                child: Material(
                  color: selected ? colors.accentFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: () => widget.onDateChanged(day),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          Text(
                            _weekday(localizations, day),
                            style: TextStyle(color: colors.muted, fontSize: 11),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            localizations.formatDecimal(day.day),
                            style: TextStyle(
                              color: selected ? colors.accent : colors.ink,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _dot(hasEvents ? colors.accent : Colors.transparent),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _day(
    BuildContext context,
    _CalendarColors colors,
    bool mobile, {
    DateTime? date,
    GlobalKey? timelineKey,
  }) {
    final day = date ?? _date;
    final events = _eventsOn(day);
    if (!mobile && _dayShowsAgenda) return _eventList(context, colors, events);
    final allDay = events.where((event) => event.allDay);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!mobile && allDay.isNotEmpty) ...[
          _allDayStrip(colors, allDay),
          const SizedBox(height: 12),
        ],
        _timeline(
          context,
          colors,
          [day],
          mobile: mobile,
          timelineKey: timelineKey,
        ),
      ],
    );
  }

  Widget _allDayStrip(_CalendarColors colors, Iterable<CalendarEvent> events) {
    return _calendarSurface(
      colors,
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'All day',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 5,
                children: events
                    .map((event) => _eventChip(colors, event))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeline(
    BuildContext context,
    _CalendarColors colors,
    List<DateTime> days, {
    required bool mobile,
    GlobalKey? timelineKey,
  }) {
    final multiDay = days.length > 1;
    final daysEvents = days.map(_eventsOn).toList();
    final placements = [
      for (var index = 0; index < days.length; index++)
        _placeEvents(daysEvents[index], days[index]),
    ];
    final ruler = _TimelineRuler(
      placements.expand((day) => day),
      mobile ? _mobileHourHeight : 59,
      fullDay: mobile,
    );
    final hourColumn = mobile ? 47.0 : 60.0;
    final localizations = MaterialLocalizations.of(context);
    final showAllDay =
        multiDay &&
        daysEvents.any((events) => events.any((event) => event.allDay));
    final now = DateTime.now();

    return KeyedSubtree(
      key: timelineKey,
      child: _calendarSurface(
        colors,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (multiDay)
              Row(
                children: [
                  SizedBox(width: hourColumn),
                  for (final day in days)
                    Expanded(
                      child: InkWell(
                        onTap: () => _openDay(day),
                        child: _weekHeading(localizations, colors, day, now),
                      ),
                    ),
                ],
              ),
            if (showAllDay)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: hourColumn,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, top: 10),
                      child: Text(
                        'All day',
                        style: TextStyle(color: colors.muted, fontSize: 11),
                      ),
                    ),
                  ),
                  for (final events in daysEvents)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(3, 0, 3, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final event in events.where(
                              (event) => event.allDay,
                            ))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: _eventChip(colors, event),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            Row(
              children: [
                SizedBox(
                  width: hourColumn,
                  height: ruler.height,
                  child: Stack(
                    children: [
                      for (
                        var hour = ruler.firstHour;
                        hour < ruler.lastHour;
                        hour++
                      )
                        Positioned(
                          left: 0,
                          right: mobile ? 6 : 9,
                          top: ruler.offset(hour * 60) + 4,
                          child: Text(
                            _time(context, TimeOfDay(hour: hour, minute: 0)),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.muted, fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
                for (var i = 0; i < days.length; i++)
                  Expanded(
                    child: _timelineColumn(
                      context,
                      colors,
                      day: days[i],
                      placements: placements[i],
                      ruler: ruler,
                      now: now,
                      compact: multiDay,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _weekHeading(
    MaterialLocalizations localizations,
    _CalendarColors colors,
    DateTime day,
    DateTime today,
  ) {
    final isToday = DateUtils.isSameDay(day, today);
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.line)),
      ),
      child: Column(
        children: [
          Text(
            _weekday(localizations, day),
            style: TextStyle(color: colors.muted, fontSize: 11),
          ),
          const SizedBox(height: 3),
          Container(
            width: 27,
            height: 27,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isToday ? colors.accent : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Text(
              localizations.formatDecimal(day.day),
              style: TextStyle(
                color: isToday ? colors.onAccent : colors.ink,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineColumn(
    BuildContext context,
    _CalendarColors colors, {
    required DateTime day,
    required List<_TimelinePlacement> placements,
    required _TimelineRuler ruler,
    required DateTime now,
    required bool compact,
  }) {
    const topInset = 2.0;
    final nowOffset = ruler.offset(now.hour * 60 + now.minute);
    final showNow =
        DateUtils.isSameDay(day, now) &&
        nowOffset >= 0 &&
        nowOffset < ruler.height;
    return Container(
      height: ruler.height,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colors.line)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (var hour = ruler.firstHour; hour < ruler.lastHour; hour++)
                Positioned(
                  left: 0,
                  right: 0,
                  top: ruler.offset(hour * 60),
                  child: Divider(height: 1, thickness: 1, color: colors.line),
                ),
              for (final placement in placements)
                Positioned(
                  left: 3 + placement.lane * width / placement.lanes,
                  width: math.max(0, width / placement.lanes - 6),
                  top: ruler.offset(placement.start) + topInset,
                  height:
                      ruler.offset(placement.end) -
                      ruler.offset(placement.start) -
                      topInset * 2,
                  child: _timelineEvent(
                    context,
                    colors,
                    placement.event,
                    compact: compact,
                  ),
                ),
              if (showNow)
                Positioned(
                  left: 0,
                  right: 0,
                  top: nowOffset,
                  child: IgnorePointer(
                    child: Row(
                      children: [
                        _dot(colors.accent, size: 6),
                        Expanded(
                          child: Divider(
                            height: 1,
                            thickness: 1,
                            color: colors.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _timelineEvent(
    BuildContext context,
    _CalendarColors colors,
    CalendarEvent event, {
    required bool compact,
  }) {
    final tone = colors.event(event.category);
    final time = _eventTime(context, event);
    final radius = BorderRadius.circular(5);
    final textScaler = MediaQuery.textScalerOf(context);
    final titleSize = compact ? 11.0 : 13.0;
    final timeSize = compact ? 9.0 : 11.0;
    final twoLineHeight =
        5 + (textScaler.scale(titleSize) + textScaler.scale(timeSize)) * 1.35;
    return Tooltip(
      message: '${event.title}, $time',
      child: Material(
        color: tone.fill,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onEventTap(event),
          child: Container(
            padding: EdgeInsets.only(left: compact ? 4 : 7, right: 3),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: tone.ink, width: 3)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showTime = constraints.maxHeight >= twoLineHeight;
                final showLocation =
                    !compact &&
                    (event.location?.isNotEmpty ?? false) &&
                    constraints.maxHeight >=
                        twoLineHeight + textScaler.scale(10) * 1.35;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: showTime
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    if (showTime) const SizedBox(height: 5),
                    Flexible(
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tone.ink,
                          fontSize: titleSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showTime)
                      Text(
                        time,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tone.ink, fontSize: timeSize),
                      ),
                    if (showLocation)
                      Text(
                        event.location!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tone.ink, fontSize: 10),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _weekAgenda(
    BuildContext context,
    _CalendarColors colors,
    List<DateTime> week,
  ) {
    final localizations = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final day in week) ...[
          Row(
            children: [
              Expanded(
                child: _sectionTitle(
                  colors,
                  localizations.formatMediumDate(day),
                ),
              ),
              IconButton(
                tooltip: 'Open ${localizations.formatFullDate(day)}',
                icon: Icon(
                  Icons.arrow_forward_rounded,
                  size: 17,
                  color: colors.accent,
                ),
                onPressed: () => _openDay(day),
              ),
            ],
          ),
          _eventList(context, colors, _eventsOn(day)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _month(BuildContext context, _CalendarColors colors, bool mobile) {
    final localizations = MaterialLocalizations.of(context);
    final first = DateTime(_date.year, _date.month);
    final start = DateUtils.addDaysToDate(first, 1 - first.weekday);
    final dayCount = DateUtils.getDaysInMonth(_date.year, _date.month);
    final weekCount = ((first.weekday - 1 + dayCount) / 7).ceil();
    final selectedEvents = _eventsOn(_date);
    final previewHeading = _sectionTitle(
      colors,
      localizations.formatMediumDate(_date),
    );
    final openDay = TextButton.icon(
      onPressed: () => _openDay(_date),
      style: TextButton.styleFrom(foregroundColor: colors.accent),
      icon: const Icon(Icons.arrow_forward_rounded, size: 17),
      label: const Text('Open day'),
      iconAlignment: IconAlignment.end,
    );
    final largeText = MediaQuery.textScalerOf(context).scale(15) > 23;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _calendarSurface(
          colors,
          Column(
            children: [
              Row(
                children: [
                  for (final day in _weekContaining(first))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Text(
                          _weekday(localizations, day),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              for (var row = 0; row < weekCount; row++)
                Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(
                        child: _monthDay(
                          context,
                          localizations,
                          colors,
                          DateUtils.addDaysToDate(start, row * 7 + column),
                          mobile: mobile,
                          firstColumn: column == 0,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        if (largeText)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              previewHeading,
              Align(alignment: AlignmentDirectional.centerEnd, child: openDay),
            ],
          )
        else
          Row(
            children: [
              Expanded(child: previewHeading),
              openDay,
            ],
          ),
        _eventList(context, colors, selectedEvents),
      ],
    );
  }

  Widget _monthDay(
    BuildContext context,
    MaterialLocalizations localizations,
    _CalendarColors colors,
    DateTime day, {
    required bool mobile,
    required bool firstColumn,
  }) {
    final inMonth = _date.month == day.month;
    final selected = DateUtils.isSameDay(day, _date);
    final today = DateUtils.isSameDay(day, DateTime.now());
    final events = _eventsOn(day);
    final displayedEvents = events.take(mobile ? 3 : 2);
    final remaining = events.length - displayedEvents.length;
    final dateLabel = localizations.formatFullDate(day);
    final eventCount = events.length == 1
        ? '1 event'
        : '${events.length} events';
    final textScaler = MediaQuery.textScalerOf(context);
    final dayHeight = math.max(25.0, textScaler.scale(12) * 1.35);
    final cellHeight = mobile
        ? math.max(52.0, dayHeight + 24)
        : math.max(86.0, dayHeight + textScaler.scale(10) * 4.1 + 12);
    return Semantics(
      label: '$dateLabel, $eventCount',
      selected: selected,
      button: true,
      excludeSemantics: true,
      onTap: () => widget.onDateChanged(day),
      child: InkWell(
        onTap: () => widget.onDateChanged(day),
        child: Container(
          height: cellHeight,
          padding: EdgeInsets.fromLTRB(mobile ? 3 : 5, 4, mobile ? 3 : 5, 2),
          decoration: BoxDecoration(
            color: selected ? colors.accentFill : null,
            border: Border(
              top: BorderSide(color: colors.line),
              left: firstColumn
                  ? BorderSide.none
                  : BorderSide(color: colors.line),
            ),
          ),
          child: Column(
            crossAxisAlignment: mobile
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Container(
                width: dayHeight,
                height: dayHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: today ? colors.accent : null,
                ),
                child: Text(
                  localizations.formatDecimal(day.day),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: today
                        ? colors.onAccent
                        : inMonth
                        ? colors.ink
                        : colors.muted,
                    fontSize: 12,
                    fontWeight: selected || today
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (mobile) ...[
                const SizedBox(height: 5),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final event in displayedEvents)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: _dot(
                          colors.event(event.category).ink,
                          size: 3.5,
                        ),
                      ),
                    if (remaining > 0)
                      Icon(Icons.add_rounded, size: 9, color: colors.muted),
                  ],
                ),
              ] else ...[
                for (final event in displayedEvents)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        _dot(colors.event(event.category).ink, size: 4),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.ink, fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (remaining > 0)
                  Text(
                    '+$remaining more',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted, fontSize: 9),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _eventList(
    BuildContext context,
    _CalendarColors colors,
    List<CalendarEvent> events,
  ) {
    return _calendarSurface(
      colors,
      events.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 13),
              child: Text(
                'No events scheduled',
                style: TextStyle(color: colors.muted, fontSize: 13),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < events.length; index++) ...[
                  if (index > 0)
                    Divider(
                      color: colors.line,
                      height: 1,
                      indent: 13,
                      endIndent: 13,
                    ),
                  _eventRow(context, colors, events[index]),
                ],
              ],
            ),
    );
  }

  Widget _eventRow(
    BuildContext context,
    _CalendarColors colors,
    CalendarEvent event,
  ) {
    return InkWell(
      onTap: () => widget.onEventTap(event),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            _dot(colors.event(event.category).ink, size: 7),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      _eventTime(context, event),
                      if (event.location?.isNotEmpty ?? false) event.location!,
                    ].join(' · '),
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: colors.muted, size: 19),
          ],
        ),
      ),
    );
  }

  Widget _eventChip(_CalendarColors colors, CalendarEvent event) {
    final tone = colors.event(event.category);
    final radius = BorderRadius.circular(6);
    return Material(
      color: tone.fill,
      borderRadius: radius,
      child: InkWell(
        onTap: () => widget.onEventTap(event),
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Text(
            event.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tone.ink,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

List<DateTime> _weekContaining(DateTime date) {
  final monday = DateUtils.addDaysToDate(date, 1 - date.weekday);
  return List.generate(7, (index) => DateUtils.addDaysToDate(monday, index));
}

const _mobileHourHeight = 53.0;

class _ContinuousDayTimeline extends StatefulWidget {
  const _ContinuousDayTimeline({
    required this.date,
    required this.onDateChanged,
    required this.eventsOn,
    required this.section,
  });

  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final List<CalendarEvent> Function(DateTime) eventsOn;
  final Widget Function(BuildContext, DateTime, GlobalKey) section;

  @override
  State<_ContinuousDayTimeline> createState() => _ContinuousDayTimelineState();
}

class _ContinuousDayTimelineState extends State<_ContinuousDayTimeline> {
  final _viewportKey = GlobalKey();
  final _centerKey = const ValueKey('calendar-current-day-sliver');
  final _keys = <int, ({GlobalKey section, GlobalKey timeline})>{};
  late ScrollController _controller;
  late DateTime _anchor;
  late DateTime _visibleDay;
  bool _placing = false;
  bool _checkScheduled = false;
  double _swipeDistance = 0;

  @override
  void initState() {
    super.initState();
    _positionAt(widget.date, _initialMinute(widget.date));
  }

  @override
  void didUpdateWidget(_ContinuousDayTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.date == oldWidget.date || widget.date == _visibleDay) return;

    final relative = _dateOffset(widget.date, _visibleDay).abs() == 1;
    final minute = relative ? _visibleMinute() : _initialMinute(widget.date);
    final previous = _controller;
    previous.removeListener(_onScroll);
    _positionAt(widget.date, minute);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _TimelineRuler _ruler(DateTime date) => _TimelineRuler(
    _placeEvents(widget.eventsOn(date), date),
    _mobileHourHeight,
    fullDay: true,
  );

  void _positionAt(DateTime date, int minute) {
    _anchor = _visibleDay = date;
    _keys.clear();
    _placing = true;
    final rulerOffset = _ruler(date).offset(minute);
    final controller = ScrollController(
      initialScrollOffset: 36 + rulerOffset,
      keepScrollOffset: false,
    )..addListener(_onScroll);
    _controller = controller;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller != _controller) return;
      final viewport = _topOf(_viewportKey);
      final timeline = _topOf(_keys[0]?.timeline);
      if (controller.hasClients && viewport != null && timeline != null) {
        final offset = controller.offset + timeline - viewport + rulerOffset;
        if ((offset - controller.offset).abs() > .5) controller.jumpTo(offset);
      }
      _placing = false;
    });
  }

  int _initialMinute(DateTime date) {
    final now = DateTime.now();
    return DateUtils.isSameDay(date, now) && now.hour >= 8 && now.hour <= 20
        ? (now.hour - 1) * 60
        : 8 * 60;
  }

  int _visibleMinute() {
    final viewport = _topOf(_viewportKey);
    final timeline = _topOf(_keys[_dateOffset(_visibleDay, _anchor)]?.timeline);
    if (viewport == null || timeline == null) {
      return _initialMinute(_visibleDay);
    }
    return _ruler(_visibleDay).minuteAtOffset(viewport - timeline);
  }

  void _onScroll() {
    if (_placing || _checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || _placing) return;
      final viewport = _topOf(_viewportKey);
      if (viewport == null) return;

      // The date changes as the next day heading reaches the top of the viewport.
      final leadingEdge = viewport + 24;
      for (final entry in _keys.entries) {
        final box = _renderBox(entry.value.section);
        if (box == null) continue;
        final top = box.localToGlobal(Offset.zero).dy;
        if (top > leadingEdge || top + box.size.height <= leadingEdge) continue;
        final date = DateUtils.addDaysToDate(_anchor, entry.key);
        if (date != _visibleDay) {
          _visibleDay = date;
          widget.onDateChanged(date);
        }
        break;
      }
    });
  }

  int _dateOffset(DateTime date, DateTime origin) => DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(origin.year, origin.month, origin.day)).inDays;

  RenderBox? _renderBox(GlobalKey? key) {
    final renderObject = key?.currentContext?.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject
        : null;
  }

  double? _topOf(GlobalKey? key) =>
      _renderBox(key)?.localToGlobal(Offset.zero).dy;

  Widget _daySliver({required bool before}) => SliverPadding(
    key: before ? null : _centerKey,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    sliver: SliverList.builder(
      itemCount: 3660,
      itemBuilder: (context, index) {
        final offset = before ? -index - 1 : index;
        final day = DateUtils.addDaysToDate(_anchor, offset);
        final keys = _keys.putIfAbsent(
          offset,
          () => (section: GlobalKey(), timeline: GlobalKey()),
        );
        return KeyedSubtree(
          key: keys.section,
          child: widget.section(context, day, keys.timeline),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _swipeDistance = 0,
      onHorizontalDragUpdate: (details) => _swipeDistance += details.delta.dx,
      onHorizontalDragEnd: (_) {
        if (_swipeDistance.abs() >= 48) {
          final step = _swipeDistance < 0 ? 1 : -1;
          widget.onDateChanged(DateUtils.addDaysToDate(_visibleDay, step));
        }
      },
      child: RepaintBoundary(
        key: _viewportKey,
        child: CustomScrollView(
          key: ValueKey(_anchor),
          center: _centerKey,
          controller: _controller,
          slivers: [_daySliver(before: true), _daySliver(before: false)],
        ),
      ),
    );
  }
}

String _weekday(MaterialLocalizations localizations, DateTime date) =>
    localizations.narrowWeekdays[date.weekday % 7];

String _eventTime(BuildContext context, CalendarEvent event) {
  if (event.allDay) return 'All day';
  final start = _time(context, TimeOfDay.fromDateTime(event.start.toLocal()));
  final end = _time(context, TimeOfDay.fromDateTime(event.end.toLocal()));
  return '$start–$end';
}

String _time(BuildContext context, TimeOfDay time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

int _minuteOnDay(DateTime time, DateTime day) {
  if (time.isBefore(day)) return 0;
  if (!time.isBefore(DateUtils.addDaysToDate(day, 1))) return 24 * 60;
  final local = time.toLocal();
  return local.hour * 60 + local.minute;
}

List<_TimelinePlacement> _placeEvents(
  List<CalendarEvent> events,
  DateTime day,
) {
  final placements = <_TimelinePlacement>[];
  final lanes = <int>[];
  var groupStart = 0;
  var groupEnd = 0;
  for (final event in events.where((event) => !event.allDay)) {
    final start = _minuteOnDay(event.start, day);
    final end = math.min(
      1440,
      math.max(start + 1, _minuteOnDay(event.end, day)),
    );
    if (groupEnd <= start) {
      for (var index = groupStart; index < placements.length; index++) {
        placements[index].lanes = lanes.length;
      }
      groupStart = placements.length;
      groupEnd = 0;
      lanes.clear();
    }
    var lane = lanes.indexWhere((end) => end <= start);
    if (lane < 0) {
      lane = lanes.length;
      lanes.add(end);
    } else {
      lanes[lane] = end;
    }
    placements.add(_TimelinePlacement(event, start, end, lane));
    groupEnd = math.max(groupEnd, end);
  }
  for (var index = groupStart; index < placements.length; index++) {
    placements[index].lanes = lanes.length;
  }
  return placements;
}

class _TimelinePlacement {
  _TimelinePlacement(this.event, this.start, this.end, this.lane);

  final CalendarEvent event;
  final int start;
  final int end;
  final int lane;
  int lanes = 1;
}

class _TimelineRuler {
  _TimelineRuler(
    Iterable<_TimelinePlacement> events,
    this.hourHeight, {
    bool fullDay = false,
  }) {
    firstHour = fullDay
        ? 0
        : events.fold(8, (hour, event) => math.min(hour, event.start ~/ 60));
    lastHour = fullDay
        ? 24
        : events.fold(
            19,
            (hour, event) => math.max(hour, (event.end / 60).ceil()),
          );
    final eventStartsByEnd = <int, List<int>>{};
    final minutes = {
      for (var hour = firstHour; hour <= lastHour; hour++) hour * 60,
    };
    for (final event in events) {
      minutes.addAll([event.start, event.end]);
      eventStartsByEnd.putIfAbsent(event.end, () => []).add(event.start);
    }
    _minutes = minutes.toList()..sort();
    var previous = _minutes.first;
    for (final minute in _minutes) {
      var position =
          (_offsets[previous] ?? 0) + (minute - previous) * hourHeight / 60;
      for (final start in eventStartsByEnd[minute] ?? const <int>[]) {
        // Expand short events at the same anchors as the time labels and now marker.
        position = math.max(position, _offsets[start]! + 26);
      }
      _offsets[minute] = position;
      previous = minute;
    }
  }

  final double hourHeight;
  late final int firstHour;
  late final int lastHour;
  late final List<int> _minutes;
  final _offsets = <int, double>{};

  double get height => _offsets[_minutes.last]!;

  double offset(int minute) {
    final exact = _offsets[minute];
    if (exact != null) return exact;
    if (minute < _minutes.first) return -1;
    if (minute > _minutes.last) return height;
    final index = _minutes.indexWhere((anchor) => anchor > minute);
    final before = _minutes[index - 1];
    final after = _minutes[index];
    final progress = (minute - before) / (after - before);
    return _offsets[before]! +
        (_offsets[after]! - _offsets[before]!) * progress;
  }

  int minuteAtOffset(double position) {
    if (position <= 0) return _minutes.first;
    if (position >= height) return _minutes.last;
    final index = _minutes.indexWhere(
      (minute) => _offsets[minute]! >= position,
    );
    final before = _minutes[index - 1];
    final after = _minutes[index];
    final progress =
        (position - _offsets[before]!) / (_offsets[after]! - _offsets[before]!);
    return (before + (after - before) * progress).round();
  }
}

Widget _sectionTitle(_CalendarColors colors, String label) => Text(
  label,
  style: TextStyle(
    color: colors.ink,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  ),
);

Widget _dot(Color color, {double size = 5}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
);

Widget _calendarSurface(_CalendarColors colors, Widget child) => Material(
  color: colors.surface,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(11),
    side: BorderSide(color: colors.line),
  ),
  clipBehavior: Clip.antiAlias,
  child: child,
);

class _CalendarColors {
  const _CalendarColors(this.dark);

  factory _CalendarColors.of(BuildContext context) =>
      _CalendarColors(Theme.of(context).brightness == Brightness.dark);

  final bool dark;

  Color get surface => dark ? const Color(0xFF222623) : Colors.white;
  Color get ink => dark ? const Color(0xFFF0F1EC) : const Color(0xFF202521);
  Color get muted => dark ? const Color(0xFFAAB2A7) : const Color(0xFF696E66);
  Color get line => dark ? const Color(0xFF393F39) : const Color(0xFFE9E8E1);
  Color get accent => dark ? const Color(0xFFA4C3A9) : const Color(0xFF466955);
  Color get onAccent => dark ? const Color(0xFF17231B) : Colors.white;
  Color get accentFill =>
      dark ? const Color(0xFF303F33) : const Color(0xFFEDF2EC);

  ({Color ink, Color fill}) event(String category) {
    return switch (category.toLowerCase()) {
      'work' =>
        dark
            ? (ink: const Color(0xFFB7C8DF), fill: const Color(0xFF303A49))
            : (ink: const Color(0xFF435B78), fill: const Color(0xFFEAF0F7)),
      'study' =>
        dark
            ? (ink: const Color(0xFFCCC0E0), fill: const Color(0xFF3E354C))
            : (ink: const Color(0xFF625078), fill: const Color(0xFFF0EBF6)),
      'health' =>
        dark
            ? (ink: const Color(0xFFE1B8AC), fill: const Color(0xFF49352E))
            : (ink: const Color(0xFF884F41), fill: const Color(0xFFF8EBE6)),
      _ => (ink: accent, fill: accentFill),
    };
  }
}
