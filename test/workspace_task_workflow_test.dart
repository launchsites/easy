import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/task_capture_defaults.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('saved capture defaults and reviewed project steps reach Tasks', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final platform = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);
    const title = 'Build a website for Alex and send it to Alex';
    final fixture = WorkspaceData(
      events: [],
      tasks: [
        TaskItem(
          id: 'website',
          title: title,
          category: 'work',
          date: dateOnly(DateTime.now()),
        ),
      ],
      notes: [],
      sections: {
        'taskCaptureDefaults': const TaskCaptureDefaults(categoryId: '')
            .toJson(),
      },
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
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Break down'));
    await tester.pumpAndSettle();
    expect(find.text('Build a website for Alex'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add selected'));
    await tester.pumpAndSettle();
    expect(find.text('Subtask added'), findsOneWidget);
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Review studio assets');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add task'));
    await tester.pumpAndSettle();
    expect(find.text('Review studio assets'), findsNothing);
    await tester.tap(find.text('Tasks').first);
    await tester.pumpAndSettle();
    expect(find.text('Review studio assets'), findsOneWidget);
    expect(find.text('Send the website to Alex'), findsOneWidget);
    await tester.tap(find.text('Review studio assets'));
    await tester.pumpAndSettle();
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Build a website for Alex'), findsNothing);
  });
}
