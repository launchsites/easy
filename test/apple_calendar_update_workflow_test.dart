import 'package:easy/calendar_page.dart';
import 'package:easy/calendar_sources/event_kit_calendar_adapter.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets(
    'Apple copy update requires selection and remembers the new version',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final platform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = platform);

      const bridge = MethodChannel('easy/event_kit_calendar');
      const identity = {
        'accountId': 'work-account',
        'calendarId': 'work-calendar',
        'eventId': 'apple-event',
      };
      final original = 'a' * 64;
      final updated = 'b' * 64;
      final start = dateOnly(DateTime.now())
          .add(const Duration(hours: 10))
          .toUtc();
      final end = start.add(const Duration(hours: 1));
      const title = 'Revised studio appointment';
      const note = 'Review the draft before the meeting.';
      var attempts = 0;
      var writes = 0;
      var notesSelected = false;

      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        switch (call.method) {
          case 'accessStatus':
            return 'full';
          case 'prepareUpdate':
            final arguments = call.arguments as Map;
            expect(arguments['target'], identity);
            expect(
              arguments['expectedRevision'],
              writes == 0 ? original : updated,
            );
            expect(arguments['scope'], {
              'location': false,
              'notes': notesSelected,
            });
            final draft = arguments['draft'] as Map;
            expect(draft['title'], title);
            expect(draft.containsKey('location'), isFalse);
            expect(draft['notes'], notesSelected ? note : null);
            return {
              ...identity,
              'name': 'Work calendar',
              'accountName': 'Test account',
              'canWrite': true,
              'reviewToken': 'review-${attempts++}',
              'revision': writes == 0 ? original : updated,
              'startMilliseconds': start.millisecondsSinceEpoch,
              'endMilliseconds': end.millisecondsSinceEpoch,
              'before': {
                ...identity,
                'title': 'Original appointment',
                'allDay': false,
                'recurring': false,
                'startMilliseconds': start.millisecondsSinceEpoch,
                'endMilliseconds': end.millisecondsSinceEpoch,
                if (notesSelected) 'notes': 'Older notes',
              },
            };
          case 'updateReviewedEvent':
            expect(call.arguments, {
              'reviewToken': 'review-1',
              'confirmed': true,
            });
            writes++;
            return {...identity, 'revision': updated};
          default:
            fail('Unexpected Apple Calendar action ${call.method}');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(bridge, null));
      final workspace = WorkspaceData(
        events: [
          CalendarEvent(
            id: 'local-event',
            title: title,
            start: start,
            end: end,
            category: 'work',
            location: 'Private room',
            description: note,
          ),
        ],
        tasks: [],
        notes: [],
        sections: {
          'appleCalendarCopies': {
            'local-event': {...identity, 'revision': original},
          },
        },
      );
      late WorkspaceStore store;
      await tester.pumpWidget(
        EasyApp(
          calendarAdapter: const EventKitCalendarAdapter(
            platform: TargetPlatform.iOS,
          ),
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
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();

      Future<void> preview({bool includeNotes = false}) async {
        await tester.tap(find.text('Update Apple copy'));
        await tester.pumpAndSettle();
        notesSelected = includeNotes;
        if (includeNotes) await tester.tap(find.text('Include notes'));
        await tester.tap(find.text('Review update'));
        await tester.pumpAndSettle();
        expect(find.text('Current in Apple Calendar'), findsOneWidget);
        expect(find.text('After update'), findsOneWidget);
      }

      await preview();
      expect(writes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await preview(includeNotes: true);
      expect(find.text('Older notes'), findsOneWidget);
      await tester.tap(find.text('Update calendar'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      final state = WorkspaceData.decode(
        (await store.read()).snapshot.workspaceJson,
      );
      final copies = state.sections['appleCalendarCopies'] as Map;
      expect((copies['local-event'] as Map)['revision'], updated);
      expect(state.events.single.description, note);
    },
  );
}
