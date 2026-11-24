import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/weekly_plan_sheet.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_workspace_feed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('one weekly run accounts for accepted effort and respects due/dependency times', () {
    final reserved = _event(
      'accepted',
      _at(0, 9),
      _at(0, 9, 20),
      task: 'build',
    );
    final settings = _settings();
    final tasks = [_build, _review, _urgent, _unknown];
    final preview = planWorkspaceWeek(
      weekStart: _at(0, 0),
      notBefore: _at(0, 8),
      events: [reserved, reserved],
      tasks: tasks,
      settings: settings,
    )!;
    expect(preview.window.start, _at(0, 8));
    expect(preview.window.end, _at(7, 0));
    final scheduled = {
      for (final item in preview.proposal.scheduled) item.task.id: item,
    };
    final build = scheduled['build']!;
    expect(build.task.remainingMinutes, 90);
    expect(
      build.blocks.map((block) => (block.start.toLocal(), block.end.toLocal())),
      [(_at(0, 9, 20), _at(0, 10)), (_at(1, 9), _at(1, 9, 50))],
    );
    expect(scheduled['review']!.blocks.single.start.toLocal(), _at(2, 9));
    expect(
      {
        for (final item in preview.proposal.unscheduled)
          item.task.id: item.problem,
      },
      {
        'urgent': PlannerProblem.deadlinePassed,
        'unknown': PlannerProblem.needsDuration,
      },
    );
    expect(preview.select(['review']), isNull);
    expect(preview.select(['build', 'build']), isNull);
    final selection = preview.select(['build', 'review'])!;
    expect(() => selection.tasks.clear(), throwsUnsupportedError);
    expect(
      selection.verify(
        events: [reserved],
        tasks: tasks,
        settings: settings,
        notBefore: _at(0, 9),
      ),
      hasLength(2),
    );
    expect(
      selection.verify(
        events: [reserved],
        tasks: tasks,
        settings: settings,
        notBefore: _at(0, 9, 21),
      ),
      isNull,
    );
    expect(
      selection.verify(
        events: [reserved],
        tasks: tasks,
        settings: settings,
        categories: {'work'},
        notBefore: _at(0, 8),
      ),
      isNull,
    );
    expect(
      selection.verify(
        events: [reserved],
        tasks: tasks,
        settings: _settings(endMinute: 610),
        notBefore: _at(0, 8),
      ),
      isNull,
    );

    final added = [
      for (final item in selection.tasks)
        for (final (index, block) in item.blocks.indexed)
          _event(
            '${item.task.id}-$index',
            block.start,
            block.end,
            task: item.task.id,
          ),
    ];
    expect(
      selection.verify(
        events: [reserved, ...added],
        tasks: tasks,
        settings: settings,
        notBefore: _at(0, 8),
      ),
      isNull,
    );
    final conflict = _event('busy', _at(1, 9), _at(1, 9, 15));
    expect(
      selection.verify(
        events: [reserved, conflict],
        tasks: tasks,
        settings: settings,
        notBefore: _at(0, 8),
      ),
      isNull,
    );
    final collision = _event(
      'accepted',
      _at(2, 9),
      _at(2, 9, 20),
      task: 'review',
    );
    expect(
      selection.verify(
        events: [reserved, collision],
        tasks: tasks,
        settings: settings,
        notBefore: _at(0, 8),
      ),
      isNull,
    );
  });

  test('trial hours are explicit and retain configured exclusions', () {
    const task = TaskItem(
      id: 'copy',
      title: 'Edit copy',
      category: 'work',
      estimatedMinutes: 40,
    );
    final exclusion = SchedulingSettings(
      availability: [
        WeeklyAvailability(
          id: 'monday-off',
          weekdays: [1],
          startMinute: 0,
          endMinute: 1440,
          kind: AvailabilityKind.unavailable,
        ),
      ],
    );
    final noHours = planWorkspaceWeek(
      weekStart: _at(0, 0),
      notBefore: _at(0, 0),
      events: [],
      tasks: [task],
      settings: exclusion,
    )!;
    expect(noHours.proposal.scheduled, isEmpty);
    expect(
      noHours.proposal.advisories,
      contains('This window has no saved availability.'),
    );
    final hours = WeeklyPlanHours(
      weekdays: [1, 2],
      startMinute: 540,
      endMinute: 600,
    );
    final preview = planWorkspaceWeek(
      weekStart: _at(0, 0),
      notBefore: _at(0, 0),
      events: [],
      tasks: [task],
      settings: exclusion,
      hours: hours,
    )!;
    expect(
      preview.proposal.scheduled.single.blocks.single.start.toLocal(),
      _at(1, 9),
    );
    expect(
      () => planWorkspaceWeek(
        weekStart: _at(0, 0),
        notBefore: _at(0, 0),
        events: [],
        tasks: [task],
        settings: _settings(),
        hours: hours,
      ),
      throwsArgumentError,
    );
  });

  test(
    'objective exclusions keep accepted and completed prerequisites only',
    () {
      const prep = TaskItem(
        id: 'prep',
        title: 'Prepare slides',
        category: 'work',
        estimatedMinutes: 30,
      );
      const present = TaskItem(
        id: 'present',
        title: 'Present slides',
        category: 'work',
        estimatedMinutes: 15,
        prerequisiteIds: ['prep'],
      );
      WeeklyPlanPreview run({
        bool done = false,
        List<CalendarEvent> events = const [],
      }) => planWorkspaceWeek(
        weekStart: _at(0, 0),
        notBefore: _at(0, 8),
        events: events,
        tasks: [done ? prep.withDone(true) : prep, present],
        settings: _settings(),
        taskIds: {'present'},
      )!;
      final undispatched = run().proposal;
      expect(undispatched.scheduled, isEmpty);
      expect(
        undispatched.unscheduled.single.problem,
        PlannerProblem.unavailableDependency,
      );
      expect(undispatched.unscheduled.single.prerequisiteId, 'prep');
      final booked = _event(
        'prep-booking',
        _at(0, 9),
        _at(0, 9, 30),
        task: 'prep',
      );
      final accepted = run(events: [booked]);
      expect(
        accepted.proposal.scheduled.single.blocks.single.start.toLocal(),
        _at(0, 9, 30),
      );
      expect(accepted.select(['present']), isNotNull);
      expect(
        run(done: true).proposal.scheduled.single.blocks.single.start.toLocal(),
        _at(0, 9),
      );
    },
  );

  test('recurring effort retains each effective date in a weekly horizon', () {
    const repeating = TaskItem(
      id: 'repeat',
      title: 'Read a chapter',
      category: 'study',
      estimatedMinutes: 20,
    );
    const plain = TaskItem(id: 'plain', title: 'Independent', category: 'work');
    final series = RecurringTaskSeries(
      id: repeating.id,
      task: repeating,
      startDate: _at(0, 0),
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.daily,
      ),
    );
    final tasks = weeklyWorkspaceTasks(
      feed: TaskWorkspaceFeed([series]),
      tasks: [plain, repeating],
      weekStart: _at(0, 0),
    );
    expect(tasks.where((item) => item.id == plain.id), hasLength(1));
    expect(tasks.where((item) => item.id == repeating.id), isEmpty);
    expect(tasks.map((item) => item.id).toSet(), hasLength(8));
    final repeatingCandidates = tasks.where((item) => item.id != plain.id);
    for (final (index, task) in repeatingCandidates.indexed) {
      expect(task.date, _at(index, 0));
      expect(task.earliestStart, _at(index, 0));
    }
    final preview = planWorkspaceWeek(
      weekStart: _at(0, 0),
      notBefore: _at(0, 0),
      events: [],
      tasks: tasks,
      hours: WeeklyPlanHours(
        weekdays: [1, 2, 3, 4, 5, 6, 7],
        startMinute: 540,
        endMinute: 600,
      ),
    )!;
    final dates = preview.proposal.scheduled.map(
      (task) => task.blocks.single.start.toLocal(),
    );
    expect(dates, [for (var i = 0; i < 7; i++) _at(i, 9)]);
  });

  test('seven-day window uses civil dates and refuses elapsed weeks', () {
    final reference = DateTime(2030, 9, 4, 19);
    expect(weeklyPlanStart(reference), _at(0, 0));
    expect(weeklyPlanStart(reference, startsOn: DateTime.sunday), _at(-1, 0));
    final late = DateTime(2026, 12, 28);
    expect(weeklyPlanEnd(late), DateTime(2027, 1, 4));
    expect(weeklyPlanningWindow(late, notBefore: DateTime(2027, 1, 4)), isNull);
  });

  testWidgets(
    '320px week review retains split selection and prerequisite closure',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 695);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      WeeklyPlanSelection? accepted;
      final reserved = _event(
        'accepted',
        _at(0, 9),
        _at(0, 9, 20),
        task: 'build',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await showModalBottomSheet<WeeklyPlanSelection>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => WeeklyPlanSheet(
                      weekStart: _at(0, 0),
                      events: [reserved],
                      tasks: [_build, _review, _competing],
                      settings: _settings(),
                      clock: () => _at(0, 8),
                    ),
                  );
                },
                child: const Text('Open week'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open week'));
      await tester.pumpAndSettle();
      expect(find.text('Uses your saved availability.'), findsOneWidget);
      await tester.tap(find.text('Objectives'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, _competing.title));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use objectives'));
      await tester.pumpAndSettle();
      expect(find.text('2 tasks selected'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Preview week'),
      );
      await tester.runAsync(
        () async => (button.onPressed! as Future<void> Function())(),
      );
      await tester.pumpAndSettle();
      expect(accepted, isNull);
      final build = find.widgetWithText(CheckboxListTile, 'Build site');
      final review = find.widgetWithText(CheckboxListTile, 'Review site');
      final apply = find.widgetWithText(FilledButton, 'Add selected tasks');
      expect(build, findsNWidgets(2));
      expect(find.text(_competing.title), findsNothing);
      await tester.tap(build.first);
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<CheckboxListTile>(build).map((tile) => tile.value),
        [false, false],
      );
      expect(find.text('Select the prerequisite tasks first.'), findsOneWidget);
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.ensureVisible(build.last);
      await tester.pumpAndSettle();
      await tester.tap(build.last);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(accepted?.tasks.map((entry) => entry.task.id), ['build']);
      expect(accepted?.tasks.single.blocks, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}

DateTime _at(int offset, int hour, [int minute = 0]) =>
    DateTime(2030, 9, 2 + offset, hour, minute);

SchedulingSettings _settings({int endMinute = 600}) => SchedulingSettings(
  availability: [
    WeeklyAvailability(
      id: 'open',
      weekdays: [1, 2, 3],
      startMinute: 540,
      endMinute: endMinute,
    ),
  ],
);

CalendarEvent _event(String id, DateTime start, DateTime end, {String? task}) =>
    CalendarEvent(
      id: id,
      title: id,
      start: start,
      end: end,
      category: 'work',
      plannedTaskId: task,
    );

final _build = TaskItem(
  id: 'build',
  title: 'Build site',
  category: 'work',
  estimatedMinutes: 110,
  allowSplit: true,
  minimumChunkMinutes: 30,
  dueAt: _at(1, 10),
);
final _review = TaskItem(
  id: 'review',
  title: 'Review site',
  category: 'work',
  estimatedMinutes: 15,
  prerequisiteIds: ['build'],
  dueAt: _at(2, 10),
);
final _urgent = TaskItem(
  id: 'urgent',
  title: 'Already due',
  category: 'work',
  estimatedMinutes: 15,
  dueAt: _at(0, 8),
);
const _unknown = TaskItem(
  id: 'unknown',
  title: 'Estimate outstanding',
  category: 'work',
);
const _competing = TaskItem(
  id: 'unselected',
  title: 'Tidy the archive',
  category: 'work',
  estimatedMinutes: 10,
);
