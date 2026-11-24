part of 'gym_session.dart';

class PreviousWorkoutSet {
  const PreviousWorkoutSet({
    required this.weightKg,
    required this.reps,
    required this.sessionDate,
  });

  final double weightKg;
  final int reps;

  /// Date of the finished session that contains this confirmed set.
  final DateTime sessionDate;
}

/// Looks up confirmed sets from earlier sessions. Template IDs take priority.
/// A unique exact exercise name and set position can match across templates.
Map<(String, String), PreviousWorkoutSet> previousWorkoutSets(
  GymSession session,
  Iterable<GymSession> history,
) {
  final exercises = {
    for (final exercise in session.exercises)
      if (exercise.kind == WorkoutExerciseKind.strength &&
          exercise.sets.isNotEmpty)
        exercise.id: exercise,
  };
  if (exercises.isEmpty) return const {};
  final names = _unambiguousStrengthNames(exercises.values);
  final stable = <(String, String), PreviousWorkoutSet>{};
  final crossTemplate = <(String, String), PreviousWorkoutSet>{};

  void add(
    Map<(String, String), PreviousWorkoutSet> results,
    String exerciseId,
    String setId,
    WorkoutSet candidate,
    DateTime date,
  ) {
    final key = (exerciseId, setId);
    final saved = results[key];
    if (saved != null && !date.isAfter(saved.sessionDate)) return;
    results[key] = PreviousWorkoutSet(
      weightKg: candidate.weightKg,
      reps: candidate.reps,
      sessionDate: date,
    );
  }

  for (final source in history) {
    if (source.finishedAt case final finished?
        when source.startedAt.isBefore(session.startedAt) &&
            !finished.isAfter(session.startedAt)) {
      final sameTemplate = source.planId == session.planId;
      final historicalNames = _unambiguousStrengthNames(source.exercises);
      for (final exercise in source.exercises) {
        if (exercise.kind != WorkoutExerciseKind.strength) continue;
        final exact = sameTemplate ? exercises[exercise.id] : null;
        final name = _normalizedWorkoutName(exercise.name);
        final byName = identical(historicalNames[name], exercise)
            ? names[name]
            : null;
        if (exact == null && byName == null) continue;
        final exactIds = exact?.sets.map((set) => set.id).toSet();
        for (final (index, set) in exercise.sets.indexed) {
          if (source.progressFor(exercise.id, setId: set.id) !=
              GymProgress.done) {
            continue;
          }
          if (exactIds?.contains(set.id) == true) {
            add(stable, exact!.id, set.id, set, source.startedAt);
          }
          if (byName != null && exact == null && index < byName.sets.length) {
            add(
              crossTemplate,
              byName.id,
              byName.sets[index].id,
              set,
              source.startedAt,
            );
          }
        }
      }
    }
  }
  return Map.unmodifiable({...crossTemplate, ...stable});
}

final _workoutWhitespace = RegExp(r'\s+');

String _normalizedWorkoutName(String value) =>
    value.trim().toLowerCase().replaceAll(_workoutWhitespace, ' ');

Map<String, WorkoutExercise?> _unambiguousStrengthNames(
  Iterable<WorkoutExercise> exercises,
) {
  final names = <String, WorkoutExercise?>{};
  for (final exercise in exercises) {
    if (exercise.kind != WorkoutExerciseKind.strength) continue;
    final key = _normalizedWorkoutName(exercise.name);
    names[key] = names.containsKey(key) ? null : exercise;
  }
  return names;
}
