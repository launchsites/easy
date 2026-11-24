import 'dart:async';

import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/calendar_settings_page.dart';
import 'package:easy/calendar_sources/event_kit_calendar_adapter.dart';
import 'package:easy/main.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _calendar = CalendarIdentity(
  accountId: 'fixture-account',
  calendarId: 'fixture-calendar',
);
const _title = 'Private calendar fixture';
const _body = 'Private appointment details';

void main() {
  for (final (viewport, search) in [
    (const Size(390, 844), false),
    (const Size(1440, 900), false),
    (const Size(1440, 900), true),
  ]) {
    testWidgets(
      'Revocation clears a live Apple projection on $viewport, search $search',
      (tester) async {
        final previous = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final adapter = _AppleFixture();
        addTearDown(adapter.close);
        final data = WorkspaceData(
          tasks: [],
          notes: [],
          events: [],
          sections: {
            'calendarPreferences': CalendarSourcePreferences(
              allCalendars: [_calendar],
            ).toJson(),
          },
        );
        await SharedPreferencesAsync().setString(
          'easy.workspace.v1',
          data.encode(),
        );
        await tester.pumpWidget(
          EasyApp(
            openStore: openPreferenceWorkspaceStore,
            calendarAdapter: adapter,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(_title), findsOneWidget);
        if (search) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          final dialog = find.byType(Dialog);
          await tester.enterText(
            find.descendant(of: dialog, matching: find.byType(TextField)),
            'Private calendar',
          );
          await tester.pump(const Duration(milliseconds: 120));
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: dialog, matching: find.text(_title)),
            findsOneWidget,
          );
        } else {
          await tester.tap(find.text(_title));
          await tester.pumpAndSettle();
          expect(find.text(_body), findsOneWidget);
        }

        adapter.revoked = true;
        adapter.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(adapter.queries, 2);
        expect(find.text(_title), findsNothing);
        expect(find.text(_body), findsNothing);
        if (search) {
          expect(find.byType(Dialog), findsOneWidget);
          expect(find.text('Private calendar'), findsOneWidget);
        } else if (viewport.width < 720) {
          expect(
            find.text('This Apple Calendar event is unavailable.'),
            findsOneWidget,
          );
        } else {
          expect(find.byTooltip('Close details'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _AppleFixture extends EventKitCalendarAdapter {
  final _changes = StreamController<void>.broadcast();
  bool revoked = false;
  int queries = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<EventKitCalendarAccess> accessStatus() async =>
      EventKitCalendarAccess.full;

  @override
  Future<EventKitCalendarAccess> requestReadAccess() =>
      throw StateError('The feed must never request access by itself.');

  @override
  Future<List<CalendarSource>> calendars() async => [
    CalendarSource(
      id: _calendar,
      name: 'Selected calendar',
      accountName: 'Fixture',
    ),
  ];

  @override
  Future<List<SourcedCalendarEvent<ExternalCalendarEvent>>> events({
    required DateTime start,
    required DateTime end,
    Iterable<CalendarIdentity>? calendars,
  }) async {
    queries++;
    expect(calendars?.toSet(), {_calendar});
    if (revoked) throw PlatformException(code: 'calendar_access');
    final now = DateTime.now();
    return [
      SourcedCalendarEvent(
        id: const CalendarOccurrenceIdentity(
          calendar: _calendar,
          eventId: 'appointment',
        ),
        event: ExternalCalendarEvent(
          title: _title,
          start: now.subtract(const Duration(minutes: 10)).toUtc(),
          end: now.add(const Duration(minutes: 50)).toUtc(),
          allDay: false,
          notes: _body,
          status: CalendarEventStatus.confirmed,
        ),
      ),
    ];
  }

  @override
  Stream<void> get changes => _changes.stream;

  void changed() => _changes.add(null);

  Future<void> close() => _changes.close();
}
