import 'package:easy/gym_session.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final started = DateTime.utc(2026, 11, 24, 8);
  final recorded = started.add(const Duration(minutes: 10));

  GymSession session({bool duplicate = false}) => GymSession.start(
    now: started,
    plan: WorkoutPlan(
      id: 'upper-body',
      name: 'Upper body',
      schedule: WorkoutSchedule(
        kind: WorkoutScheduleKind.once,
        startDate: started,
      ),
      exercises: [
        WorkoutExercise(
          id: 'treadmill',
          name: 'Treadmill',
          kind: WorkoutExerciseKind.cardio,
          distanceKm: .5,
          minutes: 6,
          inclinePercent: 2,
        ),
        for (final id in ['bench', if (duplicate) 'bench-two'])
          WorkoutExercise(
            id: id,
            name: 'Bench press',
            kind: WorkoutExerciseKind.strength,
            sets: [
              for (final set in ['first', 'second', 'third'])
                WorkoutSet(id: set, weightKg: 50),
            ],
          ),
      ],
    ),
  );

  GymWorkoutCaptureReview review(GymSession active, String text) =>
      reviewGymWorkoutCapture(
        session: active,
        originalText: text,
        recordedAt: recorded,
      );

  test(
    'a complete strength sequence keeps the source and original targets',
    () {
      final active = session();
      const words = '  bench press 60kg x8,8,6  ';
      final draft = review(active, words).draft!;
      expect(draft.kind, GymWorkoutCaptureKind.strength);
      expect(draft.setIds, ['first', 'second', 'third']);
      expect(draft.canConfirmCompletion, isFalse);
      final updated = draft.apply(
        active,
        entryId: 'phrased',
        markExplicitCompletion: true,
      )!;
      expect(updated.exercises.last.sets.map((set) => set.reps), [8, 8, 6]);
      expect(updated.exercises.last.sets.map((set) => set.weightKg), [
        60,
        60,
        60,
      ]);
      expect(updated.progressFor('bench', setId: 'third'), GymProgress.pending);
      expect(active.exercises.last.sets.last.reps, 8);
      expect(updated.plannedExercise('bench')!.sets.last.weightKg, 50);
      expect(updated.entries.single.captureText, words);
      final restored = GymSession.decode(updated.encode());
      expect(restored.entries.single.captureText, words);
      expect(restored.entries.single.exerciseId, 'bench');
      expect(draft.apply(restored, entryId: 'phrased'), isNull);
      expect(draft.apply(restored, entryId: 'duplicate-other-id'), isNull);
    },
  );

  test('explicit completion and pounds affect only the reviewed set', () {
    final active = session();
    final draft = review(
      active,
      'I did Bench press set 2 135 pounds times 6',
    ).draft!;
    expect(draft.canConfirmCompletion, isTrue);
    expect(draft.setIds, ['second']);
    final edited = draft.apply(
      active,
      entryId: 'set-2',
      markExplicitCompletion: true,
    )!;
    final sets = edited.exercises.last.sets;
    expect(sets[0].weightKg, 50);
    expect(sets[1].weightKg, closeTo(61.23497, .00001));
    expect(sets[2].reps, 8);
    expect(edited.progressFor('bench', setId: 'first'), GymProgress.pending);
    expect(edited.progressFor('bench', setId: 'second'), GymProgress.done);
    expect(edited.progressFor('bench', setId: 'third'), GymProgress.pending);
  });

  test(
    'after a named exercise preserves chronology without marking it done',
    () {
      const text = 'After treadmill, I stretched';
      final active = session().withCapturedEntry(
        GymLogEntry(
          id: 'later',
          title: 'Water',
          loggedAt: recorded.add(const Duration(minutes: 3)),
        ),
      );
      final draft = review(active, text).draft!;
      expect(draft.kind, GymWorkoutCaptureKind.extra);
      expect(draft.title, 'Stretched');
      expect(draft.afterExerciseId, 'treadmill');
      final updated = draft.apply(active, entryId: 'stretch')!;
      expect(updated.entries.map((entry) => entry.id), ['stretch', 'later']);
      expect(updated.progressFor('treadmill'), GymProgress.pending);
      final saved = GymSession.decode(updated.encode()).entries.first;
      expect(saved.afterExerciseId, 'treadmill');
      expect(saved.captureText, text);
    },
  );

  test(
    'cardio changes exact values and other reviewed rows remain compatible',
    () {
      final active = session();
      final cardio = review(
        active,
        'I did treadmill 3% incline 0.45km in 5mins',
      ).draft!;
      final strength = review(active, 'Bench press set 3 x6').draft!;
      final first = cardio.apply(
        active,
        entryId: 'cardio',
        markExplicitCompletion: true,
      )!;
      final updated = strength.apply(first, entryId: 'bench')!;
      expect(updated.exercises.first.distanceKm, .45);
      expect(updated.exercises.first.inclinePercent, 3);
      expect(updated.exercises.first.minutes, 5);
      expect(updated.progressFor('treadmill'), GymProgress.done);
      expect(updated.exercises.last.sets.last.reps, 6);
      expect(updated.exercises.last.sets.last.weightKg, 50);
      expect(updated.progressFor('bench', setId: 'third'), GymProgress.pending);
    },
  );

  test(
    'reps or minutes alone leave unknown fields and completion untouched',
    () {
      final active = session();
      final strength = review(active, 'I did Bench press set 3 x6').draft!;
      final cardio = review(active, 'I did treadmill for 5 minutes').draft!;
      expect(strength.canConfirmCompletion, isFalse);
      expect(cardio.canConfirmCompletion, isFalse);
      final updated = cardio.apply(
        active,
        entryId: 'minutes',
        markExplicitCompletion: true,
      )!;
      expect(updated.exercises.first.minutes, 5);
      expect(updated.exercises.first.distanceKm, .5);
      expect(updated.exercises.first.inclinePercent, 2);
      expect(updated.progressFor('treadmill'), GymProgress.pending);
    },
  );

  test('ambiguous or hypothetical statements cannot update a session', () {
    final active = session();
    final rejected = {
      'bench press 60 x8,8,6': GymWorkoutCaptureIssue.unsupportedValues,
      'bench press 60kg x8': GymWorkoutCaptureIssue.ambiguousSets,
      'bench press set 4 50kg x8': GymWorkoutCaptureIssue.ambiguousSets,
      'I did not do Bench press 60kg x8,8,6':
          GymWorkoutCaptureIssue.plannedLanguage,
      'Tomorrow Bench press 60 kg x 8,8,6':
          GymWorkoutCaptureIssue.plannedLanguage,
      'After row I stretched': GymWorkoutCaptureIssue.unknownExercise,
      'Treadmill 5m': GymWorkoutCaptureIssue.unsupportedValues,
      'Treadmill 5 mins, 6 mins': GymWorkoutCaptureIssue.unsupportedValues,
      'Treadmill 2.5 min': GymWorkoutCaptureIssue.unsupportedValues,
      'Treadmill .45km in 5mins': GymWorkoutCaptureIssue.unsupportedValues,
      'Bench press .5 kg x8,8,6': GymWorkoutCaptureIssue.unsupportedValues,
    };
    for (final MapEntry(:key, :value) in rejected.entries) {
      final result = review(active, key);
      expect(result.issue, value, reason: key);
      expect(result.draft, isNull, reason: key);
    }
    expect(
      review(session(duplicate: true), 'Bench press 60 kg x8,8,6').issue,
      GymWorkoutCaptureIssue.ambiguousExercise,
    );
    expect(review(active, 'Bench press ${'0' * 2401}').draft, isNull);
    expect(
      reviewGymWorkoutCapture(
        session: active,
        originalText: 'Stretch',
        recordedAt: started.subtract(const Duration(seconds: 1)),
      ).issue,
      GymWorkoutCaptureIssue.inactive,
    );
  });
}
