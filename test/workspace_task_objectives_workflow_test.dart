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
  for (final knownTime in [false, true]) {
    testWidgets(
      'Today shows a read-only task review with known time $knownTime',
      (tester) async {
        final oldPlatform = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(
          () => SharedPreferencesAsyncPlatform.instance = oldPlatform,
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final today = dateOnly(DateTime.now());
        const title = 'Outline next month’s content';
        final data = WorkspaceData(
          tasks: [
            TaskItem(
              id: 'content-fixture',
              title: title,
              category: 'work',
              date: today,
              estimatedMinutes: 20,
            ),
          ],
          events: [],
          notes: [],
          sections: {
            if (knownTime)
              'schedulingSettings': SchedulingSettings(
                availability: [
                  WeeklyAvailability(
                    id: 'work-hours',
                    weekdays: [1, 2, 3, 4, 5, 6, 7],
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

        await tester.tap(find.text('What fits now'));
        final suggestion = find.byType(Dialog);
        for (var i = 0; i < 100 && suggestion.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('What can I work on?'), findsOneWidget);
        if (knownTime) {
          expect(find.textContaining('min available'), findsOneWidget);
        } else {
          expect(find.text('Available time is unverified'), findsOneWidget);
        }
        expect(
          find.descendant(of: suggestion, matching: find.text('Plan day')),
          findsOneWidget,
        );
        final row = find.descendant(of: suggestion, matching: find.text(title));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(suggestion, findsNothing);
        expect(find.byTooltip('Close details'), findsOneWidget);

        final store = await openPreferenceWorkspaceStore(
          preferences: prefs,
          readLegacy: () async =>
              throw StateError('Expected the opened workspace'),
        );
        final stored = await store.read();
        expect(stored.revision, 1);
        expect(
          WorkspaceData.decode(stored.snapshot.workspaceJson).events,
          isEmpty,
        );
        await store.close();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
