import 'dart:convert';

import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/focus/focus_mode.dart';
import 'package:easy/focus/focus_suggestion_action.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _start = DateTime.utc(2026, 11, 24, 9);
final _end = DateTime.utc(2026, 11, 24, 10);
final _on = FocusSuggestionPreferences(enabled: true);
final _work = FocusMode(
  id: 'work',
  name: 'Work',
  color: 0xff356453,
  categories: {'work'},
);
final _study = FocusMode(
  id: 'study',
  name: 'Study',
  color: 0xff394968,
  categories: {'study'},
);
const _workCalendar = CalendarIdentity(
  accountId: 'easy-local',
  calendarId: 'work',
);
const _private = CalendarIdentity(
  accountId: 'private-account',
  calendarId: 'a-calendar',
);

FocusSuggestionEvent _local({
  String id = 'work-plan',
  String category = 'work',
  bool accepted = true,
  bool allDay = false,
}) => FocusSuggestionEvent.local(
  id: id,
  category: category,
  start: _start,
  end: _end,
  calendar: _workCalendar,
  accepted: accepted,
  allDay: allDay,
);

FocusSuggestionEvent _sourced({
  String recurrenceId = 'occurrence-a',
  bool accepted = true,
}) => FocusSuggestionEvent.sourced(
  id: CalendarOccurrenceIdentity(
    calendar: _private,
    eventId: 'event-from-private-calendar',
    recurrenceId: recurrenceId,
  ),
  start: _start,
  end: _end,
  accepted: accepted,
);

FocusSuggestion? _find({
  FocusSuggestionPreferences? status,
  List<FocusMode>? modes,
  Iterable<FocusSuggestionEvent>? events,
  CalendarModeMemberships? memberships,
  DateTime? now,
  String? currentMode,
  bool activity = false,
  bool workout = false,
  bool Function(FocusMode, String)? categoryMatch,
}) => suggestFocusMode(
  preferences: status ?? _on,
  modes: modes ?? [_work, _study],
  events: events ?? [_local()],
  memberships: memberships,
  now: now ?? _start,
  currentModeId: currentMode,
  activityInProgress: activity,
  workoutInProgress: workout,
  matchesLocalCategory: categoryMatch,
);

void main() {
  test(
    'settings start disabled and busy state does not inspect event content',
    () {
      Iterable<FocusSuggestionEvent> blocked() sync* {
        throw StateError(
          'Event input inspected while suggestions were blocked.',
        );
      }

      expect(
        _find(status: FocusSuggestionPreferences(), events: blocked()),
        isNull,
      );
      expect(_find(activity: true, events: blocked()), isNull);
      expect(_find(workout: true, events: blocked()), isNull);
      expect(_find(currentMode: 'work'), isNull);
    },
  );

  test(
    'only a timed accepted occurrence with a visible category match qualifies',
    () {
      expect(
        _find(now: _start.subtract(const Duration(microseconds: 1))),
        isNull,
      );
      expect(_find(now: _end), isNull);
      expect(_find(now: _start)?.mode.id, 'work');
      expect(_find(events: [_local(accepted: false)]), isNull);
      expect(_find(events: [_local(allDay: true)]), isNull);
      expect(_find(modes: [_study]), isNull);
      expect(_find(memberships: CalendarModeMemberships({'work': {}})), isNull);
      expect(
        _find(
          events: [_local(category: 'writing')],
          memberships: CalendarModeMemberships({
            'work': {_workCalendar},
          }),
          categoryMatch: (mode, category) =>
              mode.id == 'work' && category == 'writing',
        )?.mode.id,
        'work',
      );
    },
  );

  test(
    'multiple rows or destinations abstain, exact repeated rows deduplicate',
    () {
      expect(_find(events: [_local(), _local()])?.mode.id, 'work');
      expect(
        _find(
          events: [
            _local(),
            _local(id: 'other-active-work'),
          ],
        ),
        isNull,
      );
      final peer = FocusMode(
        id: 'side',
        name: 'Side project',
        color: 0xff2f5f87,
        categories: {'work'},
      );
      expect(_find(modes: [_work, peer]), isNull);
    },
  );

  test('private feeds require the exact source identity and an explicit mode assignment', () {
    expect(_find(events: [_sourced()]), isNull);
    const wrongAccount = CalendarIdentity(
      accountId: 'other-local-account',
      calendarId: 'a-calendar',
    );
    expect(
      _find(
        events: [_sourced()],
        memberships: CalendarModeMemberships({
          'work': {wrongAccount},
        }),
      ),
      isNull,
    );
    final chosen = CalendarModeMemberships({
      'study': {_private},
    });
    expect(_find(events: [_sourced()], memberships: chosen)?.mode.id, 'study');
    expect(
      _find(events: [_sourced(accepted: false)], memberships: chosen),
      isNull,
    );
    expect(
      _find(
        events: [_sourced()],
        memberships: CalendarModeMemberships({
          'work': {_private},
          'study': {_private},
        }),
      ),
      isNull,
    );
  });

  test('fall-back hours use exact instants and stale review checks the valid window', () {
    final start = DateTime.parse('2026-11-01T01:15:00-04:00');
    final end = DateTime.parse('2026-11-01T01:45:00-04:00');
    final occurrence = FocusSuggestionEvent.local(
      id: 'fold',
      category: 'work',
      start: start,
      end: end,
    );
    final first = _find(
      events: [occurrence],
      now: DateTime.parse('2026-11-01T01:30:00-04:00'),
    )!;
    expect(first.activeFrom, start);
    expect(
      _find(
        events: [occurrence],
        now: DateTime.parse('2026-11-01T01:30:00-05:00'),
      ),
      isNull,
    );
    final moved = FocusSuggestionEvent.local(
      id: 'fold',
      category: 'work',
      start: start,
      end: _end,
    );
    expect(first.matches(_find(events: [moved], now: start)!), isFalse);
  });

  test(
    'dismissed occurrence is private, bounded and survives device reload',
    () async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      final raw = SharedPreferencesAsync();
      final store = FocusSuggestionSettingsStore(raw);
      expect((await store.load()).enabled, isFalse);
      final chosen = CalendarModeMemberships({
        'study': {_private},
      });
      final first = _find(events: [_sourced()], memberships: chosen)!;
      await store.save(_on.dismissing(first));
      final restored = await FocusSuggestionSettingsStore(raw).load();
      expect(restored.enabled, isTrue);
      expect(
        _find(status: restored, events: [_sourced()], memberships: chosen),
        isNull,
      );
      expect(
        _find(
          status: restored,
          events: [_sourced(recurrenceId: 'new-occurrence')],
          memberships: chosen,
        ),
        isNotNull,
      );
      final serialized = jsonEncode(restored.toJson());
      expect(serialized, isNot(contains('private-account')));
      expect(serialized, isNot(contains('event-from-private-calendar')));
      expect(serialized, isNot(contains('Study')));
      var retained = restored;
      for (var item = 0; item < 80; item++) {
        retained = retained.dismissing(_find(events: [_local(id: '$item')])!);
      }
      expect(retained.toJson()['dismissed'] as List, hasLength(64));
    },
  );

  testWidgets('only a deliberate tap accepts or dismisses the compact action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final longMode = FocusMode(
      id: 'long-mode',
      name: 'Longer personal work mode',
      color: 0xff356453,
      categories: {'work'},
    );
    final suggestion = _find(modes: [longMode])!;
    var accepted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: FocusSuggestionAction(
              suggestion: suggestion,
              onAccept: () => accepted++,
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      ),
    );
    expect(accepted, 0);
    await tester.tap(find.byTooltip('Dismiss focus suggestion'));
    expect(dismissed, 1);
    expect(accepted, 0);
    await tester.tap(find.text('Switch to Longer personal work mode'));
    expect(accepted, 1);
    expect(tester.takeException(), isNull);
  });
}
