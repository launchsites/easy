import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';
import 'workspace_data.dart' show spaceColor;

class MobileModeFrame extends StatelessWidget {
  const MobileModeFrame({required this.mode, required this.child, super.key});

  final String? mode;
  final Widget child;

  static const _gymStroke = Color(0xffb24f43);

  @override
  Widget build(BuildContext context) {
    final activeMode = mode?.toLowerCase();
    final stroke = activeMode == null || MediaQuery.sizeOf(context).width >= 720
        ? null
        : activeMode == 'gym'
        ? _gymStroke
        : spaceColor(activeMode);

    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (stroke != null)
          Positioned.fill(
            left: 4,
            top: 4,
            right: 4,
            bottom: 4,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: stroke, width: 2),
                    borderRadius: BorderRadius.circular(23),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class GymWorkoutOverview extends StatelessWidget {
  const GymWorkoutOverview({
    required this.workoutName,
    required this.scheduleLabel,
    required this.exercises,
    required this.active,
    required this.canStart,
    required this.onWorkout,
    required this.onPlans,
    required this.onFreestyle,
    super.key,
  });

  final String? workoutName;
  final String? scheduleLabel;
  final List<({String name, String detail})> exercises;
  final bool active;
  final bool canStart;
  final VoidCallback onWorkout;
  final VoidCallback onPlans;
  final VoidCallback onFreestyle;

  @override
  Widget build(BuildContext context) {
    final name = workoutName?.trim() ?? '';
    final date = scheduleLabel?.trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: const Text('Workout', style: sectionHeadingStyle),
              ),
            ),
            TextButton(
              onPressed: onPlans,
              child: const Text('Plans', semanticsLabel: 'Workout plans'),
            ),
          ],
        ),
        if (name.isNotEmpty || active)
          Text(
            name.isNotEmpty ? name : 'Workout in progress',
            style: const TextStyle(
              color: ink,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -.22,
              height: 1.25,
            ),
          )
        else
          const Text(
            'No workouts planned.',
            style: TextStyle(color: muted, fontSize: 14),
          ),
        if (date.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(date, style: const TextStyle(color: muted, fontSize: 13)),
        ],
        if (exercises.isNotEmpty) ...[
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: const BoxDecoration(
              border: BorderDirectional(start: BorderSide(color: line)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final exercise in exercises.take(5))
                    _ExerciseLine(name: exercise.name, detail: exercise.detail),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (active || canStart)
              FilledButton(
                onPressed: onWorkout,
                child: Text(
                  active ? 'Resume' : 'Start',
                  semanticsLabel: active ? 'Resume workout' : 'Start workout',
                ),
              ),
            if (!active)
              TextButton(
                onPressed: onFreestyle,
                child: const Text(
                  'Freestyle',
                  semanticsLabel: 'Start a freestyle workout',
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ExerciseLine extends StatelessWidget {
  const _ExerciseLine({required this.name, required this.detail});

  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              name,
              style: const TextStyle(
                color: ink,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Text(
                detail,
                textAlign: TextAlign.end,
                style: const TextStyle(color: muted, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
