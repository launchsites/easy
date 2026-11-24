import 'dart:convert';

import 'package:easy/categories/workspace_categories.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/task_breakdown.dart';
import 'package:easy/tasks/task_breakdown_review.dart';
import 'package:easy/tasks/task_capture_defaults.dart';
import 'package:easy/tasks/task_capture_defaults_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'breakdown keeps explicitly worded steps and resolves a literal object',
    () {
      final parent = _task('Build a website for Alex and send it to Alex');
      final review = proposeTaskBreakdown(parent);
      expect(review.proposals.map((proposal) => proposal.title), [
        'Build a website for Alex',
        'Send the website to Alex',
      ]);
      expect(review.proposals.last.sourceText, 'send it to Alex');
      expect(
        proposeTaskBreakdown(_task('Draft the brief; review it, then send it'))
            .proposals
            .map((proposal) => proposal.title),
        ['Draft the brief', 'Review the brief', 'Send the brief'],
      );
      expect(
        proposeTaskBreakdown(
          _task('Write a report, draft a summary, and send it'),
        ).proposals.last.title,
        'Send it',
      );
    },
  );

  test('breakdown abstains from ambiguous wording or completed work', () {
    for (final title in [
      'Build a website for Alex',
      'Review terms and conditions',
      'Review checklist and test results',
      'Review “write and send an invoice”',
      'Read "create a logo and publish it"',
      'Review the brief (check expenses and draft a reply)',
      'Build and send it',
      'Do not prepare a report and send it',
      'Review the brief and do not publish it',
    ]) {
      expect(
        proposeTaskBreakdown(_task(title)).proposals,
        isEmpty,
        reason: title,
      );
    }
    expect(
      proposeTaskBreakdown(_task('Prepare slides and share them', done: true))
          .proposals,
      isEmpty,
    );
  });

  test('approval rechecks parent, hierarchy, existing children, and IDs', () {
    final parent = _task(
      'Build a website and send it',
      date: DateTime(2026, 1),
      estimated: 90,
    );
    final review = proposeTaskBreakdown(parent);
    final approval = review.approve({1: 'Send the final site to Alex'})!;
    final children = approval.createChildren(
      currentTasks: [parent],
      nextId: () => 'fresh',
    )!;
    expect(children.single.title, 'Send the final site to Alex');
    expect(children.single.parentId, parent.id);
    expect(children.single.category, parent.category);
    expect(children.single.date, isNull);
    expect(children.single.dueAt, isNull);
    expect(children.single.estimatedMinutes, isNull);
    expect(parent.estimatedMinutes, 90);
    expect(
      approval.createChildren(currentTasks: [parent], nextId: () => parent.id),
      isNull,
    );
    expect(
      approval.createChildren(currentTasks: const [], nextId: () => 'fresh'),
      isNull,
    );
    expect(
      approval.createChildren(
        currentTasks: [parent.withDone(true)],
        nextId: () => 'fresh',
      ),
      isNull,
    );
    expect(
      approval.createChildren(
        currentTasks: [_task('Build a different site')],
        nextId: () => 'fresh',
      ),
      isNull,
    );
    expect(
      approval.createChildren(
        currentTasks: [
          parent,
          _task(
            'send the  final site to Alex!',
            id: 'existing',
            parentId: parent.id,
          ),
        ],
        nextId: () => 'fresh',
      ),
      isNull,
    );
    expect(review.approve({9: 'Invalid index'}), isNull);
    expect(review.approve({0: '', 1: 'Send'}), isNull);
    expect(review.approve({0: 'Duplicate', 1: 'duplicate!'}), isNull);
    final already = _task(
      'Send the website',
      id: 'existing',
      parentId: parent.id,
    );
    expect(
      proposeTaskBreakdown(
        parent,
        existingTasks: [already],
      ).proposals.single.title,
      'Build a website',
    );

    final nested = parent.withParent('depth-8');
    final chain = [
      for (var index = 0; index < 9; index++)
        _task(
          'Level $index',
          id: 'depth-$index',
          parentId: index == 0 ? null : 'depth-${index - 1}',
        ),
      nested,
    ];
    expect(
      proposeTaskBreakdown(nested)
          .approve({0: 'Build the site'})!
          .createChildren(currentTasks: chain, nextId: () => 'fresh'),
      isNull,
    );
  });

  test('capture defaults distinguish a civil date, Inbox, and General', () {
    final now = DateTime(2026, 12, 31, 23, 50);
    const today = TaskCaptureDefaults(placement: TaskCapturePlacement.today);
    const tomorrow = TaskCaptureDefaults(
      placement: TaskCapturePlacement.tomorrow,
      categoryId: '',
    );
    expect(today.dateFor(now), DateTime(2026, 12, 31));
    expect(tomorrow.dateFor(now), DateTime(2027));
    expect(const TaskCaptureDefaults().dateFor(now), isNull);
    expect(today.toJson(), isNot(contains('categoryId')));
    final decoded = TaskCaptureDefaults.fromJson(
      jsonDecode(jsonEncode(tomorrow.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.placement, TaskCapturePlacement.tomorrow);
    expect(decoded.categoryId, '');
    expect(
      () => TaskCaptureDefaults.fromJson({'version': 1, 'placement': 'later'}),
      throwsFormatException,
    );
  });

  testWidgets('320px breakdown review edits and explicitly selects one step', (
    tester,
  ) async {
    _phone(tester);
    final review = proposeTaskBreakdown(_task('Build a website and send it'));
    TaskBreakdownApproval? choice;
    await _show(
      tester,
      (context) async =>
          choice = await showTaskBreakdownReview(context, review: review),
    );
    await _tap(tester, 'Open');
    final action = find.widgetWithText(FilledButton, 'Add selected');
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('breakdown-title-1')),
      'Send the staging link',
    );
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pumpAndSettle();
    await _tap(tester, 'Add selected');
    expect(choice?.titles, ['Send the staging link']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px capture defaults select and clear a nested category', (
    tester,
  ) async {
    _phone(tester);
    final catalog = WorkspaceCategories.defaults().withCategory(
      WorkspaceCategory(
        id: 'reports',
        label: 'Reports',
        colorArgb: 0xff426651,
        parentId: 'work',
      ),
    );
    var defaults = const TaskCaptureDefaults();
    await _show(tester, (context) async {
      defaults =
          await showTaskCaptureDefaultsEditor(
            context,
            defaults: defaults,
            categories: catalog,
          ) ??
          defaults;
    });
    await _tap(tester, 'Open');
    await _tap(tester, 'Tomorrow');
    await _tap(tester, 'Default category');
    await _tap(tester, 'Reports');
    expect(find.text('Work / Reports'), findsOneWidget);
    await _tap(tester, 'Save defaults');
    expect(defaults.placement, TaskCapturePlacement.tomorrow);
    expect(defaults.categoryId, 'reports');
    await _tap(tester, 'Open');
    await _tap(tester, 'Use focus mode');
    await _tap(tester, 'Save defaults');
    expect(defaults.categoryId, isNull);
    expect(tester.takeException(), isNull);
  });
}

TaskItem _task(
  String title, {
  String id = 'parent',
  String? parentId,
  DateTime? date,
  bool done = false,
  int? estimated,
}) => TaskItem(
  id: id,
  title: title,
  category: 'work',
  parentId: parentId,
  date: date,
  done: done,
  estimatedMinutes: estimated,
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 625);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _show(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}
