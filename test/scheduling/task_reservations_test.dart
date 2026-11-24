import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/manual_time_block.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/task_reservations.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2030, 1, 7, 10);
DateTime _at(int minutes) => _now.add(Duration(minutes: minutes));

TaskItem _task(
  String id, {
  int? minutes = 30,
  List<String> needs = const [],
  int? earliest,
  int? due,
  bool done = false,
  int? finished,
}) => TaskItem(
  id: id,
  title: id,
  category: 'work',
  estimatedMinutes: minutes,
  prerequisiteIds: needs,
  earliestStart: earliest == null ? null : _at(earliest),
  dueAt: due == null ? null : _at(due),
  done: done,
  completedAt: finished == null ? null : _at(finished),
);

CalendarEvent _block(
  String id,
  String task,
  int start,
  int end, {
  bool external = false,
  bool allDay = false,
  String? series,
}) => CalendarEvent(
  id: id,
  title: id,
  category: 'work',
  plannedTaskId: task,
  start: _at(start),
  end: _at(end),
  sourceLabel: external ? 'Shared calendar' : null,
  allDay: allDay,
  recurringSeriesId: series,
);

ScheduleProposal _day(List<TaskItem> tasks, List<CalendarEvent> events) =>
    planWorkspaceDay(
      window: TimeSpan(_now, _at(180)),
      events: events,
      tasks: tasks,
    );

ManualBlockReview _manual(List<TaskItem> tasks, List<CalendarEvent> events) =>
    reviewManualTimeBlock(
      taskId: 'finish',
      span: TimeSpan(_at(90), _at(120)),
      tasks: tasks,
      events: events,
      notBefore: _now,
    );

void main() {
  final accepted = _block('draft-time', 'draft', 30, 60);
  final finish = _task('finish', needs: ['draft']);
  final setup = _task('setup', minutes: null);

  for (final (constraint, draft) in [
    ('prerequisite', _task('draft', needs: ['setup'])),
    ('earliest start', _task('draft', earliest: 45)),
    ('hard deadline', _task('draft', due: 45)),
  ]) {
    test('retains stale $constraint blocks and stops downstream placement', () {
      final work = _task('independent', minutes: 45);
      final tasks = [setup, draft, finish, work];
      final plan = _day(tasks, [accepted]);
      expect(plan.scheduled.map((row) => row.task.id), [work.id]);
      expect(plan.scheduled.single.blocks.single.start, _at(60));
      expect(plan.satisfiedPrerequisites, isEmpty);
      final issues = {
        for (final issue in plan.unscheduled) issue.task.id: issue,
      };
      expect(issues['draft']?.problem, PlannerProblem.reservationsNeedReview);
      expect(issues['finish']?.problem, PlannerProblem.unavailableDependency);
      expect(issues['finish']?.prerequisiteId, 'draft');
      final manual = _manual(tasks, [accepted]);
      expect(manual.problem, ManualBlockProblem.prerequisite);
      expect(manual.relatedTitle, draft.title);
    });
  }

  test(
    'fresh manual and weekly proofs reject a newly stale approved draft',
    () {
      final saved = [accepted];
      final old = [setup, _task('draft'), finish];
      final changed = [
        setup,
        _task('draft', needs: ['setup']),
        finish,
      ];
      final manual = _manual(old, saved).approve()!;
      expect(
        manual.verify(tasks: old, events: saved, notBefore: _now),
        isNotNull,
      );
      expect(
        manual.verify(tasks: changed, events: saved, notBefore: _now),
        isNull,
      );
      final hours = WeeklyPlanHours(
        weekdays: [1],
        startMinute: 540,
        endMinute: 960,
      );
      final weekly = planWorkspaceWeek(
        weekStart: weeklyPlanStart(_now),
        notBefore: _now,
        events: saved,
        tasks: old,
        hours: hours,
      )!.select(['finish'])!;
      expect(
        weekly.verify(events: saved, tasks: old, notBefore: _now),
        isNotNull,
      );
      expect(
        weekly.verify(events: saved, tasks: changed, notBefore: _now),
        isNull,
      );
    },
  );

  test('new upstream work needs explicit acceptance before it proves a reservation', () {
    final draft = _task('draft', needs: ['setup']);
    final preparing = _task('setup');
    final tasks = [preparing, draft, finish];
    final first = _day(tasks, [accepted]);
    expect(first.scheduled.single.task.id, 'setup');
    expect(first.scheduled.single.blocks.single.start, _now);
    expect(first.satisfiedPrerequisites, isEmpty);
    final reviewed = [accepted, _block('prep', 'setup', 0, 30)];
    final next = _day(tasks, reviewed);
    expect(next.satisfiedPrerequisites, {'setup', 'draft'});
    expect(next.scheduled.single.task.id, 'finish');
    expect(next.scheduled.single.blocks.single.start, _at(60));
    expect(_manual(tasks, reviewed).approve(), isNotNull);
  });

  test(
    'retains only valid coverage when extra accepted intervals became stale',
    () {
      final events = [
        accepted,
        _block('extends-too-late', 'draft', 120, 150),
        _block('historical', 'draft', -60, 0),
      ];
      final tasks = [_task('draft', due: 60, earliest: 30), finish];
      final proof = reviewTaskReservations(
        tasks: tasks,
        events: events,
        cutoff: _now,
      );
      final draft = proof.reservations['draft']!;
      expect(draft.minutes, 60);
      expect(draft.lastEnd, _at(150));
      expect(draft.coveredAt, _at(60));
      expect(draft.requiresReview, isTrue);
      expect(proof.satisfiesAt('draft', _at(60)), isTrue);
      expect(
        proof.satisfiesAt(
          'draft',
          _at(60).subtract(const Duration(microseconds: 1)),
        ),
        isFalse,
      );
      final next = _day(tasks, events);
      expect(next.scheduled.single.task.id, 'finish');
      expect(next.scheduled.single.blocks.single.start, _at(60));
    },
  );

  test(
    'historical completion timestamps and duplicate records fail closed',
    () {
      final events = [accepted];
      final draft = _task('draft', needs: ['setup']);
      for (final complete in [
        _task('setup', done: true),
        _task('setup', done: true, finished: -2),
      ]) {
        final verified = [complete, draft, finish];
        expect(_day(verified, events).satisfiedPrerequisites, {
          'setup',
          'draft',
        });
        expect(_manual(verified, events).approve(), isNotNull);
      }
      final future = [_task('setup', done: true, finished: 1), draft, finish];
      expect(_day(future, events).scheduled, isEmpty);
      expect(_manual(future, events).problem, ManualBlockProblem.prerequisite);
      final duplicate = reviewTaskReservations(
        tasks: [_task('draft'), finish],
        events: [accepted, _block('draft-time', 'draft', 40, 70)],
        cutoff: _now,
      );
      expect(duplicate.reservations['draft']?.minutes, 40);
      expect(duplicate.reservations['draft']?.requiresReview, isTrue);
      expect(duplicate.satisfiesAt('draft', _at(120)), isFalse);
    },
  );

  test(
    'read-only, all-day, and repeating calendar rows never prove task work',
    () {
      final tasks = [_task('draft'), finish];
      final imported = [
        _block('read-only', 'draft', 30, 60, external: true),
        _block('all-day', 'draft', 60, 90, allDay: true),
        _block('repeated', 'draft', 90, 120, series: 'series'),
      ];
      final proof = reviewTaskReservations(
        tasks: tasks,
        events: imported,
        cutoff: _now,
      );
      expect(proof.reservations, isEmpty);
      expect(_manual(tasks, imported).problem, ManualBlockProblem.prerequisite);
      final plan = _day(tasks, imported);
      expect(plan.satisfiedPrerequisites, isEmpty);
      expect(plan.scheduled.map((block) => block.blocks.single.start), [
        _now,
        _at(120),
      ]);
    },
  );

  test(
    'counted effort is exact across overlaps, elapsed time and real gaps',
    () {
      final proof = reviewTaskReservations(
        tasks: [_task('draft')],
        events: [
          _block('cover-left', 'draft', -10, 10),
          _block('overlap', 'draft', 5, 20),
          _block('after-gap', 'draft', 26, 40),
        ],
        cutoff: _now,
      );
      final coverage = proof.reservations['draft']!;
      expect(coverage.minutes, 34);
      expect(coverage.coveredAt, _at(36));
      expect(coverage.lastEnd, _at(40));
      expect(proof.satisfiesAt('draft', _at(36)), isTrue);
      expect(
        proof.satisfiesAt(
          'draft',
          _at(36).subtract(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    },
  );

  test('moving accepted work respects a booked dependant in a chain', () {
    final tasks = [
      _task('start'),
      _task('middle', needs: ['start']),
      _task('finish', needs: ['middle']),
    ];
    final bookings = [
      _block('first', 'start', 30, 60),
      _block('second', 'middle', 60, 90),
      _block('third', 'finish', 90, 120),
    ];
    ManualBlockReview move(int start) => reviewManualTimeBlock(
      taskId: 'start',
      span: TimeSpan(_at(start), _at(start + 30)),
      tasks: tasks,
      events: bookings,
      notBefore: _now,
      existingEventId: 'first',
    );

    final earlier = move(0).approve();
    expect(earlier?.calendarEvent().id, 'first');
    expect(earlier?.calendarEvent().initialPlannedStart, _at(30));
    final later = move(120);
    expect(later.problem, ManualBlockProblem.dependent);
    expect(later.relatedTitle, 'middle');
    expect(later.approve(), isNull);
  });

  test(
    '20,000 accepted-task dependencies complete iteratively or expose a cycle',
    () {
      const count = 20000;
      final tasks = [
        for (var index = 0; index < count; index++)
          _task(
            '$index',
            minutes: 1,
            needs: index == 0 ? const [] : ['${index - 1}'],
          ),
      ];
      final events = [
        for (var index = 0; index < count; index++)
          _block('b-$index', '$index', index, index + 1),
      ];
      final accepted = reviewTaskReservations(
        tasks: tasks,
        events: events,
        cutoff: _now,
      );
      expect(accepted.satisfiesAt('${count - 1}', _at(count)), isTrue);
      expect(accepted.satisfiesAt('${count - 1}', _at(count - 1)), isFalse);
      tasks[0] = tasks[0].withPrerequisites(['${count - 1}']);
      final cycle = reviewTaskReservations(
        tasks: tasks,
        events: events,
        cutoff: _now,
      );
      expect(cycle.satisfiesAt('${count - 1}', _at(count)), isFalse);
      expect(cycle.reservations.length, count);
      expect(
        cycle.reservations.values.every((evidence) => evidence.requiresReview),
        isTrue,
      );
    },
  );
}
