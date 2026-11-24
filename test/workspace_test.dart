import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/orbit_navigation.dart';
import 'package:easy/record_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  testWidgets('Mobile capture saves a task and opens its details', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    expect(find.text('Studio review'), findsOneWidget);
    await tester.tap(find.text('All spaces'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Work'));
    await tester.pumpAndSettle();

    const title = 'Parcel collection';
    await tester.tap(find.byTooltip('Add item'));
    await tester.pumpAndSettle();
    final editor = find.byType(RecordEditor);
    final titleField = find
        .descendant(of: editor, matching: find.byType(TextFormField))
        .first;
    await tester.enterText(titleField, title);
    await tester.tap(find.widgetWithText(FilledButton, 'Add task'));
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    final task = find.text(title);
    expect(task, findsOneWidget);

    await _openMobileTasks(tester);
    await tester.ensureVisible(task);
    await tester.tap(task);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: editor, matching: task), findsOneWidget);

    // Create a fresh workspace state backed by the same local store.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    await _openMobileTasks(tester);
    expect(task, findsOneWidget);
  });

  testWidgets('Desktop sidebar opens workspaces and contextual details', (
    tester,
  ) async {
    _setViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Navigate'), findsNothing);

    await tester.tap(find.widgetWithText(InkWell, 'Calendar').first);
    await tester.pumpAndSettle();
    expect(find.byType(CalendarPage), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-date')), findsOneWidget);
    expect(find.text('Week'), findsNothing);

    await tester.tap(find.widgetWithText(InkWell, 'Tasks').first);
    await tester.pumpAndSettle();
    expect(find.byType(TasksPage), findsOneWidget);
    await tester.tap(find.text('Send the project outline'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close details'), findsOneWidget);

    await tester.tap(find.widgetWithText(InkWell, 'Notes').first);
    await tester.pumpAndSettle();
    expect(find.byType(NotesPage), findsOneWidget);
    expect(find.byTooltip('Close details'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _openMobileTasks(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Navigate'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(OrbitNavigation),
      matching: find.text('Tasks'),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(TasksPage), findsOneWidget);
}
