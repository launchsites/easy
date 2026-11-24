part of 'gym_session.dart';

enum GymWorkoutCaptureKind { extra, cardio, strength }

enum GymWorkoutCaptureIssue {
  inactive('The capture does not belong to this live workout.'),
  empty('Enter one workout entry.'),
  ambiguousExercise('Choose the exact exercise this entry refers to.'),
  unknownExercise('The named exercise is unavailable in this workout.'),
  plannedLanguage('Review this statement before treating it as an actual.'),
  unsupportedValues('Use an exact exercise and explicit numbers and units.'),
  ambiguousSets('Give a set number, or a repetition count for each set.'),
  alreadyConfirmed('A matching set or exercise has already been marked.');

  const GymWorkoutCaptureIssue(this.message);
  final String message;
}

class GymWorkoutCaptureReview {
  const GymWorkoutCaptureReview._({this.draft, this.issue});

  final GymWorkoutCaptureDraft? draft;
  final GymWorkoutCaptureIssue? issue;
}

typedef _ReviewedSet = ({WorkoutSet before, int reps, double? kilograms});

typedef _ReviewedCardio = ({double? distance, int? minutes, double? incline});

class GymWorkoutCaptureDraft {
  const GymWorkoutCaptureDraft._({
    required this.kind,
    required this.originalText,
    required this.title,
    required this.detail,
    required this.recordedAt,
    required this._sessionStartedAt,
    this.afterExerciseId,
    this.afterExerciseName,
    this.canConfirmCompletion = false,
    this._exercise,
    this._sets = const [],
    this._cardio,
  });

  final GymWorkoutCaptureKind kind;
  final String originalText;
  final String title;
  final String detail;
  final DateTime recordedAt;
  final String? afterExerciseId;
  final String? afterExerciseName;
  final bool canConfirmCompletion;
  final DateTime _sessionStartedAt;
  final WorkoutExercise? _exercise;
  final List<_ReviewedSet> _sets;
  final _ReviewedCardio? _cardio;

  String? get exerciseId => _exercise?.id;
  List<String> get setIds =>
      List.unmodifiable(_sets.map((item) => item.before.id));

  /// Rechecks the exact affected rows. Independent entries from the same
  /// review can still apply after an unrelated row or note changed.
  GymSession? apply(
    GymSession current, {
    required String entryId,
    bool markExplicitCompletion = false,
  }) {
    if (current.finished ||
        !_sessionStartedAt.isAtSameMomentAs(current.startedAt) ||
        entryId.trim().isEmpty ||
        current.entries.any((item) => item.id == entryId)) {
      return null;
    }
    if (afterExerciseId case final reference?
        when !current.exercises.any(
          (item) => item.id == reference && item.name == afterExerciseName,
        )) {
      return null;
    }

    var updated = current;
    final expected = _exercise;
    if (expected != null) {
      final matches = current.exercises.where((item) => item.id == expected.id);
      if (matches.length != 1) return null;
      final actual = matches.single;
      if (actual.kind != expected.kind || actual.name != expected.name) {
        return null;
      }
      final WorkoutExercise replacement;
      if (_cardio case final cardio?) {
        if (current.progressFor(actual.id) != GymProgress.pending ||
            (cardio.distance != null &&
                actual.distanceKm != expected.distanceKm) ||
            (cardio.minutes != null && actual.minutes != expected.minutes) ||
            (cardio.incline != null &&
                actual.inclinePercent != expected.inclinePercent)) {
          return null;
        }
        replacement = actual.copyWith(
          distanceKm: cardio.distance,
          minutes: cardio.minutes,
          inclinePercent: cardio.incline,
        );
      } else {
        final selected = {for (final item in _sets) item.before.id: item};
        final changed = <WorkoutSet>[];
        final touched = <String>{};
        for (final set in actual.sets) {
          final edit = selected[set.id];
          if (edit == null) {
            changed.add(set);
            continue;
          }
          if (!touched.add(set.id) ||
              current.progressFor(actual.id, setId: set.id) !=
                  GymProgress.pending ||
              set.weightKg != edit.before.weightKg ||
              set.reps != edit.before.reps) {
            return null;
          }
          changed.add(set.copyWith(weightKg: edit.kilograms, reps: edit.reps));
        }
        if (touched.length != selected.length) return null;
        replacement = actual.copyWith(sets: changed);
      }
      updated = updated._withExercises([
        for (final item in current.exercises)
          if (identical(item, actual)) replacement else item,
      ]);
      if (markExplicitCompletion && canConfirmCompletion) {
        for (final id in _cardio != null ? const <String?>[null] : setIds) {
          updated = updated._withProgress(actual.id, id, GymProgress.done);
        }
      }
    }

    return updated.withCapturedEntry(
      GymLogEntry(
        id: entryId,
        title: title,
        actual: kind == GymWorkoutCaptureKind.extra ? null : detail,
        exerciseId: exerciseId,
        afterExerciseId: afterExerciseId,
        captureText: originalText,
        loggedAt: recordedAt,
      ),
    );
  }
}

GymWorkoutCaptureReview reviewGymWorkoutCapture({
  required GymSession session,
  required String originalText,
  required DateTime recordedAt,
}) {
  GymWorkoutCaptureReview reject(GymWorkoutCaptureIssue issue) =>
      GymWorkoutCaptureReview._(issue: issue);
  if (session.finished || recordedAt.isBefore(session.startedAt)) {
    return reject(GymWorkoutCaptureIssue.inactive);
  }
  if (originalText.trim().isEmpty) return reject(GymWorkoutCaptureIssue.empty);
  if (originalText.length > 2400 || originalText.contains(RegExp(r'[\r\n;]'))) {
    return reject(GymWorkoutCaptureIssue.unsupportedValues);
  }
  if (_workoutNonActual.hasMatch(originalText)) {
    return reject(GymWorkoutCaptureIssue.plannedLanguage);
  }

  var text = originalText.trim().replaceFirst(_workoutCaptureLead, '');
  WorkoutExercise? after;
  if (_workoutAfter.firstMatch(text) case final context?) {
    final reference = _matchWorkoutExercise(
      text.substring(context.end),
      session,
    );
    if (reference.ambiguous) {
      return reject(GymWorkoutCaptureIssue.ambiguousExercise);
    }
    if (reference.exercise == null) {
      return reject(GymWorkoutCaptureIssue.unknownExercise);
    }
    after = reference.exercise;
    text = _workoutRemainder(text.substring(context.end + reference.end));
  }

  var explicitCompletion = false;
  if (_workoutPast.firstMatch(text) case final action?) {
    explicitCompletion = true;
    text = _workoutRemainder(text.substring(action.end));
  } else {
    text = text.replaceFirst(_workoutLog, '');
  }
  final named = _matchWorkoutExercise(text, session);
  if (named.ambiguous) return reject(GymWorkoutCaptureIssue.ambiguousExercise);
  final exercise = named.exercise;

  GymWorkoutCaptureReview ready({
    required GymWorkoutCaptureKind kind,
    required String title,
    required String detail,
    bool canConfirm = false,
    List<_ReviewedSet> sets = const [],
    _ReviewedCardio? cardio,
  }) => GymWorkoutCaptureReview._(
    draft: GymWorkoutCaptureDraft._(
      kind: kind,
      originalText: originalText,
      sessionStartedAt: session.startedAt,
      recordedAt: recordedAt,
      title: title,
      detail: detail,
      afterExerciseId: after?.id,
      afterExerciseName: after?.name,
      canConfirmCompletion: canConfirm,
      exercise: kind == GymWorkoutCaptureKind.extra ? null : exercise,
      sets: List.unmodifiable(sets),
      cardio: cardio,
    ),
  );

  if (exercise == null) {
    final note = text.replaceFirst(_workoutNoteLead, '').trim();
    final explicitNote = note != text;
    if (note.isNotEmpty && (_workoutExtra.hasMatch(note) || explicitNote)) {
      final title = explicitNote
          ? note
          : note.replaceFirst(_workoutFirstPerson, '');
      return ready(
        kind: GymWorkoutCaptureKind.extra,
        title: title[0].toUpperCase() + title.substring(1),
        detail: after == null ? 'Session log' : 'After ${after.name}',
      );
    }
    return reject(GymWorkoutCaptureIssue.unknownExercise);
  }

  final values = _workoutRemainder(text.substring(named.end));
  if (exercise.kind == WorkoutExerciseKind.cardio) {
    final cardio = _readWorkoutCardio(values);
    if (cardio == null) return reject(GymWorkoutCaptureIssue.unsupportedValues);
    if (session.progressFor(exercise.id) != GymProgress.pending) {
      return reject(GymWorkoutCaptureIssue.alreadyConfirmed);
    }
    return ready(
      kind: GymWorkoutCaptureKind.cardio,
      title: exercise.name,
      detail: [
        if (cardio.distance case final distance?)
          '${_captureNumber(distance)} km',
        if (cardio.minutes case final minutes?) '$minutes min',
        if (cardio.incline case final incline?)
          '${_captureNumber(incline)}% incline',
      ].join(' · '),
      canConfirm:
          explicitCompletion &&
          cardio.distance != null &&
          cardio.minutes != null &&
          cardio.incline != null,
      cardio: cardio,
    );
  }

  final strength = _workoutStrength.firstMatch(values);
  if (strength == null) return reject(GymWorkoutCaptureIssue.unsupportedValues);
  final numbers = _workoutInteger
      .allMatches(strength.group(4)!)
      .map((match) => int.parse(match.group(0)!))
      .toList();
  final firstSet = int.tryParse(strength.group(1) ?? '');
  final start = firstSet == null ? 0 : firstSet - 1;
  if ((firstSet == null && numbers.length != exercise.sets.length) ||
      start < 0 ||
      start + numbers.length > exercise.sets.length) {
    return reject(GymWorkoutCaptureIssue.ambiguousSets);
  }
  final rawWeight = strength.group(2)?.replaceAll(',', '.');
  final rawUnit = strength.group(3);
  final unit = rawUnit == null
      ? null
      : rawUnit.toLowerCase().startsWith('k')
      ? WorkoutWeightUnit.kilograms
      : WorkoutWeightUnit.pounds;
  final weight = rawWeight == null
      ? null
      : unit!.toKilograms(double.parse(rawWeight));
  final sets = <_ReviewedSet>[];
  for (final (index, reps) in numbers.indexed) {
    final before = exercise.sets[start + index];
    if (session.progressFor(exercise.id, setId: before.id) !=
        GymProgress.pending) {
      return reject(GymWorkoutCaptureIssue.alreadyConfirmed);
    }
    sets.add((before: before, reps: reps, kilograms: weight));
  }
  final displayWeight = rawWeight == null
      ? ''
      : '$rawWeight ${unit!.symbol} × ';
  final setLabel = firstSet == null
      ? ''
      : numbers.length == 1
      ? 'Set $firstSet · '
      : 'Sets $firstSet–${start + numbers.length} · ';
  return ready(
    kind: GymWorkoutCaptureKind.strength,
    title: exercise.name,
    detail: '$setLabel$displayWeight${numbers.join(', ')} reps',
    canConfirm: explicitCompletion && weight != null,
    sets: sets,
  );
}

final _workoutCaptureLead = RegExp(
  r'^(?:gym|workout)\s*:\s*',
  caseSensitive: false,
);
final _workoutAfter = RegExp(r'^(?:after|following)\s+', caseSensitive: false);
final _workoutPast = RegExp(
  r'^(?:i\s+)?(?:did|logged|completed|finished)\s+',
  caseSensitive: false,
);
final _workoutLog = RegExp(r'^log\s+', caseSensitive: false);
final _workoutNoteLead = RegExp(
  r'^(?:note|extra)[: ]\s*',
  caseSensitive: false,
);
final _workoutFirstPerson = RegExp(r'^i\s+', caseSensitive: false);
final _workoutExtra = RegExp(
  r'^(?:i\s+)?(?:stretch(?:ed|ing)?|warm(?:ed)?[ -]up|cool(?:ed)?[ -]down|rest(?:ed)?|took a break)\b',
  caseSensitive: false,
);
final _workoutNonActual = RegExp(
  r"\b(?:not|didn['’]t|instead of|next time|tomorrow|will|might|should|plan to)\b",
  caseSensitive: false,
);
final _workoutStrength = RegExp(
  r'^(?:sets?\s+(\d{1,3})\s*[: ]+\s*)?'
  r'(?:(\d{1,7}(?:[.,]\d{1,4})?)\s*(kg|kilograms?|lb|lbs|pounds?)\s*)?'
  r'(?:[×x]|times)\s*(\d{1,4}(?:(?:\s*[,/]\s*(?:and\s+)?|\s+and\s+)\d{1,4}){0,31})\s*(?:reps?)?\s*[.!]?$',
  caseSensitive: false,
);
final _workoutInteger = RegExp(r'\d+');
final _workoutRemainderLead = RegExp(r'^\s*(?:[:,.]\s+|:\s*)?');

String _workoutRemainder(String text) =>
    text.replaceFirst(_workoutRemainderLead, '').trim();

({WorkoutExercise? exercise, int end, bool ambiguous}) _matchWorkoutExercise(
  String text,
  GymSession session,
) {
  WorkoutExercise? result;
  var end = 0;
  var ambiguous = false;
  for (final exercise in session.exercises) {
    final name = exercise.name
        .trim()
        .split(_workoutWhitespace)
        .map(RegExp.escape)
        .join(r'\s+');
    if (name.isEmpty) continue;
    final exact = RegExp(
      '^$name'
      r'(?=$|[\s,.:;])',
      caseSensitive: false,
    ).firstMatch(text);
    if (exact == null || exact.end < end) continue;
    if (exact.end == end) {
      ambiguous = true;
      continue;
    }
    result = exercise;
    end = exact.end;
    ambiguous = false;
  }
  return (exercise: result, end: end, ambiguous: ambiguous);
}

final _workoutDistance = RegExp(
  r'(?<![\p{L}\d.,+\-])(\d{1,7}(?:[.,]\d{1,4})?)\s*(km|kilomet(?:re|er)s?|mi|miles?|met(?:re|er)s?)\b',
  caseSensitive: false,
  unicode: true,
);
final _workoutMinutes = RegExp(
  r'(?<![\p{L}\d.,+\-])(\d{1,5})\s*(?:min|mins|minutes?)\b',
  caseSensitive: false,
  unicode: true,
);
final _workoutIncline = RegExp(
  r'(?<![\p{L}\d.,+\-])(?:([+\-]?\d{1,4}(?:[.,]\d{1,4})?)\s*(?:%|percent)\s*(?:incline|grade)\b'
  r'|(?:incline|grade)\s*([+\-]?\d{1,4}(?:[.,]\d{1,4})?)\s*(?:%|percent))',
  caseSensitive: false,
  unicode: true,
);
final _workoutConnector = RegExp(
  r'^(?:[\s,.!]|\b(?:in|at|for|with|and)\b)*$',
  caseSensitive: false,
);

_ReviewedCardio? _readWorkoutCardio(String values) {
  final distances = _workoutDistance.allMatches(values).toList();
  final minutes = _workoutMinutes.allMatches(values).toList();
  final inclines = _workoutIncline.allMatches(values).toList();
  if ([distances, minutes, inclines].any((matches) => matches.length > 1)) {
    return null;
  }
  final spans = [...distances, ...minutes, ...inclines]
    ..sort((a, b) => a.start.compareTo(b.start));
  if (spans.isEmpty) return null;
  var cursor = 0;
  for (final span in spans) {
    if (span.start < cursor ||
        !_workoutConnector.hasMatch(values.substring(cursor, span.start))) {
      return null;
    }
    cursor = span.end;
  }
  if (!_workoutConnector.hasMatch(values.substring(cursor))) return null;
  double? distance;
  if (distances.firstOrNull case final match?) {
    final amount = double.parse(match.group(1)!.replaceAll(',', '.'));
    final unit = match.group(2)!.toLowerCase();
    distance = unit.startsWith('mi')
        ? amount * 1.609344
        : unit.startsWith('met')
        ? amount / 1000
        : amount;
  }
  final incline = inclines.firstOrNull;
  return (
    distance: distance,
    minutes: minutes.isEmpty ? null : int.parse(minutes.single.group(1)!),
    incline: incline == null
        ? null
        : double.parse(
            (incline.group(1) ?? incline.group(2))!.replaceAll(',', '.'),
          ),
  );
}

String _captureNumber(double number) =>
    number.toString().replaceFirst(RegExp(r'\.0$'), '');
