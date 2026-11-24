import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('the workspace repeats, completes, reopens and skips a task', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = oldPreferences);
    const title = 'Check the studio schedule';
    final fixture = WorkspaceData(
      events: [],
      tasks: [
        TaskItem(
          id: 'studio',
          title: title,
          category: '',
          date: dateOnly(DateTime.now()),
        ),
      ],
      notes: [],
    );
    final app = EasyApp(
      openStore: ({required preferences, required readLegacy}) =>
          openPreferenceWorkspaceStore(
            preferences: preferences,
            readLegacy: () async => WorkspaceSnapshot(
              workspaceJson: fixture.encode(),
              gymSessionJson: const [],
              workoutPlanJson: const [],
            ),
          ),
    );
    Future<void> restart() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeat'));
    await tester.pumpAndSettle();
    expect(find.text('Repeat task'), findsOneWidget);
    await tester.tap(find.text('Save repeat settings'));
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    final details = find.byKey(const ValueKey('desktop-record-detail'));
    expect(find.text('Repeating task'), findsOneWidget);
    expect(find.text('Repeat rule'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('Task completed'), findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.text('Completed')),
      findsOneWidget,
    );
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    await restart();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: details, matching: find.text('Open')),
      findsOneWidget,
    );

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This occurrence'));
    await tester.pumpAndSettle();
    expect(find.text(title), findsNothing);
    await restart();
    expect(find.text(title), findsNothing);
    await tester.tap(find.text('Tasks').first);
    await tester.pumpAndSettle();
    expect(find.text(title), findsWidgets);
  });
}
