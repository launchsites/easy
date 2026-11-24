import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Workout schedules', () {
    test('a one-off workout occurs only on its local calendar date', () {
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.once,
        startDate: DateTime(2026, 11, 24, 18),
      );
      expect(schedule.startDate, DateTime(2026, 11, 24));
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 11, 23)),
        DateTime(2026, 11, 24),
      );
      expect(schedule.occursOn(DateTime(2026, 11, 24, 23)), isTrue);
      expect(schedule.occursOn(DateTime(2026, 11, 23, 17)), isFalse);
      expect(schedule.nextOnOrAfter(DateTime(2026, 11, 25)), isNull);
    });

    test('weekday schedules search forward from their start date', () {
      final days = [DateTime.friday, DateTime.monday, DateTime.friday];
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.weekdays,
        startDate: DateTime(2026, 11, 24),
        weekdays: days,
      );
      days.clear();
      expect(schedule.weekdays, [DateTime.monday, DateTime.friday]);
      expect(() => schedule.weekdays.clear(), throwsUnsupportedError);
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 11, 22)),
        DateTime(2026, 11, 27),
      );
      expect(schedule.occursOn(DateTime(2026, 11, 23)), isFalse);
      expect(schedule.occursOn(DateTime(2026, 11, 27, 18)), isTrue);
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 11, 28)),
        DateTime(2026, 11, 30),
      );
    });

    test('an unconfigured weekday schedule has no occurrences', () {
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.weekdays,
        startDate: DateTime(2026, 11, 24),
      );
      expect(schedule.nextOnOrAfter(DateTime(2026, 11, 24)), isNull);
    });

    test('intervals count civil days across a daylight-saving change', () {
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.interval,
        startDate: DateTime(2026, 3, 28),
        intervalDays: 2,
      );
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 3, 25)),
        DateTime(2026, 3, 28),
      );
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 3, 29)),
        DateTime(2026, 3, 30),
      );
      expect(schedule.occursOn(DateTime(2026, 3, 30, 21)), isTrue);
      expect(schedule.occursOn(DateTime(2026, 3, 31, 19)), isFalse);
      expect(
        schedule.nextOnOrAfter(DateTime(2026, 3, 31)),
        DateTime(2026, 4, 1),
      );
    });

    test('an interval beyond the supported date range has no later date', () {
      final start = DateTime(2026, 11, 24);
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.interval,
        startDate: start,
        intervalDays: 1 << 40,
      );
      expect(schedule.occursOn(start), isTrue);
      expect(schedule.nextOnOrAfter(DateTime(2026, 11, 25)), isNull);
    });

    test('invalid recurrence fields are rejected', () {
      expect(
        () => WorkoutSchedule(
          kind: WorkoutScheduleKind.interval,
          startDate: DateTime(2026, 11, 24),
          intervalDays: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => WorkoutSchedule(
          kind: WorkoutScheduleKind.weekdays,
          startDate: DateTime(2026, 11, 24),
          weekdays: [0, DateTime.sunday],
        ),
        throwsArgumentError,
      );
    });
  });

  test(
    'a plan round-trips its recurring schedule, cardio, and strength sets',
    () {
      final plan = WorkoutPlan(
        id: 'plan',
        name: 'Strength and running',
        schedule: WorkoutSchedule(
          kind: WorkoutScheduleKind.interval,
          startDate: DateTime(2026, 11, 24),
          intervalDays: 3,
        ),
        exercises: [
          WorkoutExercise(
            id: 'run',
            name: 'Treadmill',
            kind: WorkoutExerciseKind.cardio,
            distanceKm: 4.5,
            inclinePercent: 2,
            minutes: 23,
          ),
          WorkoutExercise(
            id: 'lift',
            name: 'Bench press',
            kind: WorkoutExerciseKind.strength,
            sets: [
              WorkoutSet(id: '1', reps: 8, weightKg: 45),
              WorkoutSet(id: '2', reps: 6, weightKg: 52.5),
            ],
          ),
        ],
      );
      final restored = WorkoutPlan.decode(plan.encode());
      expect(restored.toJson(), plan.toJson());
      expect(
        restored.schedule.nextOnOrAfter(DateTime(2026, 11, 30)),
        DateTime(2026, 11, 30),
      );
      expect(restored.exercises.first.distanceKm, 4.5);
      expect(restored.exercises.last.sets.last.weightKg, 52.5);
      expect(restored.exercises.last.sets.last.reps, 6);
    },
  );

  test('draft collections and edits do not mutate saved snapshots', () {
    final sets = [WorkoutSet(id: 'set')];
    final lift = WorkoutExercise(
      id: 'lift',
      name: 'Squat',
      kind: WorkoutExerciseKind.strength,
      sets: sets,
    );
    final rows = [lift];
    final plan = WorkoutPlan(
      id: 'plan',
      name: 'Leg day',
      schedule: WorkoutSchedule(
        kind: WorkoutScheduleKind.once,
        startDate: DateTime(2026, 11, 24),
      ),
      exercises: rows,
    );
    sets.clear();
    rows.clear();
    expect(() => plan.exercises.clear(), throwsUnsupportedError);
    expect(() => plan.exercises.first.sets.clear(), throwsUnsupportedError);

    final changed = plan.copyWith(
      name: 'Leg session',
      exercises: [
        lift.copyWith(sets: [lift.sets.single.copyWith(reps: 10)]),
      ],
    );
    expect(plan.name, 'Leg day');
    expect(plan.exercises.single.sets.single.reps, 8);
    expect(changed.name, 'Leg session');
    expect(changed.exercises.single.sets.single.reps, 10);
  });

  test('invalid stored dates and recurrence cannot become valid plans', () {
    expect(
      () => WorkoutPlan.decode('''{
        "id": "plan", "name": "Gym", "exercises": [],
        "schedule": {"kind": "once", "startDate": "2026-02-29"}
      }'''),
      throwsFormatException,
    );
    expect(
      () => WorkoutPlan.decode('''{
        "id": "plan", "name": "Gym", "exercises": [],
        "schedule": {"kind": "interval", "startDate": "2026-11-24", "intervalDays": 0}
      }'''),
      throwsFormatException,
    );
  });

  test('local IDs are unique even when generated rapidly', () {
    final ids = List.generate(128, (_) => newWorkoutId());
    expect(ids.toSet(), hasLength(ids.length));
  });
}
