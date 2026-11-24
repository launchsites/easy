import 'package:easy/activities/activities.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('confirmed schedule writes actual time with its original plan', (
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

    final start = plusDays(
      dateOnly(DateTime.now()),
      -1,
    ).add(const Duration(hours: 9));
    final end = start.add(const Duration(minutes: 40));
    final planned = start.subtract(const Duration(hours: 1));
    const title = 'Studio sessions';
    final workspace = WorkspaceData(
      events: [
        CalendarEvent(
          id: 'past',
          title: title,
          category: 'work',
          start: start,
          end: end,
          plannedTaskId: 'studio',
          initialPlannedStart: planned,
          initialPlannedEnd: planned.add(const Duration(minutes: 30)),
        ),
      ],
      tasks: [],
      notes: [],
    );
    late WorkspaceStore store;
    await tester.pumpWidget(
      EasyApp(
        openStore: ({required preferences, required readLegacy}) async {
          return store = await openPreferenceWorkspaceStore(
            preferences: preferences,
            readLegacy: () async => WorkspaceSnapshot(
              workspaceJson: workspace.encode(),
              gymSessionJson: const [],
              workoutPlanJson: const [],
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    final initial = await store.read();
    await tester.tap(find.text('Search workspace'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'type:event studio sessions',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use scheduled times'));
    await tester.pumpAndSettle();
    expect((await store.read()).revision, initial.revision);
    await tester.tap(find.text('Confirm scheduled times'));
    await tester.pumpAndSettle();

    final logged = WorkspaceData.decode(
      (await store.read()).snapshot.workspaceJson,
    );
    final actual = ActivityData.fromJson(
      logged.sections['activities']! as Map<String, Object?>,
    ).records.single;
    expect(actual.timeSource, ActivityTimeSource.confirmedSchedule);
    expect(actual.target?.id, 'past');
    expect(actual.plan?.start.toLocal(), planned);
    expect(actual.spans.single.end?.toLocal(), end);
    expect(logged.events.single.start.toLocal(), start);
  });
}
