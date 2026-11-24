import 'package:easy/list_pages.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const root = TaskItem(id: 'root', title: 'Write report', category: 'work');
  const child = TaskItem(
    id: 'child',
    title: 'Outline findings',
    parentId: 'root',
    category: 'work',
    estimatedMinutes: 45,
    priority: TaskPriority.high,
    notes: 'Check the figures first.',
  );
  const grandchild = TaskItem(
    id: 'grandchild',
    title: 'Check totals',
    parentId: 'child',
    category: 'work',
  );
  const alternative = TaskItem(
    id: 'alternative',
    title: 'Share results',
    category: 'work',
  );

  test(
    'validates cycles, missing parents, and depth including descendants',
    () {
      const tasks = [root, child, grandchild, alternative];
      expect(
        taskParentIssue(tasks, root.id, grandchild.id),
        TaskParentIssue.cycle,
      );
      expect(taskParentIssue(tasks, child.id, child.id), TaskParentIssue.cycle);
      expect(
        taskParentIssue(tasks, child.id, 'missing'),
        TaskParentIssue.missing,
      );
      expect(taskParentIssue(tasks, child.id, null), isNull);
      expect(taskParentIssue(tasks, child.id, alternative.id), isNull);

      final deep = [
        root,
        child,
        grandchild,
        for (var i = 0; i < maxTaskDepth; i++)
          TaskItem(
            id: 'deep$i',
            title: 'Level $i',
            category: 'work',
            parentId: i == 0 ? null : 'deep${i - 1}',
          ),
      ];
      expect(
        taskParentIssue(deep, grandchild.id, 'deep${maxTaskDepth - 1}'),
        isNull,
      );
      expect(
        taskParentIssue(deep, child.id, 'deep${maxTaskDepth - 1}'),
        TaskParentIssue.tooDeep,
      );
      expect(child.withDone(true).withParent(null).estimatedMinutes, 45);
      expect(child.withParent(null).notes, child.notes);
    },
  );

  test(
    'prerequisites reject cycles and missing records separately from parents',
    () {
      final waiting = child.withPrerequisites([root.id]);
      final downstream = grandchild.withPrerequisites([child.id]);
      final tasks = [root, waiting, downstream, alternative];
      expect(
        taskPrerequisiteIssue(tasks, root.id, [root.id]),
        TaskPrerequisiteIssue.cycle,
      );
      expect(
        taskPrerequisiteIssue(tasks, root.id, [grandchild.id]),
        TaskPrerequisiteIssue.cycle,
      );
      expect(
        taskPrerequisiteIssue(tasks, root.id, ['deleted']),
        TaskPrerequisiteIssue.missing,
      );
      expect(taskPrerequisiteIssue([root, child], root.id, [child.id]), isNull);
      expect(TaskDependencyGraph(tasks).eligiblePrerequisites(root.id), [
        alternative,
      ]);

      final broken = alternative.withPrerequisites(['deleted']);
      expect(
        taskPrerequisiteIssue([root, broken], root.id, [broken.id]),
        TaskPrerequisiteIssue.missing,
      );
      final cycle = [
        root,
        waiting.withPrerequisites([downstream.id]),
        downstream,
      ];
      expect(
        taskPrerequisiteIssue(cycle, root.id, [child.id]),
        TaskPrerequisiteIssue.cycle,
      );
    },
  );

  test(
    'split minimum accepts the estimate boundary and rejects invalid blocks',
    () {
      String? validate(int? minimum) => taskSplitIssue(
        allowSplit: true,
        minimumChunkMinutes: minimum,
        estimatedMinutes: 30,
      );
      expect(validate(null), isNotNull);
      expect(validate(0), isNotNull);
      expect(validate(-5), isNotNull);
      expect(validate(31), isNotNull);
      expect(validate(30), isNull);
      expect(
        taskSplitIssue(
          allowSplit: false,
          minimumChunkMinutes: 99,
          estimatedMinutes: 30,
        ),
        isNull,
      );
    },
  );

  testWidgets('nested rows have independent toggle and disclosure controls', (
    tester,
  ) async {
    _phone(tester);
    TaskItem? toggled;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Scaffold(
          body: TasksPage(
            tasks: const [root, child, grandchild],
            onToggle: (task) => toggled = task,
            onTaskTap: (_) {},
          ),
        ),
      ),
    );

    final parentTitle = find.text(root.title);
    final childTitle = find.text(child.title);
    final grandchildTitle = find.text(grandchild.title);
    expect(
      tester.getTopLeft(childTitle).dx,
      greaterThan(tester.getTopLeft(parentTitle).dx),
    );
    expect(
      tester.getTopLeft(grandchildTitle).dx,
      greaterThan(tester.getTopLeft(childTitle).dx),
    );
    expect(find.text('45 min'), findsOneWidget);
    expect(find.text('High priority'), findsOneWidget);

    await tester.tap(find.byTooltip('Complete ${child.title}'));
    expect(toggled, same(child));
    await tester.tap(find.byTooltip('Collapse ${root.title}'));
    await tester.pumpAndSettle();
    expect(childTitle, findsNothing);
    expect(grandchildTitle, findsNothing);
    await tester.tap(find.byTooltip('Expand ${root.title}'));
    await tester.pumpAndSettle();
    expect(childTitle, findsOneWidget);
    expect(grandchildTitle, findsOneWidget);
  });

  testWidgets('task editor excludes descendants and saves optional details', (
    tester,
  ) async {
    _phone(tester);
    final due = DateTime(2030, 8, 12);
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<Object>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: RecordEditor(
                        date: due,
                        kind: RecordKind.task,
                        task: TaskItem(
                          id: root.id,
                          title: root.title,
                          category: root.category,
                          date: due,
                        ),
                        taskItems: const [root, child, grandchild, alternative],
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, 'Open editor');
    await _tap(tester, 'Task details');
    await _tap(tester, 'Parent task');
    expect(find.text(child.title), findsNothing);
    expect(find.text(grandchild.title), findsNothing);
    await _tap(tester, alternative.title);
    await _tap(tester, 'Priority');
    await _tap(tester, 'High');

    final estimate = find.byKey(const ValueKey('task-estimate'));
    final notes = find.byKey(const ValueKey('task-notes'));
    await tester.ensureVisible(estimate);
    await tester.enterText(estimate, '0');
    await _tap(tester, 'Save changes');
    expect(
      find.text('Enter an estimated duration in whole minutes.'),
      findsOneWidget,
    );
    await tester.ensureVisible(estimate);
    await tester.enterText(estimate, '30');
    await tester.ensureVisible(notes);
    await tester.enterText(notes, '# Report notes');
    await _tap(tester, 'Earliest start');
    await _tap(tester, '13');
    await _tap(tester, 'OK');
    await _tap(tester, 'OK');
    await _tap(tester, 'Save changes');
    expect(
      find.text('Earliest start must be on or before the due date.'),
      findsOneWidget,
    );
    final removeDue = find.byTooltip('Remove due date');
    await tester.ensureVisible(removeDue);
    await tester.tap(removeDue);
    await tester.pumpAndSettle();
    await _tap(tester, 'Save changes');

    final edited = result as TaskItem;
    expect(edited.id, root.id);
    expect(edited.parentId, alternative.id);
    expect(edited.estimatedMinutes, 30);
    expect(edited.priority, TaskPriority.high);
    expect(edited.notes, '# Report notes');
    expect(edited.date, isNull);
    expect(DateUtils.dateOnly(edited.earliestStart!), DateTime(2030, 8, 13));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'task planning controls save a due time and valid prerequisites',
    (tester) async {
      _phone(tester);
      final due = DateTime(2030, 8, 12);
      final task = TaskItem(
        id: root.id,
        title: root.title,
        category: root.category,
        estimatedMinutes: 30,
        date: due,
      );
      final downstream = child.withPrerequisites([task.id]);
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<Object>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        body: RecordEditor(
                          date: due,
                          kind: RecordKind.task,
                          task: task,
                          taskItems: [task, downstream, alternative],
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Open planning'),
              ),
            ),
          ),
        ),
      );
      await _tap(tester, 'Open planning');
      await _tap(tester, 'Due time');
      await _tap(tester, 'OK');
      await _tap(tester, 'Prerequisites');
      expect(find.text(downstream.title), findsNothing);
      await _tap(tester, alternative.title);
      await _tap(tester, 'Apply prerequisites');
      await _tap(tester, 'Split across blocks');
      final minField = find.byKey(const ValueKey('task-minimum-chunk'));
      await tester.ensureVisible(minField);
      await tester.enterText(minField, '31');
      await _tap(tester, 'Save changes');
      expect(
        find.text('Minimum block cannot exceed the estimated duration.'),
        findsOneWidget,
      );
      await tester.ensureVisible(minField);
      await tester.enterText(minField, '15');
      await _tap(tester, 'Save changes');

      final edited = result as TaskItem;
      expect(edited.prerequisiteIds, [alternative.id]);
      expect(edited.allowSplit, isTrue);
      expect(edited.minimumChunkMinutes, 15);
      expect(edited.dueAt, DateTime(due.year, due.month, due.day, 17));
      final completed = edited.withDone(true).withParent('another');
      expect(completed.prerequisiteIds, edited.prerequisiteIds);
      expect(completed.minimumChunkMinutes, edited.minimumChunkMinutes);
      expect(completed.dueAt, edited.dueAt);
      expect(tester.takeException(), isNull);
    },
  );
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _tap(WidgetTester tester, String title) async {
  final element = find.text(title);
  await tester.ensureVisible(element);
  await tester.tap(element);
  await tester.pumpAndSettle();
}
