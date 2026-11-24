import 'dart:math';

import 'package:easy/calendar_page.dart';
import 'package:easy/review/review.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 11, 24);
DateTime _at(int minutes) => _day.add(Duration(minutes: minutes));

WeeklyAvailability _hours(
  String id,
  int start,
  int end, {
  Set<String>? categories,
  bool excluded = false,
  int weekday = DateTime.tuesday,
}) => WeeklyAvailability(
  id: id,
  weekdays: [weekday],
  startMinute: start,
  endMinute: end,
  categories: categories,
  kind: excluded ? AvailabilityKind.unavailable : AvailabilityKind.available,
);

CalendarEvent _event(
  String id,
  int start,
  int end, {
  String? place,
  bool allDay = false,
  bool utc = false,
  String? source,
}) => CalendarEvent(
  id: id,
  title: id,
  category: 'work',
  start: utc ? _at(start).toUtc() : _at(start),
  end: utc ? _at(end).toUtc() : _at(end),
  savedPlaceId: place,
  allDay: allDay,
  sourceLabel: source,
);

ReviewDayAvailability? _derive(
  SchedulingSettings? settings, {
  List<CalendarEvent> events = const [],
  Set<String> categories = const {'work'},
  bool complete = true,
}) => deriveReviewDayAvailability(
  day: _day,
  settings: settings,
  categories: categories,
  events: events,
  calendarComplete: complete,
);

List<(int, int)> _instants(Iterable<ReviewWindow> windows) => [
  for (final span in windows)
    (span.start.microsecondsSinceEpoch, span.end.microsecondsSinceEpoch),
];

List<(int, int)> _clock(Iterable<ReviewWindow> windows) => [
  for (final span in windows)
    (
      span.start.difference(_day).inMinutes,
      span.end.difference(_day).inMinutes,
    ),
];

void main() {
  test('unverified and unconfigured days have no free-time claim', () {
    final settings = SchedulingSettings(
      availability: [_hours('work', 540, 620)],
    );
    expect(_derive(settings, complete: false), isNull);
    expect(_derive(null), isNull);
    expect(_derive(settings, categories: {}), isNull);
    expect(_derive(SchedulingSettings()), isNull);
    final workHours = SchedulingSettings(
      availability: [
        _hours('scoped', 540, 620, categories: {'work'}),
      ],
    );
    expect(_derive(workHours, categories: {'personal'}), isNull);
    expect(
      _derive(workHours, categories: {'personal', 'work'})?.categoryCount,
      1,
    );
    expect(
      _derive(
        SchedulingSettings(
          availability: [_hours('only-exclusion', 540, 620, excluded: true)],
        ),
      ),
      isNull,
    );
    final absent = _derive(
      SchedulingSettings(
        availability: [
          _hours('other-day', 540, 620, weekday: DateTime.saturday),
        ],
      ),
    )!;
    expect(absent.windows, isEmpty);
    expect(
      ReviewAgenda(availability: absent.windows).forDay(_day).freeMinutes,
      0,
    );
  });

  test(
    'overlapping categories contribute an attainable union with buffers',
    () {
      final event = _event('call', 605, 615);
      final result = _derive(
        SchedulingSettings(
          beforeMinutes: 5,
          afterMinutes: 5,
          availability: [
            _hours('work', 540, 660, categories: {'work'}),
            _hours('study', 600, 720, categories: {'study'}),
            _hours('pause', 630, 660, excluded: true),
            _hours(
              'work-break',
              570,
              600,
              categories: {'work'},
              excluded: true,
            ),
          ],
        ),
        categories: {'work', 'study'},
        events: [event],
      )!;
      expect(_clock(result.windows), [(540, 570), (620, 630), (660, 720)]);
      expect(result.categoryCount, 2);
      expect(result.travelIssues, isEmpty);
      final review = ReviewAgenda(
        availability: result.windows,
        events: [
          ReviewEvent(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end,
          ),
        ],
      ).forDay(_day);
      expect(review.freeMinutes, 100);
      expect(review.scheduledMinutes, 10);
    },
  );

  test('raw all-day rows occupy free time without adding elapsed hours', () {
    final event = _event('all-day', 0, 1440, allDay: true);
    final result = _derive(
      SchedulingSettings(availability: [_hours('work', 540, 720)]),
      events: [event],
    )!;
    expect(result.hasAllDayCommitment, isTrue);
    expect(result.windows, isEmpty);
    final review = ReviewAgenda(
      availability: result.windows,
      events: [
        ReviewEvent(
          id: event.id,
          title: event.title,
          start: event.start,
          end: event.end,
          allDay: true,
        ),
      ],
    ).forDay(_day);
    expect(review.events.single.id, event.id);
    expect(review.scheduledMinutes, 0);
    expect(review.freeMinutes, 0);
  });

  test('duplicate commitment IDs agree on exact timing and source facts', () {
    final settings = SchedulingSettings(
      availability: [_hours('work', 540, 720)],
    );
    final event = _event('call', 600, 630);
    final duplicate = _derive(
      settings,
      events: [event, _event('call', 600, 630, utc: true)],
    );
    expect(_clock(duplicate!.windows), [(540, 600), (630, 720)]);
    for (final conflict in [
      _event('call', 600, 631),
      _event('call', 600, 630, allDay: true),
      _event('call', 600, 630, source: 'Elsewhere'),
      _event('call', 600, 630, place: 'moved'),
    ]) {
      expect(_derive(settings, events: [event, conflict]), isNull);
    }
    expect(_derive(settings, events: [_event('invalid', 630, 600)]), isNull);
  });

  test(
    'off-day placed neighbors preserve unknown travel and explicit buffers',
    () {
      final places = [
        SavedPlace(id: 'home', name: 'Home'),
        SavedPlace(id: 'office', name: 'Office'),
      ];
      final morning = _derive(
        SchedulingSettings(
          places: places,
          availability: [_hours('work', 540, 720)],
        ),
        events: [
          _event('before', -6000, -5900, place: 'home'),
          _event('after', 9000, 9030, place: 'office'),
        ],
      )!;
      expect(morning.windows, isEmpty);
      expect(morning.travelIssues, {TravelIssueKind.missingDuration});

      final evening = _derive(
        SchedulingSettings(
          places: places,
          routes: [
            TravelDuration(
              fromPlaceId: 'home',
              toPlaceId: 'office',
              minutes: 20,
            ),
          ],
          beforeMinutes: 25,
          afterMinutes: 10,
          availability: [_hours('late', 1380, 1440)],
        ),
        events: [
          _event('before', -6000, -5900, place: 'home'),
          _event('after', 1450, 1480, place: 'office'),
        ],
      )!;
      expect(_clock(evening.windows), [(1380, 1405)]);
      expect(evening.travelIssues, isEmpty);
    },
  );

  test('both DST overlap hours are counted as distinct elapsed intervals', () {
    final day = DateTime(2026, 11, 1);
    DateTime utc(int hour, [int minute = 0]) =>
        DateTime.utc(2026, 11, 1, hour, minute);
    CalendarEvent appointment(String id, int hour) => CalendarEvent(
      id: id,
      title: id,
      category: 'work',
      start: utc(hour, 30),
      end: utc(hour, 45),
    );
    final result = deriveReviewDayAvailability(
      day: day,
      settings: SchedulingSettings(
        timeZoneId: 'America/New_York',
        availability: [_hours('fold', 60, 120, weekday: DateTime.sunday)],
      ),
      categories: ['work'],
      events: [appointment('first', 5), appointment('second', 6)],
      calendarComplete: true,
    )!;
    final horizon = TimeSpan(day, nextReviewDay(day));
    final expected = [
      TimeSpan(utc(5), utc(5, 30)),
      TimeSpan(utc(5, 45), utc(6, 30)),
      TimeSpan(utc(6, 45), utc(7)),
    ];
    expect(_instants(result.windows), [
      for (final window in expected)
        if (window.intersection(horizon) case final span?)
          (span.start.microsecondsSinceEpoch, span.end.microsecondsSinceEpoch),
    ]);
  });

  test('bounded calendar projection matches complete planner inputs', () {
    final random = Random(60324);
    final places = [
      for (final id in ['home', 'office', 'library'])
        SavedPlace(id: id, name: id),
    ];
    final horizon = TimeSpan(_day, nextReviewDay(_day));
    const scopes = {'work', 'study'};
    for (var fixture = 0; fixture < 500; fixture++) {
      final settings = SchedulingSettings(
        places: places,
        routes: [
          for (final from in places)
            for (final to in places)
              if (from.id != to.id && random.nextBool())
                TravelDuration(
                  fromPlaceId: from.id,
                  toPlaceId: to.id,
                  minutes: random.nextInt(600),
                ),
        ],
        beforeMinutes: random.nextInt(600),
        afterMinutes: random.nextInt(600),
        availability: [
          _hours('work', 7 * 60, 15 * 60, categories: {'work'}),
          _hours('study', 9 * 60, 17 * 60, categories: {'study'}),
        ],
      );
      final events = <CalendarEvent>[];
      for (var index = 0; index < 35; index++) {
        final start = random.nextInt(1440 * 24) - 1440 * 12;
        events.add(
          _event(
            'event-$index',
            start,
            start + 1 + random.nextInt(18 * 60),
            place: random.nextBool()
                ? places[random.nextInt(places.length)].id
                : null,
            utc: random.nextBool(),
          ),
        );
      }
      events.shuffle(random);
      final full = settings.planningInputs(
        horizon: horizon,
        categories: scopes,
        commitments: [
          for (final event in events)
            PlacedCommitment(
              id: event.id,
              span: TimeSpan(event.start, event.end),
              placeId: event.savedPlaceId,
            ),
        ],
      );
      final expected = unoccupiedPlanningWindows(
        horizon: horizon,
        availability: full.availability,
        commitments: full.commitments,
      );
      final bounded = _derive(settings, events: events, categories: scopes)!;
      expect(_instants(bounded.windows), [
        for (final window in expected)
          (
            window.start.microsecondsSinceEpoch,
            window.end.microsecondsSinceEpoch,
          ),
      ], reason: 'fixture $fixture');
      expect(
        bounded.travelIssues,
        full.travelIssues.map((item) => item.kind).toSet(),
        reason: 'fixture $fixture',
      );
    }
  });
}
