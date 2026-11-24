import 'dart:math';

import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/task_objective_availability.dart';
import 'package:easy/scheduling/task_objective_review.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _places = ['a', 'b'];
const _scopes = {'work', 'study'};
final _now = DateTime.utc(2032, 5, 4, 10);
DateTime _at(int minutes) => _now.add(Duration(minutes: minutes));
Duration _minutes(int minutes) => Duration(minutes: minutes);

WeeklyAvailability _hours(
  String id, {
  int from = 0,
  int to = 1440,
  Set<String>? scopes,
  AvailabilityKind kind = AvailabilityKind.available,
  int? weekday,
}) => WeeklyAvailability(
  id: id,
  weekdays: {weekday ?? _now.weekday},
  startMinute: from,
  endMinute: to,
  categories: scopes,
  kind: kind,
);

SchedulingSettings _settings({
  int before = 0,
  int after = 0,
  List<TravelDuration> routes = const [],
  List<WeeklyAvailability>? windows,
  bool withPlaces = false,
}) => SchedulingSettings(
  timeZoneId: 'Etc/UTC',
  beforeMinutes: before,
  afterMinutes: after,
  availability: windows ?? [_hours('all')],
  places: [
    if (withPlaces)
      for (final id in _places) SavedPlace(id: id, name: id),
  ],
  routes: routes,
);

CalendarEvent _event(String id, int start, int end, {String? place}) =>
    CalendarEvent(
      id: id,
      title: id,
      start: _at(start),
      end: _at(end),
      category: 'work',
      savedPlaceId: place,
    );

TaskObjectiveAvailability _derive(
  SchedulingSettings settings, {
  List<CalendarEvent> events = const [],
  TimeSpan? coverage,
  bool complete = false,
}) => deriveTaskObjectiveAvailability(
  now: _now,
  horizonEnd: _at(90),
  settings: settings,
  confirmedEvents: events,
  categories: _scopes,
  verifiedCalendarSpan: coverage,
  calendarComplete: complete,
);

void main() {
  test('category exclusions and event buffers bound independently', () {
    final settings = _settings(
      before: 12,
      windows: [
        _hours('shared'),
        _hours(
          'study-rest',
          from: 620,
          to: 705,
          scopes: {'study'},
          kind: AvailabilityKind.unavailable,
        ),
      ],
    );
    final events = [_event('review', 60, 75)];
    final availability = _derive(settings, events: events, complete: true);
    expect(availability.byCategory, {
      'work': _minutes(48),
      'study': _minutes(20),
    });
    expect(() => availability.byCategory.clear(), throwsUnsupportedError);
    final tasks = [
      const TaskItem(
        id: 'work',
        title: 'Work',
        category: 'work',
        estimatedMinutes: 45,
      ),
      const TaskItem(
        id: 'study',
        title: 'Study',
        category: 'study',
        estimatedMinutes: 45,
      ),
    ];
    final review = reviewTaskObjectives(
      tasks: tasks,
      events: events,
      now: _now,
      horizonEnd: _at(90),
      verifiedAvailability: availability,
    );
    expect(review.availableTime, isNull);
    expect(review.ready.single.id, 'work');
    expect(review.ready.single.fit, ObjectiveFit.complete);
    expect(review.later.single.id, 'study');
    expect(review.later.single.fit, ObjectiveFit.needsMoreTime);
    final stale = reviewTaskObjectives(
      tasks: tasks,
      events: events,
      now: _at(1),
      horizonEnd: _at(90),
      verifiedAvailability: availability,
    );
    expect(
      stale.ready.map((task) => task.fit),
      everyElement(ObjectiveFit.unknown),
    );
  });

  test('unverified or unsafe coverage stays unknown at both boundaries', () {
    final withBuffers = _settings(before: 12, after: 15);
    expect(_derive(withBuffers).byCategory, isEmpty);
    expect(
      _derive(withBuffers, coverage: TimeSpan(_at(-14), _at(90))).byCategory,
      isEmpty,
    );
    expect(
      _derive(withBuffers, coverage: TimeSpan(_at(-15), _at(12))).byCategory,
      isEmpty,
    );
    expect(
      _derive(
        withBuffers,
        coverage: TimeSpan(_at(-15), _at(40)),
      ).byCategory['work'],
      _minutes(28),
    );
    expect(
      _derive(
        withBuffers,
        coverage: TimeSpan(_at(-30), _at(40)),
        events: [_event('before-now', -20, -5)],
      ).byCategory['work'],
      Duration.zero,
    );
    expect(_derive(_settings(windows: []), complete: true).byCategory, isEmpty);
    expect(
      _derive(
        withBuffers,
        complete: true,
        events: [_event('duplicate', -30, -10), _event('duplicate', 40, 50)],
      ).byCategory,
      isEmpty,
    );
  });

  test('known directions consume time and missing routes keep uncertain edges open to review', () {
    final backwards = TravelDuration(
      fromPlaceId: 'b',
      toPlaceId: 'a',
      minutes: 12,
    );
    final forwards = TravelDuration(
      fromPlaceId: 'a',
      toPlaceId: 'b',
      minutes: 20,
    );
    final partial = _settings(withPlaces: true, routes: [backwards], before: 5);
    final coverage = TimeSpan(_at(-60), _at(90));
    final fromA = _event('from-a', -50, -25, place: 'a');
    final toB = _event('to-b', 55, 60, place: 'b');
    expect(
      _derive(
        partial,
        coverage: coverage,
        events: [fromA, toB],
      ).byCategory['work'],
      Duration.zero,
    );
    expect(
      _derive(partial, coverage: coverage, events: [fromA]).byCategory,
      isEmpty,
    );
    expect(
      _derive(partial, coverage: coverage, events: [toB]).byCategory,
      isEmpty,
    );
    expect(
      _derive(
        partial,
        coverage: coverage,
        events: [
          fromA,
          _event('stale-neighbor', 95, 100, place: 'a'),
        ],
      ).byCategory,
      isEmpty,
    );
    expect(
      _derive(
        partial,
        coverage: coverage,
        events: [_event('from-b', -50, -25, place: 'b')],
      ).byCategory['work'],
      _minutes(73),
    );
    expect(
      _derive(
        partial,
        coverage: coverage,
        events: [_event('to-a', 55, 60, place: 'a')],
      ).byCategory['work'],
      _minutes(50),
    );
    expect(
      _derive(partial, complete: true, events: [fromA]).byCategory['work'],
      _minutes(90),
    );

    final complete = _settings(
      withPlaces: true,
      routes: [backwards, forwards],
      before: 5,
    );
    expect(
      _derive(
        complete,
        coverage: coverage,
        events: [fromA, toB],
      ).byCategory['work'],
      _minutes(30),
    );
    expect(
      _derive(complete, coverage: coverage).byCategory['work'],
      _minutes(65),
    );
  });

  test('verified availability preserves both times in a clock fold', () {
    final settings = SchedulingSettings(
      timeZoneId: 'America/New_York',
      availability: [
        _hours('fold', from: 75, to: 105, weekday: DateTime.sunday),
      ],
    );
    final first = DateTime.utc(2026, 11, 1, 5, 35);
    final second = DateTime.utc(2026, 11, 1, 6, 20);
    for (final (instant, minutes) in [(first, 10), (second, 25)]) {
      final result = deriveTaskObjectiveAvailability(
        now: instant,
        horizonEnd: instant.add(_minutes(100)),
        settings: settings,
        confirmedEvents: const [],
        categories: _scopes,
        calendarComplete: true,
      );
      expect(result.byCategory['work'], _minutes(minutes));
    }
  });

  test('400 arbitrary current fits match the existing placement proof', () {
    final random = Random(700);
    for (var index = 0; index < 200; index++) {
      final settings = _settings(
        before: random.nextInt(10),
        after: random.nextInt(10),
        windows: [
          _hours(
            'available',
            from: 570 + random.nextInt(60),
            to: 640 + random.nextInt(70),
          ),
          _hours(
            'unavailable',
            from: 580 + random.nextInt(50),
            to: 650,
            kind: AvailabilityKind.unavailable,
            scopes: {'study'},
          ),
        ],
        withPlaces: true,
        routes: [
          TravelDuration(
            fromPlaceId: 'a',
            toPlaceId: 'b',
            minutes: random.nextInt(30),
          ),
          TravelDuration(
            fromPlaceId: 'b',
            toPlaceId: 'a',
            minutes: random.nextInt(30),
          ),
        ],
      );
      final events = [
        for (var at = -50; at < 120; at += 35)
          if (random.nextBool())
            _event(
              '$at',
              at + random.nextInt(10),
              at + 12 + random.nextInt(15),
              place: [null, ..._places][random.nextInt(3)],
            ),
      ];
      final horizon = TimeSpan(_now, _at(90));
      final derived = _derive(settings, events: events, complete: true);
      final proof = settings.planningInputs(
        horizon: horizon,
        categories: _scopes,
        commitments: events.map(
          (event) => PlacedCommitment(
            id: event.id,
            span: TimeSpan(event.start, event.end),
            placeId: event.savedPlaceId,
          ),
        ),
      );
      for (final category in _scopes) {
        final minutes = 1 + random.nextInt(40);
        final proposal = proposeSchedule(
          horizon: horizon,
          availability: proof.availability,
          commitments: proof.commitments,
          tasks: [
            PlanningTask(
              id: category,
              title: category,
              category: category,
              remainingMinutes: minutes,
              deadline: _at(minutes),
            ),
          ],
        );
        expect(
          derived.byCategory[category]! >= _minutes(minutes),
          proposal.scheduled.isNotEmpty,
          reason: 'fixture $index, category $category and $minutes minutes',
        );
      }
    }
  });
}
