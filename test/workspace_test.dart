import 'package:easy/calendar_page.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/orbit_navigation.dart';
import 'package:easy/quick_capture.dart';
import 'package:easy/record_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    expect(find.byType(MobileHome), findsOneWidget);
    expect(find.text('Note to self'), findsOneWidget);
    await _pickMode(tester, 'Work');
    await _openMobileDestination(tester, 'Tasks');

    const title = 'Parcel collection';
    await tester.tap(find.byTooltip('Add item'));
    await tester.pumpAndSettle();
    final capture = find.byType(QuickCapture);
    await _submitCapture(tester, title, 'Add task');
    expect(capture, findsNothing);
    final editor = find.byType(RecordEditor);
    final task = find.text(title);
    expect(task, findsOneWidget);

    await _openMobileDestination(tester, 'Today');
    expect(find.text('Objectives'), findsOneWidget);
    expect(task, findsOneWidget);

    await _openMobileDestination(tester, 'Tasks');
    expect(find.byType(TasksPage), findsOneWidget);
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
    await _openMobileDestination(tester, 'Tasks');
    expect(find.byType(TasksPage), findsOneWidget);
    expect(task, findsOneWidget);
  });

  testWidgets(
    'Gym mode focuses home while No mode restores the daily overview',
    (tester) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(const EasyApp());
      await tester.pumpAndSettle();
      expect(find.text('Get the outline out first'), findsOneWidget);
      expect(find.text('Upcoming today'), findsOneWidget);
      expect(find.text('Tasks due today'), findsOneWidget);

      await _pickMode(tester, 'Gym');
      expect(find.text('Keep the warm-up repeatable'), findsOneWidget);
      expect(find.text('Objectives'), findsOneWidget);
      expect(find.text('Log today’s working sets'), findsOneWidget);
      expect(find.text('Review the last session'), findsOneWidget);
      expect(find.text('Send the project outline'), findsNothing);
      expect(find.text('Get the outline out first'), findsNothing);

      await _pickMode(tester, 'No mode');
      expect(find.text('Get the outline out first'), findsOneWidget);
      expect(find.text('Tasks due today'), findsOneWidget);
      expect(find.text('Objectives'), findsNothing);
    },
  );

  testWidgets('Existing notes load and a new note to self survives relaunch', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    await SharedPreferencesAsync().setString(
      'easy.workspace.v1',
      '{"events":[],"tasks":[],"notes":['
          '{"id":"legacy","title":"Old note","body":"Still here",'
          '"updated":"2026-01-01T00:00:00.000"}]}',
    );
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    expect(find.text('Old note'), findsNothing);

    await tester.tap(find.text('Write a note'));
    await tester.pumpAndSettle();
    await _submitCapture(tester, 'Leave time to refine the draft', 'Add note');
    expect(find.text('Leave time to refine the draft'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    expect(find.text('Leave time to refine the draft'), findsOneWidget);

    await _openMobileDestination(tester, 'Notes');
    expect(find.byType(NotesPage), findsOneWidget);
    expect(find.text('Old note'), findsOneWidget);
  });

  testWidgets('Gym session resumes with its entries after relaunch', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    await _pickMode(tester, 'Gym');
    await tester.tap(find.text('Start session'));
    await tester.pumpAndSettle();
    expect(find.byType(GymSessionPage), findsOneWidget);
    await tester.tap(find.text('Freestyle'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Stretch');
    await tester.tap(find.byTooltip('Log entry'));
    await tester.pumpAndSettle();
    expect(find.text('Stretch'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const EasyApp());
    await tester.pumpAndSettle();
    await _pickMode(tester, 'Gym');
    await tester.tap(find.text('Resume session'));
    await tester.pumpAndSettle();
    expect(find.text('Stretch'), findsOneWidget);
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

Future<void> _openMobileDestination(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Navigate'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(OrbitNavigation),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pickMode(WidgetTester tester, String mode) async {
  await tester.tap(find.text('Mode'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(MenuItemButton, mode));
  await tester.pumpAndSettle();
}

Future<void> _submitCapture(
  WidgetTester tester,
  String text,
  String tooltip,
) async {
  final input = find.descendant(
    of: find.byType(QuickCapture),
    matching: find.byType(TextFormField),
  );
  await tester.enterText(input, text);
  await tester.pump();
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}
