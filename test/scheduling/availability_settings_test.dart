import 'dart:convert';

import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'weekly windows merge by category and explicit unavailable hours win',
    () {
      final settings = SchedulingSettings(
        timeZoneId: 'Europe/London',
        availability: [
          _hours('all', DateTime.monday, 9 * 60, 12 * 60),
          _hours(
            'work-only',
            DateTime.monday,
            11 * 60,
            15 * 60,
            categories: {'work'},
          ),
          _hours(
            'work-busy',
            DateTime.monday,
            10 * 60,
            13 * 60,
            categories: {'work'},
            kind: AvailabilityKind.unavailable,
          ),
          _hours(
            'health',
            DateTime.tuesday,
            8 * 60,
            9 * 60,
            categories: {'health'},
          ),
        ],
      );
      final window = TimeSpan(
        DateTime.utc(2026, 11, 23),
        DateTime.utc(2026, 11, 30),
      );
      final result = settings.availabilityFor(
        horizon: window,
        categories: ['work', 'health', 'study', 'work'],
      );
      expect(_for(result, 'work'), [
        _range(23, 9, 23, 10),
        _range(23, 13, 23, 15),
      ]);
      expect(_for(result, 'health'), [
        _range(23, 9, 23, 12),
        _range(24, 8, 24, 9),
      ]);
      expect(_for(result, 'study'), [_range(23, 9, 23, 12)]);
      expect(_for(result, 'missing'), isEmpty);
      expect(
        result.where(
          (entry) => entry.categories!.containsAll({'health', 'study'}),
        ),
        hasLength(1),
      );
      final reversed = settings.availabilityFor(
        horizon: window,
        categories: ['study', 'health', 'work'],
      );
      expect(_for(result, 'health'), _for(reversed, 'health'));
    },
  );

  test(
    'overnight hours include the previous weekday and clip to a day horizon',
    () {
      final settings = SchedulingSettings(
        timeZoneId: 'Europe/London',
        availability: [_hours('overnight', DateTime.monday, 22 * 60, 2 * 60)],
      );
      final result = settings.availabilityFor(
        horizon: TimeSpan(
          DateTime.utc(2026, 11, 24),
          DateTime.utc(2026, 11, 24, 1),
        ),
        categories: ['study'],
      );
      expect(_for(result, 'study'), [_range(24, 0, 24, 1)]);
    },
  );

  test('spring DST gaps create no phantom hours', () {
    final settings = SchedulingSettings(
      timeZoneId: 'Europe/London',
      availability: [
        _hours('gap', DateTime.sunday, 75, 105, categories: {'study'}),
        _hours('starts-gap', DateTime.sunday, 90, 150, categories: {'work'}),
        _hours('cross-gap', DateTime.sunday, 30, 150, categories: {'health'}),
      ],
    );
    final result = settings.availabilityFor(
      horizon: TimeSpan(DateTime.utc(2026, 3, 29), DateTime.utc(2026, 3, 30)),
      categories: ['study', 'work', 'health'],
    );
    expect(_for(result, 'study'), isEmpty);
    expect(_for(result, 'work'), [
      (DateTime.utc(2026, 3, 29, 1), DateTime.utc(2026, 3, 29, 1, 30)),
    ]);
    expect(_for(result, 'health'), [
      (DateTime.utc(2026, 3, 29, 0, 30), DateTime.utc(2026, 3, 29, 1, 30)),
    ]);
  });

  test(
    'fall fold keeps both matching wall-time slices without bridging them',
    () {
      final settings = SchedulingSettings(
        timeZoneId: 'Europe/London',
        availability: [_hours('fold', DateTime.sunday, 75, 105)],
      );
      final result = settings.availabilityFor(
        horizon: TimeSpan(
          DateTime.utc(2026, 10, 25),
          DateTime.utc(2026, 10, 26),
        ),
        categories: ['personal'],
      );
      expect(_for(result, 'personal'), [
        (DateTime.utc(2026, 10, 25, 0, 15), DateTime.utc(2026, 10, 25, 0, 45)),
        (DateTime.utc(2026, 10, 25, 1, 15), DateTime.utc(2026, 10, 25, 1, 45)),
      ]);
    },
  );

  test(
    'a DST transition inside an all-day horizon keeps its full civil day',
    () {
      final settings = SchedulingSettings(
        timeZoneId: 'Europe/London',
        availability: [_hours('day', DateTime.sunday, 0, 1440)],
      );
      final spring = settings.availabilityFor(
        horizon: TimeSpan(DateTime.utc(2026, 3, 28), DateTime.utc(2026, 3, 30)),
        categories: ['work'],
      );
      final fall = settings.availabilityFor(
        horizon: TimeSpan(
          DateTime.utc(2026, 10, 24),
          DateTime.utc(2026, 10, 26),
        ),
        categories: ['work'],
      );
      expect(spring.single.span.length.inHours, 23);
      expect(fall.single.span.length.inHours, 25);
      expect(fall.single.span.start, DateTime.utc(2026, 10, 24, 23));
    },
  );

  test('route direction, base buffers and unknown gaps remain distinct', () {
    final settings = _travelSettings();
    expect(settings.travelDuration('a', 'b'), const Duration(minutes: 30));
    expect(settings.travelDuration('b', 'a'), isNull);
    expect(settings.travelDuration('a', 'a'), Duration.zero);
    final input = settings.planningInputs(
      horizon: _horizon(),
      categories: ['work'],
      commitments: [
        _commitment('evt-third', 13, 14, 'a'),
        _commitment('evt-first', 9, 10, 'a'),
        _commitment('evt-second', 11, 12, 'b'),
      ],
    );
    expect(input.commitments, hasLength(4));
    final second = input.commitments.singleWhere(
      (value) => value.span.start.hour == 11,
    );
    expect(second.before, const Duration(minutes: 40));
    expect(second.after, const Duration(minutes: 5));
    final gap = input.commitments.singleWhere(
      (value) => value.span.start.hour == 12,
    );
    expect(gap.span.end.hour, 13);
    expect(gap.before, Duration.zero);
    final issue = input.travelIssues.single;
    expect(issue.kind, TravelIssueKind.missingDuration);
    expect(issue.requiredGap, isNull);
    expect(issue.fromCommitmentId, 'evt-second');
    expect(issue.toCommitmentId, 'evt-third');
    expect(issue.fromPlaceId, 'b');
  });

  test('the planner uses only the space left after configured travel', () {
    final inputs = _travelSettings().planningInputs(
      horizon: _horizon(),
      categories: ['work'],
      commitments: [
        _commitment('first', 9, 10, 'a'),
        _commitment('second', 11, 12, 'b'),
        _commitment('third', 13, 14, 'a'),
      ],
    );
    PlanningTask task(String id, int from, int to) => PlanningTask(
      id: id,
      title: id,
      category: 'work',
      remainingMinutes: 15,
      earliest: DateTime.utc(2026, 11, 23, from),
      deadline: DateTime.utc(2026, 11, 23, to),
    );
    final proposal = proposeSchedule(
      horizon: _horizon(),
      availability: inputs.availability,
      commitments: inputs.commitments,
      tasks: [task('review', 10, 11), task('call', 12, 13)],
    );
    expect(
      proposal.scheduled.single.blocks.single.start,
      DateTime.utc(2026, 11, 23, 10, 5),
    );
    expect(
      proposal.scheduled.single.blocks.single.end,
      DateTime.utc(2026, 11, 23, 10, 20),
    );
    expect(proposal.unscheduled.single.task.id, 'call');
  });

  test(
    'short known routes show the required gap without moving commitments',
    () {
      final settings = _travelSettings();
      final second = PlacedCommitment(
        id: 'second',
        span: TimeSpan(
          DateTime.utc(2026, 11, 23, 10, 15),
          DateTime.utc(2026, 11, 23, 11, 15),
        ),
        placeId: 'b',
        beforeMinutes: 2,
      );
      final inputs = settings.planningInputs(
        horizon: _horizon(),
        categories: ['work'],
        commitments: [_commitment('first', 9, 10, 'a'), second],
      );
      expect(inputs.travelIssues.single.kind, TravelIssueKind.insufficientGap);
      expect(
        inputs.travelIssues.single.requiredGap,
        const Duration(minutes: 37),
      );
      expect(inputs.commitments.last.span, same(second.span));
      expect(inputs.commitments.last.before, const Duration(minutes: 32));
    },
  );

  test(
    'unplaced commitments keep explicit buffers and no hours means no tasks',
    () {
      final settings = SchedulingSettings(beforeMinutes: 4, afterMinutes: 8);
      final inputs = settings.planningInputs(
        horizon: _horizon(),
        categories: ['work'],
        commitments: [
          PlacedCommitment(
            id: 'unknown-location',
            span: TimeSpan(
              DateTime.utc(2026, 11, 23, 9),
              DateTime.utc(2026, 11, 23, 10),
            ),
          ),
        ],
      );
      expect(inputs.travelIssues, isEmpty);
      expect(inputs.commitments.single.before, const Duration(minutes: 4));
      expect(inputs.commitments.single.after, const Duration(minutes: 8));
      final plan = proposeSchedule(
        horizon: _horizon(),
        availability: inputs.availability,
        commitments: inputs.commitments,
        tasks: [
          PlanningTask(
            id: 'task',
            title: 'Review',
            category: 'work',
            remainingMinutes: 15,
          ),
        ],
      );
      expect(plan.scheduled, isEmpty);
      expect(plan.unscheduled.single.problem, PlannerProblem.noFeasibleTime);
    },
  );

  test('settings JSON retains private details and rejects invalid input', () {
    final settings = _travelSettings();
    final restored = SchedulingSettings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>,
    );
    expect(restored.toJson(), settings.toJson());
    expect(restored.places.first.privateDetail, 'Apartment floor');
    expect(
      () => SchedulingSettings(timeZoneId: 'Unrecognized/Zone'),
      throwsArgumentError,
    );
    expect(() => SchedulingSettings(beforeMinutes: -1), throwsArgumentError);
    expect(
      () => SchedulingSettings(
        places: settings.places,
        routes: [settings.routes.single, settings.routes.single],
      ),
      throwsArgumentError,
    );
    expect(
      () => SchedulingSettings(routes: settings.routes),
      throwsArgumentError,
    );
    expect(
      () => _hours('empty', DateTime.monday, 500, 500),
      throwsArgumentError,
    );
    expect(() => _hours('bad-day', 8, 0, 1440), throwsArgumentError);
  });
}

WeeklyAvailability _hours(
  String id,
  int day,
  int start,
  int end, {
  Set<String>? categories,
  AvailabilityKind kind = AvailabilityKind.available,
}) => WeeklyAvailability(
  id: id,
  weekdays: [day],
  startMinute: start,
  endMinute: end,
  categories: categories,
  kind: kind,
);

List<(DateTime, DateTime)> _for(
  List<PlanningWindow> windows,
  String category,
) => [
  for (final window in windows)
    if (window.allows(category)) (window.span.start, window.span.end),
];

(DateTime, DateTime) _range(int day1, int hour1, int day2, int hour2) =>
    (DateTime.utc(2026, 11, day1, hour1), DateTime.utc(2026, 11, day2, hour2));

TimeSpan _horizon() =>
    TimeSpan(DateTime.utc(2026, 11, 23), DateTime.utc(2026, 11, 24));

PlacedCommitment _commitment(String id, int from, int to, String place) =>
    PlacedCommitment(
      id: id,
      span: TimeSpan(
        DateTime.utc(2026, 11, 23, from),
        DateTime.utc(2026, 11, 23, to),
      ),
      placeId: place,
    );

SchedulingSettings _travelSettings() => SchedulingSettings(
  timeZoneId: 'Etc/UTC',
  availability: [_hours('working-hours', DateTime.monday, 8 * 60, 16 * 60)],
  places: [
    SavedPlace(id: 'a', name: 'Home', privateDetail: 'Apartment floor'),
    SavedPlace(id: 'b', name: 'Town'),
  ],
  routes: [TravelDuration(fromPlaceId: 'a', toPlaceId: 'b', minutes: 30)],
  beforeMinutes: 10,
  afterMinutes: 5,
);
