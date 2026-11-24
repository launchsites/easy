import 'dart:async';
import 'dart:convert';

import 'package:easy/calendar_sources/calendar_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _localId = CalendarIdentity(accountId: 'easy', calendarId: 'local');
const _appleId = CalendarIdentity(
  accountId: 'device-account-a',
  calendarId: 'calendar-a',
);
const _unknownId = CalendarIdentity(
  accountId: 'disconnected',
  calendarId: 'another',
);
final _localSource = CalendarSource(
  id: _localId,
  name: 'Local calendar',
  accountName: 'On this device',
  capabilities: [CalendarCapability.read, CalendarCapability.write],
);
final _appleSource = CalendarSource(
  id: _appleId,
  name: 'Shared calendar',
  accountName: 'Account A',
);

void main() {
  test(
    'calendar preferences preserve independent All, mode and write identities',
    () {
      final settings = CalendarSourcePreferences(
        allCalendars: [_appleId],
        memberships: CalendarModeMemberships({
          'work': [_appleId],
          'next': [_unknownId],
        }),
        defaultWriteCalendar: _localId,
      );
      final data =
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>;
      final restored = CalendarSourcePreferences.fromJson(data);
      expect(restored.calendarsFor(null), {_appleId});
      expect(restored.calendarsFor('work'), {_appleId});
      expect(restored.calendarsFor('next'), {_unknownId});
      expect(restored.defaultWriteCalendar, _localId);
      expect(() => restored.allCalendars.clear(), throwsUnsupportedError);
    },
  );

  testWidgets(
    'Apple calendar access is explicit and sources remain read-only',
    (tester) async {
      final adapter = _CalendarAdapter();
      await _showSettings(tester, adapter: adapter);
      expect(adapter.checks, 1);
      expect(adapter.requests, 0);
      expect(adapter.calendarLoads, 0);
      expect(find.text('Allow calendar access'), findsOneWidget);

      await tester.tap(find.text('Allow calendar access'));
      await tester.pumpAndSettle();
      expect(adapter.requests, 1);
      expect(adapter.calendarLoads, 1);
      expect(find.text('Shared calendar'), findsOneWidget);
      expect(find.text('Account A'), findsOneWidget);
      expect(find.text('Read-only access'), findsOneWidget);
      expect(find.text('Default calendar'), findsNothing);
    },
  );

  testWidgets(
    'a calendar can appear in All and several modes and be removed from All only',
    (tester) async {
      CalendarSourcePreferences? selected;
      await _showSettings(
        tester,
        adapter: _CalendarAdapter(access: EventKitCalendarAccess.full),
        onChanged: (settings) => selected = settings,
      );
      await tester.tap(find.text('Shared calendar'));
      await tester.pumpAndSettle();
      for (final name in ['All', 'Work', 'Gym']) {
        await tester.tap(find.widgetWithText(CheckboxListTile, name));
      }
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(selected?.calendarsFor(null), {_appleId});
      expect(selected?.calendarsFor('work'), {_appleId});
      expect(selected?.calendarsFor('gym'), {_appleId});

      await tester.tap(find.text('Shared calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'All'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(selected?.calendarsFor(null), isEmpty);
      expect(selected?.calendarsFor('work'), {_appleId});
      expect(selected?.calendarsFor('gym'), {_appleId});
    },
  );

  testWidgets(
    'default destination lists only writable calendars and can be cleared',
    (tester) async {
      CalendarSourcePreferences? selected;
      await _showSettings(
        tester,
        adapter: _CalendarAdapter(access: EventKitCalendarAccess.full),
        localSources: [_localSource],
        onChanged: (settings) => selected = settings,
      );
      await tester.ensureVisible(find.text('Default calendar'));
      await tester.tap(find.text('Default calendar'));
      await tester.pumpAndSettle();
      final dialog = find.byType(SimpleDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('Shared calendar')),
        findsNothing,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('On this device')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Local calendar')),
      );
      await tester.pumpAndSettle();
      expect(selected?.defaultWriteCalendar, _localId);

      await tester.tap(find.text('Default calendar'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Ask each time')),
      );
      await tester.pumpAndSettle();
      expect(selected?.defaultWriteCalendar, isNull);
    },
  );

  testWidgets('loading and retry keep permission requests separate', (
    tester,
  ) async {
    final pending = Completer<EventKitCalendarAccess>();
    final adapter = _CalendarAdapter(
      access: EventKitCalendarAccess.full,
      failLoads: true,
    )..statusAnswer = pending.future;
    await _showSettings(tester, adapter: adapter, settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(EventKitCalendarAccess.full);
    await tester.pumpAndSettle();
    expect(find.text('Calendar access could not be checked.'), findsOneWidget);
    adapter.failLoads = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Shared calendar'), findsOneWidget);
    expect(adapter.requests, 0);
  });

  testWidgets('local calendars stay configurable on other platforms', (
    tester,
  ) async {
    final adapter = _CalendarAdapter(supported: false);
    await _showSettings(tester, adapter: adapter, localSources: [_localSource]);
    expect(find.text('Available on iPhone, iPad and Mac.'), findsOneWidget);
    expect(find.text('Local calendar'), findsOneWidget);
    expect(find.text('On this device'), findsOneWidget);
    expect(adapter.checks, 0);
    expect(adapter.calendarLoads, 0);
  });

  testWidgets(
    'source account and mode choices fit a small screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 570);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _showSettings(
        tester,
        adapter: _CalendarAdapter(access: EventKitCalendarAccess.full),
        textScale: 2,
      );
      await tester.ensureVisible(find.text('Shared calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shared calendar'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('Account A')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'Gym'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Gym'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _showSettings(
  WidgetTester tester, {
  required _CalendarAdapter adapter,
  Iterable<CalendarSource> localSources = const [],
  ValueChanged<CalendarSourcePreferences>? onChanged,
  bool settle = true,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CalendarSettingsPage(
        initialPreferences: CalendarSourcePreferences(),
        onChanged: onChanged ?? (_) {},
        modes: const {'work': 'Work', 'gym': 'Gym'},
        localSources: localSources,
        adapter: adapter,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

class _CalendarAdapter extends EventKitCalendarAdapter {
  _CalendarAdapter({
    this.access = EventKitCalendarAccess.unknown,
    this.failLoads = false,
    this.supported = true,
  });

  EventKitCalendarAccess access;
  Future<EventKitCalendarAccess>? statusAnswer;
  final bool supported;
  bool failLoads;
  int checks = 0;
  int requests = 0;
  int calendarLoads = 0;

  @override
  bool get isAvailable => supported;

  @override
  Future<EventKitCalendarAccess> accessStatus() async {
    checks++;
    return statusAnswer ?? access;
  }

  @override
  Future<EventKitCalendarAccess> requestReadAccess() async {
    requests++;
    return access = EventKitCalendarAccess.full;
  }

  @override
  Future<List<CalendarSource>> calendars() async {
    calendarLoads++;
    if (failLoads) throw StateError('Synthetic failure');
    return [_appleSource];
  }
}
