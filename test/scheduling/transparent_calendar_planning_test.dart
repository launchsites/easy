import 'package:easy/calendar_page.dart';
import 'package:easy/review/review.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/future_block_removal.dart';
import 'package:easy/scheduling/manual_time_block.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/task_objective_availability.dart';
import 'package:easy/scheduling/task_objective_review.dart';
import 'package:easy/scheduling/task_reservations.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 11, 24);
DateTime _at(int hour, [int minute = 0]) =>
    DateTime(_day.year, _day.month, _day.day, hour, minute);

CalendarEvent _event(
  String id,
  DateTime start,
  DateTime end, {
  bool blocksTime = true,
  bool allDay = false,
  String? place,
  String? task,
}) => CalendarEvent(
  id: id,
  title: id,
  start: start,
  end: end,
  category: 'personal',
  blocksTime: blocksTime,
  allDay: allDay,
  savedPlaceId: place,
  plannedTaskId: task,
);

TaskItem _task(String id, {int estimate = 30}) =>
    TaskItem(id: id, title: id, category: 'work', estimatedMinutes: estimate);

SchedulingSettings _settings({int before = 0, int after = 0}) =>
    SchedulingSettings(
      availability: [
        WeeklyAvailability(
          id: 'saved-hours',
          weekdays: [_day.weekday],
          startMinute: 9 * 60,
          endMinute: 13 * 60,
          categories: ['work'],
        ),
      ],
      beforeMinutes: before,
      afterMinutes: after,
      places: [
        SavedPlace(id: 'office', name: 'Office'),
        SavedPlace(id: 'other', name: 'Other place'),
      ],
    );

void main() {
  test('verified objective gaps ignore free intervals, buffers and travel', () {
    final settings = _settings(before: 10, after: 5);
    final free = _event(
      'Studio reminder',
      _at(9),
      _at(11, 30),
      blocksTime: false,
      place: 'other',
      task: 'send',
    );
    final previous = _event('Earlier meeting', _at(7), _at(8), place: 'office');
    final busy = _event('Meeting', _at(11), _at(12), place: 'office');
    final events = [previous, free, busy];
    final tasks = [_task('send'), _task('edit', estimate: 60)];
    final availability = deriveTaskObjectiveAvailability(
      now: _at(10),
      horizonEnd: _at(13),
      settings: settings,
      confirmedEvents: events,
      categories: ['work'],
      verifiedCalendarSpan: TimeSpan(_at(0), _at(24)),
    );
    expect(availability.byCategory, {'work': const Duration(minutes: 50)});
    final review = reviewTaskObjectives(
      tasks: tasks,
      events: events,
      now: _at(10),
      horizonEnd: _at(13),
      verifiedAvailability: availability,
    );
    expect(review.ready.single.id, 'send');
    expect(review.ready.single.fit, ObjectiveFit.complete);
    expect(review.ready.single.reservedEffort, Duration.zero);
    expect(review.later.single.fit, ObjectiveFit.needsMoreTime);
  });

  test('accepted work remains one active reservation beside a free row', () {
    final busy = _event('Accepted time', _at(9, 45), _at(10, 45), task: 'send');
    final free = _event(
      'Another reminder',
      _at(9, 45),
      _at(10, 45),
      blocksTime: false,
      task: 'other',
    );
    final events = [busy, free];
    final tasks = [_task('send'), _task('other')];
    final review = reviewTaskObjectives(
      tasks: tasks,
      events: events,
      now: _at(10),
      horizonEnd: _at(13),
      workWindow: TimeSpan(_at(10), _at(13)),
    );
    expect(review.ready.single.id, 'send');
    expect(review.ready.single.inReservedTime, isTrue);
    final reservations = reviewTaskReservations(
      tasks: tasks,
      events: events,
      cutoff: _at(10),
    );
    expect(reservations.reservations.keys, ['send']);
    expect(reservations.satisfiesAt('send', _at(10, 30)), isTrue);
    expect(reservations.satisfiesAt('other', _at(10, 45)), isFalse);
  });

  test('daily review lists free rows and charges only blocking time', () {
    final free = _event(
      'Read the announcement',
      _at(9, 30),
      _at(10, 30),
      blocksTime: false,
      place: 'other',
    );
    final holiday = _event(
      'Holiday in another country',
      _at(0),
      _at(24),
      allDay: true,
      blocksTime: false,
    );
    final busy = _event('Meeting', _at(11), _at(12), place: 'office');
    final events = [holiday, free, busy];
    final settings = _settings(before: 10, after: 5);
    ReviewDayAvailability? availability(List<CalendarEvent> rows) =>
        deriveReviewDayAvailability(
          day: _day,
          settings: settings,
          categories: ['work'],
          events: rows,
          calendarComplete: true,
        );

    final freeTime = availability(events)!;
    expect(freeTime.hasAllDayCommitment, isFalse);
    expect(freeTime.travelIssues, isEmpty);
    expect(
      freeTime.windows.map((row) => (row.start.toLocal(), row.end.toLocal())),
      [(_at(9), _at(10, 50)), (_at(12, 5), _at(13))],
    );
    final brief = ReviewAgenda(
      events: [
        for (final event in events)
          ReviewEvent(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
            allDay: event.allDay,
            blocksTime: event.blocksTime,
          ),
      ],
      availability: freeTime.windows,
    ).forDay(_day);
    expect(brief.events.map((row) => row.id), events.map((row) => row.id));
    expect(brief.scheduledMinutes, 60);
    expect(brief.freeMinutes, 165);

    final closed = availability([
      ...events,
      _event('Away all day', _at(0), _at(24), allDay: true),
    ])!;
    expect(closed.hasAllDayCommitment, isTrue);
    expect(closed.windows, isEmpty);
  });

  test('day and week can plan across a free appointment', () {
    final free = _event('Reminder', _at(10), _at(13), blocksTime: false);
    final busy = _event('Meeting', _at(10, 30), _at(11, 15));
    final tasks = [_task('send', estimate: 45)];
    final settings = _settings();
    ScheduleProposal day(SchedulingSettings? hours) => planWorkspaceDay(
      window: TimeSpan(_at(10), _at(13)),
      events: [free, busy],
      tasks: tasks,
      settings: hours,
    );
    WeeklyPlanPreview? week(List<CalendarEvent> events) => planWorkspaceWeek(
      weekStart: weeklyPlanStart(_day),
      notBefore: _at(10),
      events: events,
      tasks: tasks,
      settings: settings,
    );
    for (final schedule in [
      day(null),
      day(settings),
      week([free, busy])!.proposal,
    ]) {
      expect(
        schedule.scheduled.single.blocks.single.start.toLocal(),
        _at(11, 15),
      );
    }
    expect(
      () => week([free, _event(free.id, free.start, free.end)]),
      throwsFormatException,
    );
  });

  test('manual review preserves identities and rechecks a change to busy', () {
    final task = _task('send');
    final span = TimeSpan(_at(10), _at(10, 30));
    final free = _event('Reminder', _at(9, 45), _at(11), blocksTime: false);
    final events = [free];
    final settings = _settings(before: 10, after: 5);
    final selection = reviewManualTimeBlock(
      taskId: task.id,
      span: span,
      tasks: [task],
      events: events,
      notBefore: _at(9),
      settings: settings,
    ).approve()!;
    expect(() => selection.calendarEvent(newId: free.id), throwsArgumentError);
    expect(selection.calendarEvent(newId: 'accepted').blocksTime, isTrue);
    expect(
      selection.verify(
        tasks: [task],
        events: [_event(free.id, free.start, free.end)],
        notBefore: _at(9),
        settings: settings,
      ),
      isNull,
    );
  });

  test('removing future task blocks preserves free task-linked rows', () {
    final task = _task('send').withDone(true, completedAt: _at(9));
    final busy = _event('Accepted time', _at(11), _at(12), task: task.id);
    final free = _event(
      'Task reminder',
      _at(9, 30),
      _at(10),
      task: task.id,
      blocksTime: false,
    );
    final events = [free, busy];
    final review = FutureBlockRemovalReview.prepare(
      task: task,
      events: events,
      now: _at(9),
    );
    expect(review.blocks, [busy]);
    expect(
      review
          .select([busy.id])!
          .remainingEvents(task: task, events: events, now: _at(9)),
      [free],
    );
  });
}
