import 'package:easy/calendar_sources/event_kit_calendar_adapter.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  testWidgets('a local event is copied exactly once only after Apple review', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

    const bridge = MethodChannel('easy/event_kit_calendar');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    const target = {
      'accountId': 'fake-account',
      'calendarId': 'fake-calendar',
      'name': 'Personal calendar',
      'accountName': 'Test account',
      'canWrite': true,
    };
    messenger.setMockMethodCallHandler(bridge, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'accessStatus':
          return 'full';
        case 'calendars':
          return [target];
        case 'prepareCreate':
          final arguments = call.arguments as Map;
          final draft = arguments['draft'] as Map;
          expect(draft['title'], 'Studio review');
          return {
            ...target,
            'reviewToken': 'checked-on-device',
            'startMilliseconds': draft['startMilliseconds'],
            'endMilliseconds': draft['endMilliseconds'],
            'timeZoneId': 'Europe/London',
          };
        case 'createReviewedEvent':
          expect(call.arguments, {
            'reviewToken': 'checked-on-device',
            'confirmed': true,
          });
          return {...target, 'eventId': 'created-once'};
        default:
          fail('Unexpected method ${call.method}');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(bridge, null));
    const app = EasyApp(
      openStore: openPreferenceWorkspaceStore,
      calendarAdapter: EventKitCalendarAdapter(platform: TargetPlatform.iOS),
    );

    Future<void> showCopyReview() async {
      await tester.tap(find.text('Copy to Apple Calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Personal calendar'));
      await tester.pumpAndSettle();
      expect(find.text('Copy to Apple Calendar?'), findsOneWidget);
      expect(find.text('Personal calendar · Test account'), findsOneWidget);
      expect(find.text('Europe/London'), findsOneWidget);
    }

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('Studio review'));
    await tester.pumpAndSettle();
    await showCopyReview();
    expect(calls.where((method) => method == 'createReviewedEvent'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.where((method) => method == 'createReviewedEvent'), isEmpty);
    await showCopyReview();
    await tester.tap(find.text('Add to calendar'));
    await tester.pumpAndSettle();
    expect(
      calls.where((method) => method == 'createReviewedEvent'),
      hasLength(1),
    );
    expect(calls, isNot(contains('requestReadAccess')));
    expect(find.text('Copy to Apple Calendar'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Studio review'));
    await tester.pumpAndSettle();
    expect(find.text('Copy to Apple Calendar'), findsNothing);
  });
}
