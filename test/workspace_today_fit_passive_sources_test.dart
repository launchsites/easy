import 'dart:async';

import 'package:easy/calendar_sources/apple_calendar_feed.dart';
import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/calendar_settings_page.dart';
import 'package:easy/calendar_sources/event_kit_calendar_adapter.dart';
import 'package:easy/calendar_sources/ics_workspace.dart';
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

const _apple = CalendarIdentity(accountId: 'apple-test', calendarId: 'studio');
const _missing = CalendarIdentity(
  accountId: 'apple-test',
  calendarId: 'absent',
);
const _taskTitle = 'Send updated studio hours';
const _eventTitle = 'Studio appointment';

void main() {
  testWidgets('Apple coverage invalidates before its cached events change', (
    tester,
  ) async {
    final now = DateTime.now();
    final event = _appleEvent(now, ended: true);
    final adapter = _AppleFixture([event]);
    addTearDown(adapter.close);
    final feed = AppleCalendarFeed(adapter: adapter);
    addTearDown(feed.dispose);
    final changes = <bool>[];
    feed.addListener(() => changes.add(feed.hasCurrentCoverage));

    await feed.refresh(day: dateOnly(now), selected: {_apple});
    expect(feed.hasCurrentCoverage, isTrue);
    final cached = feed.events;

    final next = Completer<List<SourcedCalendarEvent<ExternalCalendarEvent>>>();
    adapter.heldQuery = next;
    adapter.changed();
    expect(changes.last, isFalse);
    expect(feed.events, same(cached));
    expect(feed.loading, isFalse);
    expect(adapter.queried, hasLength(1));

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(feed.loading, isTrue);
    expect(feed.hasCurrentCoverage, isFalse);
    expect(feed.events, same(cached));
    expect(adapter.queried, hasLength(2));

    next.complete([event]);
    await tester.pump();
    expect(feed.hasCurrentCoverage, isTrue);
    expect(changes.last, isTrue);
    expect(feed.events, isNot(same(cached)));
  });

  testWidgets('Apple changes withdraw a verified fit before the next query', (
    tester,
  ) async {
    final now = DateTime.now();
    final confirmed = _appleEvent(now, ended: true);
    final adapter = _AppleFixture([confirmed]);
    addTearDown(adapter.close);
    await _openToday(tester, now, selected: [_apple], adapter: adapter);
    final fit = find.text('Fits now');
    await _wait(tester, until: () => fit.evaluate().isNotEmpty);
    if (_canFitMinute(now)) expect(fit, findsOneWidget);
    expect(adapter.queried, [
      {_apple},
    ]);

    final next = Completer<List<SourcedCalendarEvent<ExternalCalendarEvent>>>();
    adapter.heldQuery = next;
    adapter.changed();
    await tester.pump();
    expect(fit, findsNothing);
    expect(adapter.queried, hasLength(1));

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(adapter.queried, hasLength(2));
    expect(fit, findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fit, findsNothing);

    next.complete([confirmed]);
    await _wait(tester, until: () => fit.evaluate().isNotEmpty);
    if (_canFitMinute(now)) expect(fit, findsOneWidget);
    expect(adapter.queried, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('A tentative Apple appointment leaves its calendar unverified', (
    tester,
  ) async {
    final now = DateTime.now();
    final adapter = _AppleFixture([
      _appleEvent(
        now.add(const Duration(minutes: 30)),
        status: CalendarEventStatus.tentative,
      ),
    ]);
    addTearDown(adapter.close);
    await _openToday(tester, now, selected: [_apple], adapter: adapter);
    await _wait(tester);
    expect(adapter.queried, [
      {_apple},
    ]);
    expect(find.text('Fits now'), findsNothing);
  });

  testWidgets('A free Apple appointment remains visible without blocking fit', (
    tester,
  ) async {
    final now = DateTime.now();
    final adapter = _AppleFixture([
      _appleEvent(now, status: CalendarEventStatus.unknown, blocksTime: false),
    ]);
    addTearDown(adapter.close);
    await _openToday(tester, now, selected: [_apple], adapter: adapter);
    final fit = find.text('Fits now');
    await _wait(tester, until: () => fit.evaluate().isNotEmpty);
    if (_canFitMinute(now)) expect(fit, findsOneWidget);
    expect(find.text(_eventTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('An unavailable selected Apple calendar leaves time unverified', (
    tester,
  ) async {
    final now = DateTime.now();
    final adapter = _AppleFixture([_appleEvent(now, ended: true)]);
    addTearDown(adapter.close);
    await _openToday(
      tester,
      now,
      selected: [_apple, _missing],
      adapter: adapter,
    );
    await _wait(tester);
    expect(adapter.queried, [
      {_apple, _missing},
    ]);
    expect(find.text('Fits now'), findsNothing);
  });

  for (final (status, ended) in [
    ('CONFIRMED', false),
    ('TENTATIVE', false),
    (null, false),
    (null, true),
    ('CANCELLED', false),
    ('invalid', false),
  ]) {
    testWidgets(
      'Today uses a saved iCalendar event with status $status, ended $ended',
      (tester) async {
        final now = DateTime.now();
        final imported = WorkspaceIcsCalendar(
          id: 'studio-file',
          name: 'Studio file',
          document: status == 'invalid'
              ? 'This file does not contain an iCalendar document.'
              : _calendarDocument(now, status, ended: ended),
        );
        await _openToday(
          tester,
          now,
          selected: [imported.identity],
          imports: [imported],
        );
        final fit = find.text('Fits now');
        if (status == 'CANCELLED' || ended) {
          await _wait(tester, until: () => fit.evaluate().isNotEmpty);
          if (_canFitMinute(now)) expect(fit, findsOneWidget);
        } else {
          await _wait(tester);
          expect(fit, findsNothing);
          if (status != 'invalid') {
            expect(find.text(_eventTitle), findsOneWidget);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('A transparent import stays on Today without blocking fit', (
    tester,
  ) async {
    final now = DateTime.now();
    final source = WorkspaceIcsCalendar(
      id: 'studio-file',
      name: 'Studio file',
      document: _calendarDocument(
        now,
        'TENTATIVE',
        ended: false,
        transparent: true,
      ),
    );
    await _openToday(
      tester,
      now,
      selected: [source.identity],
      imports: [source],
    );
    final fit = find.text('Fits now');
    await _wait(tester, until: () => fit.evaluate().isNotEmpty);
    expect(find.text(_eventTitle), findsOneWidget);
    if (_canFitMinute(now)) expect(fit, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

bool _canFitMinute(DateTime now) =>
    plusDays(dateOnly(now), 1).difference(now) >
    const Duration(minutes: 1, seconds: 5);

Future<void> _openToday(
  WidgetTester tester,
  DateTime now, {
  required List<CalendarIdentity> selected,
  EventKitCalendarAdapter adapter = const EventKitCalendarAdapter(),
  List<WorkspaceIcsCalendar> imports = const [],
}) async {
  final previous = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final day = dateOnly(now);
  await SharedPreferencesAsync().setString(
    'easy.workspace.v1',
    WorkspaceData(
      tasks: [
        TaskItem(
          id: 'studio-hours',
          title: _taskTitle,
          category: 'work',
          date: day,
          estimatedMinutes: 1,
        ),
      ],
      events: [],
      notes: [],
      sections: {
        'calendarPreferences': CalendarSourcePreferences(allCalendars: selected)
            .toJson(),
        if (imports.isNotEmpty)
          'importedCalendars': [
            for (final calendar in imports) calendar.toJson(),
          ],
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
    ).encode(),
  );
  await tester.pumpWidget(
    EasyApp(openStore: openPreferenceWorkspaceStore, calendarAdapter: adapter),
  );
  await tester.pumpAndSettle();
  expect(find.text(_taskTitle), findsOneWidget);
}

Future<void> _wait(WidgetTester tester, {bool Function()? until}) async {
  for (var index = 0; index < 50 && !(until?.call() ?? false); index++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

SourcedCalendarEvent<ExternalCalendarEvent> _appleEvent(
  DateTime now, {
  bool ended = false,
  CalendarEventStatus status = CalendarEventStatus.confirmed,
  bool blocksTime = true,
}) => SourcedCalendarEvent(
  id: const CalendarOccurrenceIdentity(
    calendar: _apple,
    eventId: 'appointment',
  ),
  event: ExternalCalendarEvent(
    title: _eventTitle,
    start: now.subtract(const Duration(minutes: 10)).toUtc(),
    end: now.add(Duration(minutes: ended ? -5 : 15)).toUtc(),
    allDay: false,
    blocksTime: blocksTime,
    status: status,
  ),
);

String _calendarDocument(
  DateTime now,
  String? status, {
  required bool ended,
  bool transparent = false,
}) {
  String stamp(DateTime instant) {
    final seconds = instant.toUtc().toIso8601String().split('.').first;
    return '${seconds.replaceAll(RegExp('[-:]'), '')}Z';
  }

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Easy Test//Calendar Fixture//EN',
    'BEGIN:VEVENT',
    'UID:studio-appointment@test.invalid',
    'DTSTAMP:${stamp(now)}',
    'DTSTART:${stamp(now.subtract(const Duration(minutes: 10)))}',
    'DTEND:${stamp(now.add(Duration(minutes: ended ? -5 : 15)))}',
    'SUMMARY:$_eventTitle',
    if (status != null) 'STATUS:$status',
    if (transparent) 'TRANSP:TRANSPARENT',
    'END:VEVENT',
    'END:VCALENDAR',
    '',
  ].join('\r\n');
}

class _AppleFixture extends EventKitCalendarAdapter {
  _AppleFixture(this.initial);

  final List<SourcedCalendarEvent<ExternalCalendarEvent>> initial;
  final queried = <Set<CalendarIdentity>>[];
  final _changes = StreamController<void>.broadcast(sync: true);
  Completer<List<SourcedCalendarEvent<ExternalCalendarEvent>>>? heldQuery;

  @override
  bool get isAvailable => true;

  @override
  Future<EventKitCalendarAccess> accessStatus() async =>
      EventKitCalendarAccess.full;

  @override
  Future<EventKitCalendarAccess> requestReadAccess() =>
      throw StateError('Today must use the already-authorized calendar feed.');

  @override
  Future<List<CalendarSource>> calendars() async => [
    CalendarSource(id: _apple, name: 'Studio Calendar', accountName: 'Fixture'),
  ];

  @override
  Future<List<SourcedCalendarEvent<ExternalCalendarEvent>>> events({
    required DateTime start,
    required DateTime end,
    Iterable<CalendarIdentity>? calendars,
  }) async {
    queried.add(calendars!.toSet());
    return await heldQuery?.future ?? initial;
  }

  @override
  Stream<void> get changes => _changes.stream;

  void changed() => _changes.add(null);

  Future<void> close() => _changes.close();
}
