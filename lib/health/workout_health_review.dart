import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'health_models.dart';

/// Open this when [HealthData.forWorkout] identifies notes to review.
/// Cancelling leaves the caller's proposed workout untouched.
Future<WorkoutHealthDecision?> showWorkoutHealthReview(
  BuildContext context, {
  required HealthData data,
  required String? planId,
  required List<HealthExerciseTarget> exercises,
  required DateTime workoutAt,
  DateTime Function()? clock,
}) {
  final choices = {
    for (final exercise in exercises)
      if (exercise.planId == planId) exercise.exerciseId: exercise,
  };
  final notes = data.forWorkout(
    planId: planId,
    exerciseIds: choices.keys,
    workoutAt: workoutAt,
  );
  if (notes.isEmpty) return Future.value();
  final selectable = [
    for (final exercise in choices.values)
      if (notes.any(
        (item) =>
            item.allWorkouts ||
            item.exercises.any((target) => target.key == exercise.key),
      ))
        exercise,
  ];
  return showDialog<WorkoutHealthDecision>(
    context: context,
    builder: (context) => _WorkoutHealthDialog(
      planId: planId,
      workoutAt: workoutAt,
      notes: notes,
      choices: selectable,
      clock: clock ?? DateTime.now,
    ),
  );
}

class _WorkoutHealthDialog extends StatefulWidget {
  const _WorkoutHealthDialog({
    required this.planId,
    required this.workoutAt,
    required this.notes,
    required this.choices,
    required this.clock,
  });

  final String? planId;
  final DateTime workoutAt;
  final List<HealthLimitation> notes;
  final List<HealthExerciseTarget> choices;
  final DateTime Function() clock;

  @override
  State<_WorkoutHealthDialog> createState() => _WorkoutHealthDialogState();
}

class _WorkoutHealthDialogState extends State<_WorkoutHealthDialog> {
  final _skips = <String>{};

  @override
  Widget build(BuildContext context) {
    final labels = MaterialLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('Workout notes'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final limitation in widget.notes) ...[
              Text(limitation.title, style: contentTitleStyle),
              if (limitation.nextReviewOn case final review?)
                Text(
                  'Review ${labels.formatMediumDate(review)}',
                  style: contentMetadataStyle,
                ),
              if (limitation.note.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: SelectableText(limitation.note),
                ),
              const SizedBox(height: 12),
            ],
            if (widget.choices.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 10),
              const Text('Skip in this session', style: contentTitleStyle),
              for (final exercise in widget.choices)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(exercise.name),
                  value: _skips.contains(exercise.exerciseId),
                  onChanged: (selected) => setState(() {
                    if (selected == true) {
                      _skips.add(exercise.exerciseId);
                    } else {
                      _skips.remove(exercise.exerciseId);
                    }
                  }),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            WorkoutHealthDecision(
              planId: widget.planId,
              reviewedAt: widget.clock(),
              workoutAt: widget.workoutAt,
              reviewedNoteIds: widget.notes.map((note) => note.id),
              skippedExerciseIds: _skips,
            ),
          ),
          child: Text(_skips.isEmpty ? 'Continue' : 'Continue with skips'),
        ),
      ],
    );
  }
}
