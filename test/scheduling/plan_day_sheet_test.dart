import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/task_model.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

DateTime _at(int hour, [int minute = 0, int dayOffset = 0]) =>
    DateTime(2030, 9, 3 + dayOffset, hour, minute);

CalendarEvent _event(
  String id,
  DateTime start,
  DateTime end, [
  String? taskId,
]) => CalendarEvent(
  id: id,
  title: id,
  start: start,
  end: end,
  category: 'work',
  plannedTaskId: taskId,
);

const _draft = TaskItem(
  id: 'draft',
  title: 'Draft summary',
  category: 'work',
  estimatedMinutes: 75,
);

const _review = TaskItem(
  id: 'review',
  title: 'Review summary',
  category: 'work',
  estimatedMinutes: 15,
  prerequisiteIds: ['draft'],
);

void main() {
  test(
    'workspace adapter merges reserved effort and waits on a prerequisite',
    () {
      final proposal = planWorkspaceDay(
        window: TimeSpan(_at(9), _at(17)),
        events: [
          _event('Meeting', _at(9), _at(10)),
          _event(
            'Past accepted draft',
            _at(9, 0, -1),
            _at(10, 30, -1),
            'draft',
          ),
          _event('Accepted draft', _at(11), _at(11, 30), 'draft'),
          _event('Overlapping acceptance', _at(11, 15), _at(11, 45), 'draft'),
        ],
        tasks: [_draft, _review],
      );
      final draft = proposal.scheduled.first;
      final review = proposal.scheduled.last;
      expect(draft.task.id, 'draft');
      expect(draft.task.remainingMinutes, 30);
      expect(draft.blocks.single.start, _at(10));
      expect(draft.blocks.single.end, _at(10, 30));
      expect(review.task.id, 'review');
      expect(review.blocks.single.start, _at(11, 45));
      expect(proposal.unscheduled, isEmpty);
    },
  );

  test('adapter respects exact deadlines and excludes fully reserved work', () {
    final exact = TaskItem(
      id: 'exact',
      title: 'Time-sensitive work',
      category: 'work',
      estimatedMinutes: 30,
      date: _at(0),
      dueAt: _at(9, 10),
    );
    final dayDeadline = TaskItem(
      id: 'day',
      title: 'Date-only work',
      category: 'work',
      date: _at(0),
      estimatedMinutes: 30,
    );
    final proposal = planWorkspaceDay(
      window: TimeSpan(_at(9), _at(17)),
      events: [
        _event('Fully planned later', _at(9, 0, 1), _at(10, 15, 1), 'draft'),
      ],
      tasks: [_draft, _review, exact, dayDeadline],
    );

    expect(proposal.scheduled.map((item) => item.task.id), [dayDeadline.id]);
    expect(proposal.scheduled.single.task.deadline, _at(0, 0, 1));
    final issues = {
      for (final item in proposal.unscheduled) item.task.id: item.problem,
    };
    expect(issues, {
      exact.id: PlannerProblem.noFeasibleTime,
      _review.id: PlannerProblem.unavailableDependency,
    });
  });

  test('earlier future blocks reserve effort before the selected day', () {
    final proposal = planWorkspaceDay(
      window: TimeSpan(_at(9), _at(17)),
      reservationStart: _at(12, 0, -1),
      events: [
        _event('Past work', _at(9, 0, -1), _at(11, 0, -1), 'draft'),
        _event(
          'Earlier accepted work',
          _at(14, 0, -1),
          _at(15, 0, -1),
          'draft',
        ),
      ],
      tasks: const [_draft],
    );
    expect(proposal.scheduled.single.task.remainingMinutes, 15);
    expect(
      proposal.scheduled.single.blocks.single.length,
      const Duration(minutes: 15),
    );
  });

  testWidgets('sheet previews off the UI isolate and returns a safe subset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    PlanSelection? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showModalBottomSheet<PlanSelection>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PlanDaySheet(
                    day: _at(0),
                    events: [_event('Meeting', _at(11), _at(12))],
                    tasks: const [_draft, _review],
                    clock: () => _at(8),
                  ),
                );
              },
              child: const Text('Open day planner'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open day planner'));
    await tester.pumpAndSettle();
    expect(find.text('Available from'), findsOneWidget);
    expect(find.text('Available until'), findsOneWidget);
    expect(find.text(_draft.title), findsNothing);
    final preview = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Preview plan'),
    );
    await tester.runAsync(() async {
      await (preview.onPressed! as Future<void> Function())();
    });
    await tester.pumpAndSettle();

    final draftTile = find.widgetWithText(CheckboxListTile, _draft.title);
    final reviewTile = find.widgetWithText(CheckboxListTile, _review.title);
    final add = find.widgetWithText(FilledButton, 'Add selected tasks');
    expect(draftTile, findsOneWidget);
    expect(reviewTile, findsOneWidget);
    expect(selected, isNull);
    await tester.tap(draftTile);
    await tester.pumpAndSettle();
    expect(find.text('Select the prerequisite tasks first.'), findsOneWidget);
    expect(tester.widget<FilledButton>(add).onPressed, isNull);
    await tester.tap(reviewTile);
    await tester.pumpAndSettle();
    await tester.tap(draftTile);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(selected?.tasks.map((task) => task.task.id), ['draft']);
    expect(selected?.window.start, _at(9));
    expect(selected?.window.end, _at(17));
    expect(selected?.reservationStart, _at(8));
    expect(tester.takeException(), isNull);
  });
}
