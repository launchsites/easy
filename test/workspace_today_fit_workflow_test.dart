import 'package:easy/calendar_page.dart';
import 'package:easy/main.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  for (final (viewport, occupied) in [
    (const Size(390, 844), false),
    (const Size(1440, 900), false),
    (const Size(390, 844), true),
  ]) {
    testWidgets('Today flags only a verified free gap at $viewport $occupied', (
      tester,
    ) async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final now = DateTime.now();
      final day = dateOnly(now);
      final hasTime =
          !occupied &&
          plusDays(day, 1).difference(now) >
              const Duration(minutes: 1, seconds: 4);
      const taskId = 'small-work';
      const title = 'Send the studio notes';
      final data = WorkspaceData(
        tasks: [
          TaskItem(
            id: taskId,
            title: title,
            category: 'work',
            date: day,
            estimatedMinutes: 1,
          ),
        ],
        events: [
          if (occupied)
            CalendarEvent(
              id: 'fixed',
              title: 'Booked appointment',
              start: now.subtract(const Duration(minutes: 1)),
              end: now.add(const Duration(minutes: 15)),
              category: 'work',
            ),
        ],
        notes: [],
        sections: {
          'schedulingSettings': SchedulingSettings(
            availability: [
              WeeklyAvailability(
                id: 'work-hours',
                weekdays: [day.weekday],
                startMinute: 0,
                endMinute: 1440,
                categories: ['work'],
              ),
            ],
          ).toJson(),
        },
      );
      final prefs = SharedPreferencesAsync();
      await prefs.setString('easy.workspace.v1', data.encode());
      await tester.pumpWidget(
        const EasyApp(openStore: openPreferenceWorkspaceStore),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.text('Fits now'), hasTime ? findsOneWidget : findsNothing);
      final store = await openPreferenceWorkspaceStore(
        preferences: prefs,
        readLegacy: () async =>
            throw StateError('Expected the seeded workspace'),
      );
      final before = await store.read();
      expect(before.revision, 1);
      expect(
        WorkspaceData.decode(before.snapshot.workspaceJson).tasks.single.done,
        isFalse,
      );

      if (hasTime) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mark done'));
        await tester.pumpAndSettle();
        expect(find.text('Fits now'), findsNothing);
        expect(
          WorkspaceData.decode((await store.read()).snapshot.workspaceJson)
              .tasks
              .single
              .done,
          isTrue,
        );
      }
      await store.close();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
}
