import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/weekly_plan_sheet.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _day = DateTime(2030, 9, 2);
DateTime _at(int minutes) => _day.add(Duration(minutes: minutes));
const _ready = TaskItem(
  id: 'ready',
  title: 'Review the request',
  category: 'work',
  estimatedMinutes: 15,
);

void main() {
  for (final week in [false, true]) {
    testWidgets(
      '${week ? 'weekly' : 'daily'} review renders 18,000 unscheduled rows lazily at 200% text',
      (tester) async {
        final tasks = [
          _ready,
          for (var index = 0; index < 18000; index++)
            TaskItem(
              id: 'pending-${index.toString().padLeft(5, '0')}',
              title: 'Unestimated task $index',
              category: 'work',
            ),
        ];
        Object? accepted;
        await _host(
          tester,
          size: week ? const Size(320, 580) : const Size(568, 320),
          build: (context) => TextButton(
            onPressed: () async {
              accepted = await showModalBottomSheet<Object>(
                context: context,
                isScrollControlled: true,
                builder: (_) => week
                    ? WeeklyPlanSheet(
                        weekStart: _day,
                        tasks: tasks,
                        events: const [],
                        clock: () => _at(480),
                      )
                    : PlanDaySheet(
                        day: _day,
                        tasks: tasks,
                        events: const [],
                        clock: () => _at(480),
                      ),
              );
            },
            child: const Text('Open plan'),
          ),
        );
        await _tap(tester, 'Open plan');
        await _preview(tester, week ? 'Preview week' : 'Preview plan');
        expect(accepted, isNull);
        final toggle = find.text(
          week ? 'Unscheduled · 18000' : 'Unscheduled (18000)',
        );
        await tester.scrollUntilVisible(toggle, 90);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final first = find.text('Unestimated task 0');
        await tester.scrollUntilVisible(first, 90);
        await tester.pumpAndSettle();
        expect(find.byType(ListTile).evaluate().length, lessThan(24));
        expect(find.text('Add an estimated duration'), findsWidgets);
        expect(find.text('Unestimated task 17999'), findsNothing);
        await _tap(tester, 'Add selected tasks');
        final scheduled = switch (accepted) {
          WeeklyPlanSelection(:final tasks) ||
          PlanSelection(:final tasks) => tasks,
          _ => null,
        };
        expect(scheduled?.single.task.id, _ready.id);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'daily review keeps every split time available in a lazy detail view',
    (tester) async {
      final events = [
        for (var index = 0; index < 120; index++)
          CalendarEvent(
            id: 'busy-$index',
            title: 'Existing event',
            category: 'work',
            start: _at(543 + index * 4),
            end: _at(544 + index * 4),
          ),
      ];
      const task = TaskItem(
        id: 'split',
        title: 'Split work',
        category: 'work',
        estimatedMinutes: 90,
        allowSplit: true,
        minimumChunkMinutes: 2,
      );
      PlanSelection? selection;
      await _host(
        tester,
        size: const Size(320, 580),
        build: (context) => TextButton(
          onPressed: () async {
            selection = await showModalBottomSheet<PlanSelection>(
              context: context,
              isScrollControlled: true,
              builder: (_) => PlanDaySheet(
                day: _day,
                tasks: const [task],
                events: events,
                clock: () => _at(480),
              ),
            );
          },
          child: const Text('Open plan'),
        ),
      );
      await _tap(tester, 'Open plan');
      await _preview(tester, 'Preview plan');
      final show = find.text('Show all 30 block times');
      await tester.scrollUntilVisible(show, 90);
      await tester.pumpAndSettle();
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('Block times'), findsOneWidget);
      final rows = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListTile),
      );
      expect(rows.evaluate().length, inInclusiveRange(1, 15));
      await tester.tap(find.byTooltip('Close block times'));
      await tester.pumpAndSettle();
      expect(selection, isNull);
      await _tap(tester, 'Add selected tasks');
      expect(selection?.tasks.single.blocks, hasLength(30));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large objective chooser keeps exact scope while searching', (
    tester,
  ) async {
    final tasks = [
      for (var index = 0; index < 30000; index++)
        TaskItem(
          id: 'objective-$index',
          title: 'Objective $index',
          category: 'work',
          estimatedMinutes: 45,
        ),
    ];
    WeeklyPlanSelection? selection;
    await _host(
      tester,
      size: const Size(568, 320),
      build: (context) => TextButton(
        onPressed: () async {
          selection = await showModalBottomSheet<WeeklyPlanSelection>(
            context: context,
            isScrollControlled: true,
            builder: (_) => WeeklyPlanSheet(
              weekStart: _day,
              tasks: tasks,
              events: const [],
              clock: () => _at(480),
            ),
          );
        },
        child: const Text('Open plan'),
      ),
    );
    await _tap(tester, 'Open plan');
    final objectives = find.text('Objectives');
    await tester.scrollUntilVisible(objectives, 120);
    await tester.pumpAndSettle();
    await tester.tap(objectives);
    await tester.pumpAndSettle();
    final modalScroll = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Scrollable))
        .first;
    final clear = find.text('Clear selection');
    await tester.scrollUntilVisible(clear, 85, scrollable: modalScroll);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(20));
    final filter = find.byType(TextField);
    await tester.ensureVisible(filter);
    await tester.enterText(filter, 'Objective 27017');
    await tester.pumpAndSettle();
    final match = find.widgetWithText(CheckboxListTile, 'Objective 27017');
    await tester.scrollUntilVisible(match, 85, scrollable: modalScroll);
    await tester.pumpAndSettle();
    await tester.tap(match);
    await tester.pumpAndSettle();
    await _tap(tester, 'Use objectives');
    expect(find.text('1 task selected'), findsOneWidget);
    await _preview(tester, 'Preview week');
    await _tap(tester, 'Add selected tasks');
    expect(selection?.tasks.single.task.id, 'objective-27017');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _host(
  WidgetTester tester, {
  required Size size,
  required WidgetBuilder build,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(body: Builder(builder: build)),
    ),
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _preview(WidgetTester tester, String label) async {
  final control = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, label),
  );
  await tester.runAsync(
    () async => (control.onPressed! as Future<void> Function())(),
  );
  await tester.pumpAndSettle();
}
