import 'dart:math' as math;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'calendar_event_index.dart';
import 'ui_theme.dart' as palette;
import 'workspace_data.dart' show spaceColor;

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.category,
    this.allDay = false,
    this.location,
    this.plannedTaskId,
    this.sourceLabel,
    this.description,
    this.color,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String category;
  final bool allDay;
  final String? location;
  final String? plannedTaskId;
  final String? sourceLabel;
  final String? description;
  final Color? color;
  bool get isReadOnly => sourceLabel != null;
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.date,
    required this.onDateChanged,
    required this.events,
    required this.onEventTap,
    this.eventsRevision,
    super.key,
  });

  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;

  /// Change this when the event snapshot changes. When omitted, a new list
  /// instance is treated as a new snapshot.
  final Object? eventsRevision;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late CalendarEventIndex<CalendarEvent> _eventIndex;
  late int _indexedEventCount;

  DateTime get _date => DateUtils.dateOnly(widget.date);

  @override
  void initState() {
    super.initState();
    _indexEvents();
  }

  @override
  void didUpdateWidget(CalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.eventsRevision ?? oldWidget.events) !=
            (widget.eventsRevision ?? widget.events) ||
        widget.events.length != _indexedEventCount) {
      _indexEvents();
    }
  }

  void _indexEvents() {
    _indexedEventCount = widget.events.length;
    _eventIndex = CalendarEventIndex(
      widget.events,
      startOf: (event) => event.start,
      endOf: (event) => event.end,
    );
  }

  List<CalendarEvent> _eventsOn(DateTime day) => _eventIndex.onDay(day);

  void _step(int days) =>
      widget.onDateChanged(DateUtils.addDaysToDate(_date, days));

  void _today() => widget.onDateChanged(DateUtils.dateOnly(DateTime.now()));

  Future<void> _jumpToDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 100),
      lastDate: DateTime(_date.year + 100, 12, 31),
    );
    if (mounted && date != null) widget.onDateChanged(date);
  }

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final colors = _CalendarColors.of(context);
    final inset = mobile ? 28.0 : 48.0;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            _step(-7),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            _step(7),
        const SingleActivator(LogicalKeyboardKey.home, alt: true): _today,
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showWeek = !mobile && constraints.maxWidth - 2 * inset >= 652;
          final allDay = showWeek
              ? const <CalendarEvent>[]
              : _eventsOn(_date).where((event) => event.allDay);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  mobile ? 8 : 32,
                  inset,
                  mobile ? 10 : 22,
                ),
                child: _dateHeading(context, colors, mobile),
              ),
              if (allDay.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      child: _allDayStrip(colors, allDay),
                    ),
                  ),
                ),
              Expanded(
                child: showWeek
                    ? SingleChildScrollView(
                        key: const PageStorageKey('calendar-week-schedule'),
                        padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
                        child: _timeline(
                          context,
                          colors,
                          _weekContaining(_date),
                        ),
                      )
                    : _ContinuousDayTimeline(
                        date: _date,
                        inset: inset,
                        onDateChanged: widget.onDateChanged,
                        eventsOn: _eventsOn,
                        section: (context, date, timelineKey) =>
                            _daySection(context, colors, date, timelineKey),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dateHeading(
    BuildContext context,
    _CalendarColors colors,
    bool mobile,
  ) {
    final localizations = MaterialLocalizations.of(context);
    final spokenDate = localizations.formatFullDate(_date);
    final displayDate = mobile
        ? localizations.formatMediumDate(_date)
        : spokenDate;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        header: true,
        button: true,
        label: spokenDate,
        hint: 'Choose a date',
        excludeSemantics: true,
        onTap: _jumpToDate,
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Previous day'): () => _step(-1),
          const CustomSemanticsAction(label: 'Next day'): () => _step(1),
          const CustomSemanticsAction(label: 'Today'): _today,
        },
        child: InkWell(
          key: const ValueKey('calendar-date'),
          onTap: _jumpToDate,
          borderRadius: BorderRadius.circular(5),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: Text(
                displayDate,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: mobile ? 25 : 34,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: mobile ? -.75 : -1.05,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _daySection(
    BuildContext context,
    _CalendarColors colors,
    DateTime date,
    GlobalKey timelineKey,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 0, 10),
            child: Semantics(
              header: true,
              child: Text(
                MaterialLocalizations.of(context).formatMediumDate(date),
                style: TextStyle(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          _timeline(context, colors, [date], timelineKey: timelineKey),
        ],
      ),
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
      multiDay ? 57 : _dayHourHeight,
      fullDay: !multiDay,
    );
    final hourColumn = multiDay ? 62.0 : 50.0;
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
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: hourColumn),
                    for (final day in days)
                      Expanded(child: _weekHeading(localizations, colors, day)),
                  ],
                ),
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
                          right: multiDay ? 10 : 8,
                          top: ruler.offset(hour * 60) + 5,
                          child: Text(
                            _time(context, TimeOfDay(hour: hour, minute: 0)),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 11,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
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
  ) {
    final selected = DateUtils.isSameDay(day, _date);
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: () => widget.onDateChanged(day),
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? colors.accentFill : Colors.transparent,
            border: Border(left: BorderSide(color: colors.line)),
          ),
          child: Text(
            localizations.formatMediumDate(day),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? colors.accent : colors.muted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ),
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
    final tone = colors.event(event);
    final time = _eventTime(context, event);
    final radius = BorderRadius.circular(7);
    final textScaler = MediaQuery.textScalerOf(context);
    final titleSize = compact ? 11.0 : 13.5;
    final timeSize = compact ? 10.0 : 11.0;
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
            padding: EdgeInsets.only(left: compact ? 4 : 8, right: 4),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: tone.edge, width: 2)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showTime = constraints.maxHeight >= twoLineHeight;
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
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _eventChip(_CalendarColors colors, CalendarEvent event) {
    final tone = colors.event(event);
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

const _dayHourHeight = 53.0;

class _ContinuousDayTimeline extends StatefulWidget {
  const _ContinuousDayTimeline({
    required this.date,
    required this.inset,
    required this.onDateChanged,
    required this.eventsOn,
    required this.section,
  });

  final DateTime date;
  final double inset;
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
    _dayHourHeight,
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
    padding: EdgeInsets.symmetric(horizontal: widget.inset),
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

  Color get surface => dark ? palette.shellSurface : palette.raisedPaper;
  Color get ink => dark ? const Color(0xFFF0F1EC) : palette.ink;
  Color get muted => dark ? const Color(0xFFAAB2A7) : palette.muted;
  Color get line => dark ? const Color(0xFF393F39) : palette.line;
  Color get accent => dark ? const Color(0xFFA4C3A9) : palette.accent;
  Color get accentFill => dark ? const Color(0xFF303F33) : palette.softAccent;

  ({Color ink, Color fill, Color edge}) event(CalendarEvent event) {
    final hue = event.color ?? spaceColor(event.category);
    final fill = Color.alphaBlend(
      hue.withValues(alpha: dark ? .24 : .09),
      dark ? surface : palette.paper,
    );
    final label = Color.lerp(ink, hue, dark ? .36 : .68)!;
    return (
      ink: event.color != null && _contrast(label, fill) < 4.5 ? ink : label,
      fill: fill,
      edge: dark ? Color.lerp(ink, hue, .66)! : hue,
    );
  }

  double _contrast(Color foreground, Color background) {
    final first = Color.alphaBlend(foreground, background).computeLuminance();
    final second = background.computeLuminance();
    return (math.max(first, second) + .05) / (math.min(first, second) + .05);
  }
}
