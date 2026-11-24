import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance/appearance.dart' show readableTint;
import 'calendar_event_index.dart';
import 'categories/category_palette.dart';
import 'categories/workspace_categories.dart';

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.category,
    this.allDay = false,
    this.blocksTime = true,
    this.location,
    this.savedPlaceId,
    this.plannedTaskId,
    this.initialPlannedStart,
    this.initialPlannedEnd,
    this.recurringSeriesId,
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
  final bool blocksTime;
  final String? location;
  final String? savedPlaceId;
  final String? plannedTaskId;
  final DateTime? initialPlannedStart;
  final DateTime? initialPlannedEnd;
  final String? recurringSeriesId;
  final String? sourceLabel;
  final String? description;
  final Color? color;
  bool get isReadOnly => sourceLabel != null;

  CalendarEvent withPlace(String? placeId) => CalendarEvent(
    id: id,
    title: title,
    start: start,
    end: end,
    category: category,
    allDay: allDay,
    blocksTime: blocksTime,
    location: location,
    savedPlaceId: placeId,
    plannedTaskId: plannedTaskId,
    initialPlannedStart: initialPlannedStart,
    initialPlannedEnd: initialPlannedEnd,
    recurringSeriesId: recurringSeriesId,
    sourceLabel: sourceLabel,
    description: description,
    color: color,
  );
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.date,
    required this.onDateChanged,
    required this.events,
    required this.onEventTap,
    this.onCreateTimedEvent,
    this.eventsRevision,
    super.key,
  });

  final DateTime date;
  final ValueChanged<DateTime> onDateChanged;
  final List<CalendarEvent> events;
  final ValueChanged<CalendarEvent> onEventTap;

  /// Opens an event draft for a range selected in the desktop timeline.
  final ValueChanged<DateTimeRange>? onCreateTimedEvent;

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
                          onCreateTimedEvent: widget.onCreateTimedEvent,
                        ),
                      )
                    : _ContinuousDayTimeline(
                        date: _date,
                        inset: inset,
                        onDateChanged: widget.onDateChanged,
                        eventsOn: _eventsOn,
                        section: (context, date, timelineKey) => _daySection(
                          context,
                          colors,
                          date,
                          timelineKey,
                          onCreateTimedEvent: mobile
                              ? null
                              : widget.onCreateTimedEvent,
                        ),
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
    GlobalKey timelineKey, {
    ValueChanged<DateTimeRange>? onCreateTimedEvent,
  }) {
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
          _timeline(
            context,
            colors,
            [date],
            timelineKey: timelineKey,
            onCreateTimedEvent: onCreateTimedEvent,
          ),
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
    ValueChanged<DateTimeRange>? onCreateTimedEvent,
  }) {
    final multiDay = days.length > 1;
    final daysEvents = days.map(_eventsOn).toList();
    final axes = [for (final day in days) _DayAxis(day, elapsed: !multiDay)];
    final placements = [
      for (var index = 0; index < days.length; index++)
        _placeEvents(daysEvents[index], axes[index]),
    ];
    final ruler = _TimelineRuler(
      placements.expand((day) => day),
      multiDay ? 57 : _dayHourHeight,
      fullDay: multiDay ? null : axes.single,
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
                      for (final mark in ruler.marks)
                        Positioned(
                          left: 0,
                          right: multiDay ? 10 : 8,
                          top: ruler.offset(mark.minute) + 5,
                          child: _timelineTick(
                            context,
                            colors,
                            mark,
                            compact: !multiDay,
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
                      axis: axes[i],
                      placements: placements[i],
                      ruler: ruler,
                      now: now,
                      compact: multiDay,
                      onCreateTimedEvent: onCreateTimedEvent,
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
              color: selected ? colors.onAccentFill : colors.muted,
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
    required _DayAxis axis,
    required List<_TimelinePlacement> placements,
    required _TimelineRuler ruler,
    required DateTime now,
    required bool compact,
    required ValueChanged<DateTimeRange>? onCreateTimedEvent,
  }) {
    const topInset = 2.0;
    final nowOffset = ruler.offset(axis.position(now));
    final showNow =
        DateUtils.isSameDay(axis.date, now) &&
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
              for (final mark in ruler.marks)
                Positioned(
                  left: 0,
                  right: 0,
                  top: ruler.offset(mark.minute),
                  child: Divider(height: 1, thickness: 1, color: colors.line),
                ),
              if (onCreateTimedEvent != null)
                Positioned.fill(
                  child: _DesktopTimeSelection(
                    key: ValueKey(('calendar-selection', axis.date)),
                    axis: axis,
                    ruler: ruler,
                    colors: colors,
                    onSelected: onCreateTimedEvent,
                  ),
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
    final (time, accessibleTime) = _eventTime(context, event);
    final radius = BorderRadius.circular(7);
    final textScaler = MediaQuery.textScalerOf(context);
    final titleSize = compact ? 11.0 : 13.5;
    final timeSize = compact ? 10.0 : 11.0;
    final twoLineHeight =
        5 + (textScaler.scale(titleSize) + textScaler.scale(timeSize)) * 1.35;
    return Tooltip(
      message: '${event.title}, $accessibleTime',
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

class _DesktopTimeSelection extends StatefulWidget {
  const _DesktopTimeSelection({
    required this.axis,
    required this.ruler,
    required this.colors,
    required this.onSelected,
    super.key,
  });

  final _DayAxis axis;
  final _TimelineRuler ruler;
  final _CalendarColors colors;
  final ValueChanged<DateTimeRange> onSelected;

  @override
  State<_DesktopTimeSelection> createState() => _DesktopTimeSelectionState();
}

class _DesktopTimeSelectionState extends State<_DesktopTimeSelection> {
  int? _anchor;
  int? _edge;

  @override
  void didUpdateWidget(_DesktopTimeSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ruler != widget.ruler) _anchor = _edge = null;
  }

  int _minuteAt(double y) {
    const step = 15;
    final ruler = widget.ruler;
    final minute = (ruler.minuteAtOffset(y) / step).round() * step;
    return minute
        .clamp(ruler.minuteAtOffset(0), ruler.minuteAtOffset(ruler.height))
        .toInt();
  }

  ({int start, int end})? _span(int? edge) {
    final anchor = _anchor;
    if (anchor == null || edge == null || anchor == edge) return null;
    return (start: math.min(anchor, edge), end: math.max(anchor, edge));
  }

  DateTimeRange? _range(({int start, int end}) span) {
    final start = widget.axis.instantAt(span.start);
    final end = widget.axis.instantAt(span.end);
    return start == null || end == null || !end.isAfter(start)
        ? null
        : DateTimeRange(start: start, end: end);
  }

  void _cancel() {
    if (_anchor == null) return;
    setState(() => _anchor = _edge = null);
  }

  void _finish(DragEndDetails details) {
    final span = _span(_minuteAt(details.localPosition.dy));
    _cancel();
    if (span == null) return;
    final range = _range(span);
    if (range != null) widget.onSelected(range);
  }

  @override
  Widget build(BuildContext context) {
    final span = _span(_edge);
    return Listener(
      // An accepted Flutter drag also reports an end after a pointer cancel.
      onPointerCancel: (event) {
        if (event.kind == PointerDeviceKind.mouse) _cancel();
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          supportedDevices: const {PointerDeviceKind.mouse},
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: (details) =>
              _anchor = _edge = _minuteAt(details.localPosition.dy),
          onVerticalDragUpdate: (details) {
            if (_anchor == null) return;
            final minute = _minuteAt(details.localPosition.dy);
            if (minute != _edge) setState(() => _edge = minute);
          },
          onVerticalDragEnd: _finish,
          onVerticalDragCancel: _cancel,
          child: Stack(
            fit: StackFit.expand,
            children: [if (span != null) _preview(context, span)],
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, ({int start, int end}) span) {
    final start = widget.ruler.offset(span.start);
    final end = widget.ruler.offset(span.end);
    final height = math.max(0.0, end - start - 4);
    final range = _range(span);
    final color = range == null ? widget.colors.muted : widget.colors.accent;
    return Positioned(
      left: 3,
      right: 3,
      top: start + 2,
      height: height,
      child: DecoratedBox(
        key: const ValueKey('calendar-selection-preview'),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .14),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(7),
        ),
        child: height >= 34
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  range == null
                      ? 'Choose another time'
                      : '${_time(context, TimeOfDay.fromDateTime(range.start))}'
                            '–${_time(context, TimeOfDay.fromDateTime(range.end))}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 11),
                ),
              )
            : null,
      ),
    );
  }
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
    _positionAt(widget.date, _initialClock(widget.date));
  }

  @override
  void didUpdateWidget(_ContinuousDayTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.date == oldWidget.date || widget.date == _visibleDay) return;

    final relative = _dateOffset(widget.date, _visibleDay).abs() == 1;
    final clock = relative ? _visibleClock() : _initialClock(widget.date);
    final previous = _controller;
    previous.removeListener(_onScroll);
    _positionAt(widget.date, clock);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _TimelineRuler _ruler(_DayAxis axis) => _TimelineRuler(
    _placeEvents(widget.eventsOn(axis.date), axis),
    _dayHourHeight,
    fullDay: axis,
  );

  void _positionAt(DateTime date, _WallClock clock) {
    _anchor = _visibleDay = date;
    _keys.clear();
    _placing = true;
    final axis = _DayAxis(date, elapsed: true);
    final rulerOffset = _ruler(axis).offset(axis.positionOfClock(clock));
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

  _WallClock _initialClock(DateTime date) {
    final now = DateTime.now();
    final minute =
        DateUtils.isSameDay(date, now) && now.hour >= 8 && now.hour <= 20
        ? (now.hour - 1) * 60
        : 8 * 60;
    return (minute: minute, offset: now.timeZoneOffset);
  }

  _WallClock _visibleClock() {
    final viewport = _topOf(_viewportKey);
    final timeline = _topOf(_keys[_dateOffset(_visibleDay, _anchor)]?.timeline);
    if (viewport == null || timeline == null) {
      return _initialClock(_visibleDay);
    }
    final axis = _DayAxis(_visibleDay, elapsed: true);
    final position = _ruler(axis).minuteAtOffset(viewport - timeline);
    return axis.clockAt(position);
  }

  void _onScroll() {
    if (_placing || _checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || _placing) return;
      final viewport = _topOf(_viewportKey);
      if (viewport == null) return;

      // The slivers have finalized their children before this callback.
      _keys.removeWhere((_, keys) => keys.section.currentContext == null);

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

(String, String) _eventTime(BuildContext context, CalendarEvent event) {
  final start = event.start.toLocal();
  final end = event.end.toLocal();
  final from = _time(context, TimeOfDay.fromDateTime(start));
  final until = _time(context, TimeOfDay.fromDateTime(end));
  if (start.timeZoneOffset == end.timeZoneOffset &&
      !_repeatedClockTime(start) &&
      !_repeatedClockTime(end)) {
    return ('$from–$until', '$from–$until');
  }
  return (
    '$from ${start.timeZoneName}–$until ${end.timeZoneName}',
    '$from ${_utcOffset(start.timeZoneOffset)} – '
        '$until ${_utcOffset(end.timeZoneOffset)}',
  );
}

String _time(BuildContext context, TimeOfDay time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

Widget _timelineTick(
  BuildContext context,
  _CalendarColors colors,
  _TimelineMark mark, {
  required bool compact,
}) {
  final fullTime = _time(context, mark.time);
  final visibleTime = compact
      ? _mobileAxisTime(context, mark.time, fullTime)
      : fullTime;
  final repeated = mark.repeatedAt;
  return Text(
    repeated == null ? visibleTime : '$visibleTime\n${repeated.timeZoneName}',
    semanticsLabel: repeated == null
        ? compact
              ? fullTime
              : null
        : '$fullTime, ${_utcOffset(repeated.timeZoneOffset)}',
    textAlign: TextAlign.right,
    maxLines: repeated == null ? null : 2,
    overflow: compact ? TextOverflow.clip : TextOverflow.ellipsis,
    style: TextStyle(
      color: colors.muted,
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

String _mobileAxisTime(BuildContext context, TimeOfDay time, String fullTime) {
  if (time.minute != 0 || MediaQuery.alwaysUse24HourFormatOf(context)) {
    return fullTime;
  }
  final localizations = MaterialLocalizations.of(context);
  final format = localizations.timeOfDayFormat();
  if (format != TimeOfDayFormat.h_colon_mm_space_a &&
      format != TimeOfDayFormat.a_space_h_colon_mm) {
    return fullTime;
  }
  final hour = localizations.formatHour(time);
  final period = time.period == DayPeriod.am
      ? localizations.anteMeridiemAbbreviation
      : localizations.postMeridiemAbbreviation;
  return format == TimeOfDayFormat.h_colon_mm_space_a
      ? '$hour $period'
      : '$period $hour';
}

String _utcOffset(Duration offset) {
  final sign = offset.isNegative ? '−' : '+';
  final absolute = offset.abs();
  final hours = absolute.inHours.toString().padLeft(2, '0');
  final minutes = (absolute.inMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$minutes';
}

bool _repeatedClockTime(DateTime time) {
  final axis = _DayAxis(DateUtils.dateOnly(time), elapsed: true);
  final shift = axis.startOffset - axis.endOffset;
  if (shift <= Duration.zero) return false;
  final other = time.add(
    time.timeZoneOffset == axis.startOffset ? shift : -shift,
  );
  return DateUtils.isSameDay(time, other) &&
      time.hour == other.hour &&
      time.minute == other.minute;
}

typedef _WallClock = ({int minute, Duration? offset});
typedef _TimelineMark = ({int minute, TimeOfDay time, DateTime? repeatedAt});

class _DayAxis {
  _DayAxis(this.date, {required this.elapsed})
    : end = DateUtils.addDaysToDate(date, 1);

  final DateTime date;
  final DateTime end;
  final bool elapsed;
  static const _civilMinutes = 24 * 60;

  late final Duration startOffset = date.timeZoneOffset;
  late final Duration endOffset = end
      .subtract(const Duration(microseconds: 1))
      .timeZoneOffset;
  late final int actualMinutes = end.difference(date).inMinutes;
  late final int minutes = elapsed ? actualMinutes : _civilMinutes;

  DateTime _instant(int minute) => date.add(Duration(minutes: minute));

  DateTime? instantAt(int minute) {
    if (minute == minutes) return end;
    if (elapsed) return _instant(minute);
    final local = DateTime(date.year, date.month, date.day, 0, minute);
    // A shared week ruler cannot tell the two occurrences of a wall time apart.
    return position(local) == minute && !_repeatedClockTime(local)
        ? local
        : null;
  }

  int position(DateTime time) {
    if (time.isBefore(date)) return 0;
    if (!time.isBefore(end)) return minutes;
    if (elapsed) return time.difference(date).inMinutes;
    final local = time.toLocal();
    return local.hour * 60 + local.minute;
  }

  _WallClock clockAt(int minute) {
    if (minute >= minutes) return (minute: _civilMinutes, offset: null);
    final local = _instant(minute);
    return (
      minute: local.hour * 60 + local.minute,
      offset: local.timeZoneOffset,
    );
  }

  int positionOfClock(_WallClock clock) {
    if (clock.minute >= _civilMinutes) return minutes;
    if (clock.offset case final preferred?) {
      final instant = _wallWithOffset(clock.minute, preferred);
      if (instant.timeZoneOffset == preferred) return position(instant);
    }
    return position(DateTime(date.year, date.month, date.day, 0, clock.minute));
  }

  DateTime _wallWithOffset(int minute, Duration offset) => DateTime.utc(
    date.year,
    date.month,
    date.day,
    0,
    minute,
  ).subtract(offset).toLocal();

  List<_TimelineMark> marks() {
    final first = startOffset;
    final last = endOffset;
    if (first == last && actualMinutes == _civilMinutes) {
      return [for (var hour = 0; hour < 24; hour++) _hourMark(hour)];
    }

    final offsets = {first, last};
    final instants = {0: date};
    for (var hour = 0; hour < 24; hour++) {
      for (final offset in offsets) {
        final candidate = _wallWithOffset(hour * 60, offset);
        if (candidate.timeZoneOffset == offset &&
            !candidate.isBefore(date) &&
            candidate.isBefore(end)) {
          instants[position(candidate)] = candidate;
        }
      }
    }
    if (first != last) {
      // Include the boundary even when the new clock starts on a half hour.
      var low = 0;
      var high = minutes;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (_instant(mid).timeZoneOffset == first) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      if (low < minutes) instants[low] = _instant(low);
    }

    final sorted = instants.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final counts = <TimeOfDay, int>{};
    for (final instant in instants.values) {
      final time = TimeOfDay.fromDateTime(instant);
      counts.update(time, (count) => count + 1, ifAbsent: () => 1);
    }
    return sorted.map((entry) {
      final time = TimeOfDay.fromDateTime(entry.value);
      return (
        minute: entry.key,
        time: time,
        repeatedAt: counts[time]! > 1 ? entry.value : null,
      );
    }).toList();
  }
}

_TimelineMark _hourMark(int hour) => (
  minute: hour * 60,
  time: TimeOfDay(hour: hour, minute: 0),
  repeatedAt: null,
);

List<_TimelinePlacement> _placeEvents(
  List<CalendarEvent> events,
  _DayAxis axis,
) {
  final spans = [
    for (final (order, event) in events.indexed)
      if (!event.allDay)
        (event: event, start: axis.position(event.start), order: order),
  ];
  if (!axis.elapsed && axis.startOffset > axis.endOffset) {
    // A civil week column can have a later instant with an earlier clock time.
    spans.sort((a, b) {
      final comparison = a.start.compareTo(b.start);
      return comparison == 0 ? a.order.compareTo(b.order) : comparison;
    });
  }
  final placements = <_TimelinePlacement>[];
  final lanes = <int>[];
  var groupStart = 0;
  var groupEnd = 0;
  for (final span in spans) {
    final event = span.event;
    final start = span.start;
    final end = math.min(
      axis.minutes,
      math.max(start + 1, axis.position(event.end)),
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
    _DayAxis? fullDay,
  }) {
    final int endMinute;
    if (fullDay != null) {
      marks = fullDay.marks();
      endMinute = fullDay.minutes;
    } else {
      final firstHour = events.fold(
        8,
        (hour, event) => math.min(hour, event.start ~/ 60),
      );
      final lastHour = events.fold(
        19,
        (hour, event) => math.max(hour, (event.end / 60).ceil()),
      );
      marks = [
        for (var hour = firstHour; hour < lastHour; hour++) _hourMark(hour),
      ];
      endMinute = lastHour * 60;
    }
    final eventStartsByEnd = <int, List<int>>{};
    final minutes = {for (final mark in marks) mark.minute, endMinute};
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
  late final List<_TimelineMark> marks;
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
  const _CalendarColors(this.scheme, this.categories);

  factory _CalendarColors.of(BuildContext context) => _CalendarColors(
    Theme.of(context).colorScheme,
    WorkspaceCategoryPalette.of(context),
  );

  final ColorScheme scheme;
  final WorkspaceCategories categories;

  bool get dark => scheme.brightness == Brightness.dark;
  Color get surface => scheme.surfaceContainerLow;
  Color get ink => scheme.onSurface;
  Color get muted => scheme.onSurfaceVariant;
  Color get line => scheme.outlineVariant;
  Color get accent => scheme.primary;
  Color get accentFill => scheme.primaryContainer;
  Color get onAccentFill => readableTint(
    accent,
    surface: accentFill,
    foreground: scheme.onPrimaryContainer,
  );

  ({Color ink, Color fill, Color edge}) event(CalendarEvent event) {
    final hue =
        event.color ??
        switch (categories.colorArgbFor(event.category)) {
          final value? => Color(value),
          _ => accent,
        };
    final fill = Color.alphaBlend(
      hue.withValues(alpha: dark ? .24 : .09),
      dark ? surface : scheme.surface,
    );
    final label = Color.lerp(ink, hue, dark ? .36 : .68)!;
    return (
      ink: readableTint(label, surface: fill, foreground: ink),
      fill: fill,
      edge: readableTint(
        dark ? Color.lerp(ink, hue, .66)! : hue,
        surface: fill,
        foreground: ink,
        minimumContrast: 3,
      ),
    );
  }
}
