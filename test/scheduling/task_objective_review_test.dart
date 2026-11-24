import 'dart:math';

import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/task_objective_review.dart';
import 'package:easy/scheduling/task_objective_review_sheet.dart';
import 'package:easy/task_model.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _now = DateTime.utc(2032, 5, 4, 10);
DateTime _at(int minutes) => _now.add(Duration(minutes: minutes));

TaskItem _task(
  String id, {
  String? title,
  String category = 'work',
  int? minutes,
  int? due,
  int? preferred,
  int? earliest,
  int? minimumChunk,
  TaskPriority? priority,
  bool done = false,
  int? completed,
  List<String> needs = const [],
  String? parent,
  TaskSchedulingHold? hold,
}) => TaskItem(
  id: id,
  title: title ?? id,
  category: category,
  estimatedMinutes: minutes,
  dueAt: due == null ? null : _at(due),
  date: preferred == null ? null : _at(preferred),
  earliestStart: earliest == null ? null : _at(earliest),
  allowSplit: minimumChunk != null,
  minimumChunkMinutes: minimumChunk ?? defaultTaskChunkMinutes,
  priority: priority,
  done: done,
  completedAt: completed == null ? null : _at(completed),
  prerequisiteIds: needs,
  parentId: parent,
  schedulingHold: hold,
);

CalendarEvent _event(
  String id,
  int start,
  int end, {
  String? task,
  bool external = false,
  bool allDay = false,
  String? series,
}) => CalendarEvent(
  id: id,
  title: id,
  category: 'work',
  start: _at(start),
  end: _at(end),
  plannedTaskId: task,
  sourceLabel: external ? 'Other calendar' : null,
  allDay: allDay,
  recurringSeriesId: series,
);

TaskObjectiveReview _review(
  List<TaskItem> tasks, {
  List<CalendarEvent> events = const [],
  TimeSpan? window,
  Set<String>? scope,
  DateTime? horizon,
}) => reviewTaskObjectives(
  tasks: tasks,
  events: events,
  now: _now,
  horizonEnd: horizon ?? _at(180),
  focusCategories: scope,
  workWindow: window,
);

Map<String, TaskObjective> _rows(TaskObjectiveReview review) => {
  for (final row in [
    ...review.ready,
    ...review.needsAttention,
    ...review.later,
  ])
    row.id: row,
};

void main() {
  test(
    'urgent prerequisites keep their own dates and outrank unbound work',
    () {
      final preparation = _task('prepare', preferred: 1440);
      final tasks = [
        _task('ship', due: 60, needs: ['middle']),
        _task('a-high', priority: TaskPriority.high),
        _task('middle', needs: ['prepare']),
        _task('b-timed', due: 90),
        _task('c-soft', preferred: -2880),
        preparation,
      ];
      final review = _review(tasks);
      expect(review.ready.map((row) => row.id), [
        'prepare',
        'b-timed',
        'a-high',
        'c-soft',
      ]);
      final first = review.ready.first;
      expect(first.dueAt, isNull);
      expect(first.preferredDate, _at(1440));
      expect(first.dependencyDeadline?.taskId, 'ship');
      expect(first.dependencyDeadline?.dueAt, _at(60));
      expect(_rows(review)['middle']?.prerequisiteTitle, 'prepare');
      expect(_rows(review)['ship']?.prerequisiteTitle, 'middle');
      expect(_rows(review)['b-timed']?.dueAt, _at(90));
      expect(_rows(review)['c-soft']?.dueAt, isNull);
      expect(_review(tasks, horizon: _at(45)).ready.first.id, 'a-high');
      expect(identical(tasks.last, preparation), isTrue);
      expect(preparation.dueAt, isNull);
      expect(() => review.ready.clear(), throwsUnsupportedError);
    },
  );

  test(
    'focus scopes rows while actual dependencies cross focus categories',
    () {
      const hold = TaskSchedulingHold(
        reason: TaskSchedulingHoldReason.appointmentTime,
      );
      final tasks = [
        _task('land', due: 32, category: 'study', needs: ['research']),
        _task('research', category: 'work'),
        _task('notify', category: 'work', needs: ['old-legacy', 'done-study']),
        _task('old-legacy', category: 'study', done: true),
        _task('done-study', category: 'study', done: true, completed: -2),
        _task('future-check', category: 'study', done: true, completed: 1),
        _task('wait', category: 'work', needs: ['future-check']),
        _task('gate', category: 'work', hold: hold),
        _task('gate-dependent', category: 'work', needs: ['gate']),
      ];
      final review = _review(tasks, scope: {'work'});
      expect(review.ready.map((row) => row.id), ['research', 'notify']);
      expect(review.ready.first.dependencyDeadline?.taskId, 'land');
      expect(_rows(review)['land'], isNull);
      expect(_rows(review)['gate']?.hold, same(hold));
      expect(_rows(review)['gate']?.readiness, ObjectiveReadiness.needsDetails);
      expect(
        _rows(review)['gate-dependent']?.readiness,
        ObjectiveReadiness.waitingForPrerequisite,
      );
      expect(
        _rows(review)['wait']?.readiness,
        ObjectiveReadiness.prerequisiteUnavailable,
      );
      expect(_review(tasks, scope: {}).isEmpty, isTrue);
    },
  );

  test('ties and broken branches stay stable across shuffled input', () {
    final tasks = [
      _task('a', needs: ['b', 'common', 'common'], due: 4),
      _task('b', needs: ['a']),
      _task('a-child', needs: ['a'], due: 5),
      _task('missing', needs: ['removed', 'common'], due: 10),
      _task('missing-child', needs: ['missing'], due: 12),
      _task('look-duplicate', needs: ['duplicate']),
      _task('duplicate', done: true),
      _task('duplicate'),
      _task('current', needs: ['common', 'also-common', 'common'], due: 30),
      _task('same-time', needs: ['common'], due: 30),
      _task('late', needs: ['also-common'], due: 25),
      _task('also-common'),
      _task('common'),
    ];
    final random = Random(79);
    for (var shuffle = 0; shuffle < 100; shuffle++) {
      final result = _review([...tasks]..shuffle(random));
      final rows = _rows(result);
      expect(result.ready.map((row) => row.id), ['also-common', 'common']);
      expect(rows['common']?.dependencyDeadline?.taskId, 'current');
      expect(rows['also-common']?.dependencyDeadline?.taskId, 'late');
      expect(rows['duplicate'], isNull);
      expect(rows['current']?.prerequisiteTitle, 'common');
      expect(rows['current']?.additionalPrerequisiteCount, 1);
      for (final id in [
        'a',
        'b',
        'a-child',
        'missing',
        'missing-child',
        'look-duplicate',
      ]) {
        expect(rows[id]?.readiness, ObjectiveReadiness.prerequisiteUnavailable);
      }
    }
  });

  test(
    'reservations merge, subtract only upcoming effort, and remain distinct',
    () {
      final result = _review(
        [
          _task('covered', minutes: 60),
          _task('partial', minutes: 60),
          _task('already-started', minutes: 90),
          _task('unknown'),
          _task('external', minutes: 30),
          _task('duplicates', minutes: 30),
          _task('blocked', needs: ['covered']),
          _task('past', minutes: 30),
        ],
        events: [
          _event('c-a', 10, 55, task: 'covered'),
          _event('c-b', 40, 70, task: 'covered'),
          _event('p-a', 40, 55, task: 'partial'),
          _event('p-b', 50, 75, task: 'partial'),
          _event('live', -30, 5, task: 'already-started'),
          _event('u', 90, 120, task: 'unknown'),
          _event('link', 90, 120, task: 'external', external: true),
          _event('all', 90, 120, task: 'external', allDay: true),
          _event(
            'repeat',
            90,
            120,
            task: 'external',
            series: 'repeating-event',
          ),
          _event('duplicate', 90, 120, task: 'duplicates'),
          _event('duplicate', 95, 120),
          _event('ended', -30, 0, task: 'past'),
        ],
      );
      final rows = _rows(result);
      expect(result.ready.first.id, 'already-started');
      expect(result.ready.first.inReservedTime, isTrue);
      expect(result.ready.first.availableToStart, isFalse);
      expect(
        rows['already-started']?.reservedEffort,
        const Duration(minutes: 5),
      );
      expect(rows['covered']?.reservedEffort, const Duration(minutes: 60));
      expect(rows['covered']?.unreservedEffort, Duration.zero);
      expect(rows['partial']?.reservedEffort, const Duration(minutes: 35));
      expect(rows['partial']?.unreservedEffort, const Duration(minutes: 25));
      expect(rows['covered']?.readiness, ObjectiveReadiness.reservedTime);
      expect(rows['unknown']?.readiness, ObjectiveReadiness.reservedTime);
      expect(rows['external']?.reservedEffort, Duration.zero);
      expect(rows['past']?.reservedEffort, Duration.zero);
      expect(
        rows['duplicates']?.readiness,
        ObjectiveReadiness.reservationUnavailable,
      );
      expect(
        rows['blocked']?.readiness,
        ObjectiveReadiness.waitingForPrerequisite,
      );
    },
  );

  test('an active block outside a changed task bound still occupies time', () {
    for (final scheduled in [
      _task('scheduled', minutes: 30, due: 15),
      _task('scheduled', minutes: 30, earliest: 5),
    ]) {
      final independent = _task('independent', minutes: 15);
      final result = _review(
        [scheduled, independent],
        window: TimeSpan(_now, _at(120)),
        events: [_event('accepted', -5, 25, task: scheduled.id)],
      );
      expect(result.ready, isEmpty);
      expect(result.availableTime, Duration.zero);
      final changed = result.needsAttention.single;
      expect(changed.id, scheduled.id);
      expect(changed.readiness, ObjectiveReadiness.reservationUnavailable);
      expect(changed.nextReservation, isNull);
      expect(changed.reservedEffort, Duration.zero);
      expect(changed.inReservedTime, isFalse);
      expect(result.later.single.id, independent.id);
      expect(result.later.single.fit, ObjectiveFit.needsMoreTime);
    }
  });

  test('a reservation matching both hard bounds stays actionable', () {
    final result = _review(
      [_task('scheduled', minutes: 25, earliest: -5, due: 25)],
      events: [_event('accepted', -5, 25, task: 'scheduled')],
    );
    final current = result.ready.single;
    expect(current.readiness, ObjectiveReadiness.reservedTime);
    expect(current.inReservedTime, isTrue);
    expect(current.reservedEffort, const Duration(minutes: 25));
  });

  test(
    'fit uses verified time and respects hard due times and split minimums',
    () {
      final tasks = [
        _task('exact', minutes: 20, due: 20),
        _task('long', minutes: 31),
        _task('too-close', minutes: 20, due: 19),
        _task('splittable', minutes: 45, minimumChunk: 15),
        _task('too-short-to-split', minutes: 31, minimumChunk: 16),
        _task('earliest', minutes: 5, earliest: 1),
        _task('missed', minutes: 5, due: 0),
        _task('unestimated'),
        _task('project', minutes: 20),
        _task('child', minutes: 20, parent: 'project'),
        _task('settled-parent', minutes: 20),
        _task('done-child', done: true, parent: 'settled-parent'),
      ];
      final busy = [_event('appointment', 30, 55)];
      final result = _review(
        tasks,
        window: TimeSpan(_at(-5), _at(60)),
        events: busy,
      );
      final rows = _rows(result);
      expect(result.availableTime, const Duration(minutes: 30));
      expect(rows['exact']?.fit, ObjectiveFit.complete);
      expect(rows['too-close']?.fit, ObjectiveFit.needsMoreTime);
      expect(rows['long']?.fit, ObjectiveFit.needsMoreTime);
      expect(rows['splittable']?.fit, ObjectiveFit.split);
      expect(rows['too-short-to-split']?.fit, ObjectiveFit.needsMoreTime);
      expect(rows['earliest']?.readiness, ObjectiveReadiness.startsLater);
      expect(rows['missed']?.readiness, ObjectiveReadiness.missedDeadline);
      expect(rows['unestimated']?.fit, ObjectiveFit.unknown);
      expect(rows['project']?.readiness, ObjectiveReadiness.hasSubtasks);
      expect(rows['child']?.availableToStart, isTrue);
      expect(rows['settled-parent']?.availableToStart, isTrue);

      final future = _review(tasks, window: TimeSpan(_at(30), _at(60)));
      expect(future.availableTime, isNull);
      expect(_rows(future)['exact']?.fit, ObjectiveFit.unknown);
      final occupied = _review(
        tasks,
        window: TimeSpan(_at(0), _at(60)),
        events: [_event('ongoing appointment', -10, 1)],
      );
      expect(occupied.availableTime, Duration.zero);
      expect(occupied.ready, isEmpty);
      expect(() => _review(tasks, horizon: _now), throwsArgumentError);
    },
  );

  test(
    'calendar and dependency snapshots stay bounded across 100,000 tasks',
    () {
      const count = 100000;
      final tasks = [
        for (var index = 0; index < count; index++)
          _task(
            '$index',
            needs: index == 0 ? const [] : ['${index - 1}'],
            due: index == count - 1 ? 15 : null,
          ),
      ];
      final review = _review(tasks);
      expect(review.ready.single.id, '0');
      expect(review.ready.single.dependencyDeadline?.taskId, '${count - 1}');
      expect(review.needsAttention, hasLength(count - 1));
      expect(review.needsAttention.first.dueAt, isNull);
    },
  );

  for (final size in [const Size(320, 580), const Size(568, 320)]) {
    testWidgets('24,000 objectives stay navigable at $size and 200%', (
      tester,
    ) async {
      final review = _review([
        for (var index = 0; index < 24000; index++)
          _task(index.toString().padLeft(5, '0'), title: 'Objective $index'),
        _task('blocked', title: 'Needs an appointment', needs: ['missing']),
      ]);
      String? selected;
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async => selected = await showTaskObjectives(
                    context,
                    review: review,
                  ),
                  child: const Text('Open review'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      expect(find.text('What can I work on?'), findsOneWidget);
      final all = find.text('Show all 24000');
      await tester.scrollUntilVisible(all, 110);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(find.text('Ready tasks'), findsOneWidget);
      final fullList = find.byType(Dialog).last;
      Finder inside(Finder matching) =>
          find.descendant(of: fullList, matching: matching);
      final visibleRows = inside(
        find.textContaining(RegExp(r'^Objective \d+$')),
      );
      expect(visibleRows.evaluate().length, inInclusiveRange(1, 24));
      expect(find.text('Objective 23999'), findsNothing);
      final objective = inside(find.text('Objective 1'));
      await tester.scrollUntilVisible(
        objective,
        80,
        scrollable: inside(find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
      await tester.tap(objective);
      await tester.pumpAndSettle();
      expect(selected, '00001');
      expect(find.text('What can I work on?'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
