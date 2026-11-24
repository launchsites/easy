import 'package:easy/mobile_home.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_workspace_feed.dart';
import 'package:easy/today_page.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _mount(
  WidgetTester tester,
  Widget home, {
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: Scaffold(body: home),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final day = DateTime(2026, 11, 24);
  final tomorrow = DateUtils.addDaysToDate(day, 1);

  testWidgets(
    'compact Today promotes only the exact open repeating occurrence',
    (tester) async {
      _viewport(tester, const Size(320, 568));
      final plain = TaskItem(
        id: 'plain',
        title: 'Original first task',
        category: 'work',
        date: day,
      );
      const template = TaskItem(
        id: 'reading',
        title: 'Read the full design brief and add a handoff note',
        category: 'work',
        estimatedMinutes: 30,
      );
      final series = RecurringTaskSeries(
        id: template.id,
        task: template,
        startDate: day,
        rule: InternalRecurrenceRule(
          frequency: InternalRecurrenceFrequency.daily,
        ),
      );
      final tasks = TaskWorkspaceFeed([series])
          .workspaceTasks([plain, template], day);
      final selected = tasks.singleWhere(
        (task) => task.id != plain.id && DateUtils.isSameDay(task.date, day),
      );
      final next = tasks.singleWhere(
        (task) => DateUtils.isSameDay(task.date, tomorrow),
      );
      TaskItem? opened;
      TaskItem? toggled;
      Future<void> show(String? fit, {bool showTasks = true}) => _mount(
        tester,
        MobileHome(
          date: day,
          mode: 'work',
          modeControl: const Text('Mode'),
          note: null,
          events: [],
          tasks: tasks,
          fitsNowTaskId: fit,
          showTasks: showTasks,
          showSchedule: false,
          onNoteTap: () {},
          onCalendarTap: () {},
          onEventTap: (_) {},
          onTaskTap: (task) => opened = task,
          onTaskToggle: (task) => toggled = task,
        ),
        scale: 2,
        direction: TextDirection.rtl,
      );

      await show(selected.id);
      final title = find.text(selected.title);
      final taskRow = find.byKey(ValueKey(selected.id));
      final marker = find.descendant(
        of: taskRow,
        matching: find.text('Fits now'),
      );
      int rowIndex(Finder row) => tester
          .widget<IndexedSemantics>(
            find
                .ancestor(of: row, matching: find.byType(IndexedSemantics))
                .first,
          )
          .index;
      expect(marker, findsOneWidget);
      expect(find.text('Fits now'), findsOneWidget);
      expect(find.byKey(ValueKey(next.id)), findsNothing);
      expect(tester.widget<Text>(title).maxLines, isNull);
      expect(rowIndex(taskRow), 0);
      expect(tester.getRect(marker).left, greaterThan(0));
      expect(tester.getRect(marker).right, lessThan(320));
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      await tester.tap(title.hitTestable());
      expect(opened, same(selected));
      final checkbox = find.descendant(
        of: taskRow,
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox.hitTestable());
      expect(toggled, same(selected));

      for (final fit in [null, template.id, next.id]) {
        await show(fit);
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.text('Fits now'), findsNothing);
        expect(rowIndex(find.byKey(ValueKey(plain.id))), 0);
      }
      await show(selected.id);
      expect(marker, findsOneWidget);
      expect(find.text('Fits now'), findsOneWidget);
      await show(selected.id, showTasks: false);
      expect(title, findsNothing);
      expect(find.text('Fits now'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop Today restores normal task order when a fit is cleared',
    (tester) async {
      _viewport(tester, const Size(1440, 900));
      final first = TaskItem(
        id: 'first',
        title: 'First task',
        category: 'study',
        date: day,
      );
      final last = TaskItem(
        id: 'last',
        title: 'Task that fits',
        category: 'study',
        date: day,
      );
      final completed = TaskItem(
        id: 'completed',
        title: 'Completed task',
        category: 'study',
        date: day,
        done: true,
      );
      final later = TaskItem(
        id: 'later',
        title: 'Tomorrow task',
        category: 'study',
        date: tomorrow,
      );
      TaskItem? opened;
      TaskItem? toggled;
      Future<void> show(String? fit) => _mount(
        tester,
        TodayPage(
          date: day,
          events: [],
          tasks: [first, completed, last, later],
          fitsNowTaskId: fit,
          showSchedule: false,
          onEventTap: (_) {},
          onTaskTap: (task) => opened = task,
          onTaskToggle: (task) => toggled = task,
        ),
      );

      await show(last.id);
      final marker = find.text('Fits now');
      final selected = find.byKey(ValueKey(last.id));
      expect(find.descendant(of: selected, matching: marker), findsOneWidget);
      expect(marker, findsOneWidget);
      expect(
        tester.getTopLeft(find.text(last.title)).dy,
        lessThan(tester.getTopLeft(find.text(first.title)).dy),
      );
      await tester.tap(find.text(last.title));
      await tester.tap(
        find.descendant(of: selected, matching: find.byType(Checkbox)),
      );
      expect(opened, same(last));
      expect(toggled, same(last));

      for (final fit in [null, completed.id, later.id, 'out-of-focus']) {
        await show(fit);
        expect(marker, findsNothing);
        expect(find.text(later.title), findsNothing);
        expect(
          tester.getTopLeft(find.text(first.title)).dy,
          lessThan(tester.getTopLeft(find.text(last.title)).dy),
        );
        expect(
          tester.getTopLeft(find.text(last.title)).dy,
          lessThan(tester.getTopLeft(find.text(completed.title)).dy),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
