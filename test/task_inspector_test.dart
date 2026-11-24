import 'package:easy/list_pages.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _title = 'Confirm studio allocation';
const _notes = 'Get the latest floor plan from the venue before the deadline.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Geist',
    )..addFont(rootBundle.load('assets/fonts/Geist.ttf'))).load();
  });

  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(820, 900),
    const Size(1440, 900),
  ]) {
    testWidgets('task inspector preserves due time and notes at $size, 200%', (
      tester,
    ) async {
      final deadline = await _mount(tester, size);
      final mobile = size.width < 720;
      final compactSidebar = size.width >= 720 && size.width < 900;
      if (mobile) {
        await tester.tap(find.byTooltip('Navigate'));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('Tasks').hitTestable().last);
      } else if (compactSidebar) {
        await tester.tap(find.byTooltip('Tasks'));
      } else {
        await tester.tap(find.text('Tasks').first);
      }
      await tester.pumpAndSettle();

      final task = find.descendant(
        of: find.byType(TasksPage),
        matching: find.text(_title),
      );
      await tester.scrollUntilVisible(
        task,
        90,
        scrollable: find.descendant(
          of: find.byType(TasksPage),
          matching: find.byType(Scrollable),
        ),
      );
      await _reveal(tester, task);
      await tester.tap(task.hitTestable());
      await tester.pumpAndSettle();

      final edit = find.widgetWithText(FilledButton, 'Edit');
      await _reveal(tester, edit);
      expect(edit.hitTestable(), findsOneWidget);
      final context = tester.element(edit);
      final localizations = MaterialLocalizations.of(context);
      final due = localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(deadline),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
      final day = localizations.formatFullDate(deadline);
      expect(find.text('Due $day, $due'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Track time')).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Delete')).dy),
      );

      final notes = find.widgetWithText(SelectableText, _notes);
      await _reveal(tester, notes);
      expect(notes.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop search shortcut and submit open the task inspector', (
    tester,
  ) async {
    await _mount(tester, const Size(1440, 900));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final search = find.byType(TextField);
    expect(search, findsOneWidget);
    await tester.enterText(search, 'latest floor plan');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close details'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, _notes), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<DateTime> _mount(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  final platform = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

  final day = dateOnly(DateTime.now());
  final deadline = DateTime(day.year, day.month, day.day, 22, 35);
  final fixture = WorkspaceData(
    events: [],
    notes: [],
    tasks: [
      TaskItem(
        id: 'studio',
        title: _title,
        notes: _notes,
        category: 'work',
        date: day,
        dueAt: deadline.toUtc(),
        estimatedMinutes: 30,
      ),
    ],
  );
  await tester.pumpWidget(
    EasyApp(
      openStore: ({required preferences, required readLegacy}) =>
          openPreferenceWorkspaceStore(
            preferences: preferences,
            readLegacy: () async => WorkspaceSnapshot(
              workspaceJson: fixture.encode(),
              gymSessionJson: const [],
              workoutPlanJson: const [],
            ),
          ),
    ),
  );
  await tester.pumpAndSettle();
  return deadline;
}
