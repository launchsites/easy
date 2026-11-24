import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/quick_capture.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('desktop opens a titled task beside a usable task list', (
    tester,
  ) async {
    const selected = 'Draft a homepage brief';
    const other = 'Send a project update';
    final preferences = await _openWorkspace(tester, [
      TaskItem(
        id: 'brief',
        title: selected,
        category: 'work',
        date: dateOnly(DateTime.now()),
      ),
      TaskItem(
        id: 'update',
        title: other,
        category: 'work',
        date: dateOnly(DateTime.now()),
      ),
    ]);
    await _navigate(tester, 'Tasks');
    final list = find.byType(TasksPage);
    final selectedRow = find.descendant(
      of: list,
      matching: find.text(selected),
    );
    final otherRow = find.descendant(of: list, matching: find.text(other));
    await tester.tap(selectedRow);
    await tester.pumpAndSettle();

    expect(find.text(selected), findsNWidgets(2));
    final listTitle = selectedRow.evaluate().single;
    final heading = find.byWidget(
      find
          .text(selected)
          .evaluate()
          .singleWhere((node) => node != listTitle)
          .widget,
    );
    expect(heading.hitTestable(), findsOneWidget);
    expect(otherRow.hitTestable(), findsOneWidget);
    expect(tester.getRect(heading).right, lessThan(tester.getRect(list).left));
    expect(
      tester.getCenter(heading).dx,
      lessThan(tester.getCenter(selectedRow).dx),
    );
    expect(find.text('Search workspace'), findsOneWidget);
    expect(find.byType(RecordEditor), findsNothing);

    Finder checkbox(String title) => find.descendant(
      of: list,
      matching: find.byWidgetPredicate(
        (widget) => widget is Checkbox && widget.semanticLabel == title,
      ),
    );
    expect(tester.widget<Checkbox>(checkbox(other)).value, isFalse);
    await tester.tap(checkbox(other));
    await tester.pumpAndSettle();

    expect(find.text(selected), findsNWidgets(2));
    expect(find.text(other), findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox(other)).value, isTrue);
    expect(tester.widget<Checkbox>(checkbox(selected)).value, isFalse);
    final tasks = await _savedTasks(preferences);
    expect(tasks.singleWhere((task) => task.id == 'update').done, isTrue);
    expect(tasks.singleWhere((task) => task.id == 'brief').done, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop New focuses contextual capture and saves spoken time', (
    tester,
  ) async {
    final preferences = await _openWorkspace(tester, const []);
    await _navigate(tester, 'Tasks');
    final localAnchor = DateTime.now();
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyN,
    );
    final capture = find.byType(QuickCapture);
    final field = find.descendant(
      of: capture,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<QuickCapture>(capture).kind, RecordKind.task);
    expect(
      tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
      isTrue,
    );

    await tester.enterText(field, "Web Design Tomorrow, 10 o'clock");
    await _chord(
      tester,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.enter,
    );
    expect(capture, findsNothing);
    expect(
      find.descendant(
        of: find.byType(TasksPage),
        matching: find.text('Web Design'),
      ),
      findsOneWidget,
    );
    final task = (await _savedTasks(preferences)).single;
    final localDeadline = DateTime(
      localAnchor.year,
      localAnchor.month,
      localAnchor.day + 1,
      10,
    );
    expect(task.title, 'Web Design');
    expect(task.date, dateOnly(localDeadline));
    expect(task.dueAt?.toLocal(), localDeadline);

    await _navigate(tester, 'Calendar');
    await _chord(tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyN);
    expect(tester.widget<QuickCapture>(capture).kind, RecordKind.event);
    expect(
      tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<SharedPreferencesAsync> _openWorkspace(
  WidgetTester tester,
  List<TaskItem> tasks,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final previous = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  final preferences = SharedPreferencesAsync();
  await preferences.setString(
    'easy.workspace.v1',
    WorkspaceData(events: const [], tasks: tasks, notes: const []).encode(),
  );
  await tester.pumpWidget(
    const EasyApp(openStore: openPreferenceWorkspaceStore),
  );
  await tester.pumpAndSettle();
  return preferences;
}

Future<List<TaskItem>> _savedTasks(SharedPreferencesAsync preferences) async {
  final store = await openPreferenceWorkspaceStore(
    preferences: preferences,
    readLegacy: () async => throw StateError('Expected an initialized store.'),
  );
  try {
    return WorkspaceData.decode((await store.read()).snapshot.workspaceJson)
        .tasks;
  } finally {
    await store.close();
  }
}

Future<void> _navigate(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}
