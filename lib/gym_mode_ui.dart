import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';
import 'workspace_data.dart' show spaceColor;

class MobileModeFrame extends StatelessWidget {
  const MobileModeFrame({
    required this.mode,
    required this.child,
    this.modeColor,
    super.key,
  });

  final String? mode;
  final Widget child;
  final Color? modeColor;

  static const _gymStroke = Color(0xffb24f43);

  @override
  Widget build(BuildContext context) {
    final activeMode = mode?.toLowerCase();
    final insets = MediaQuery.viewPaddingOf(context);
    final stroke = activeMode == null || MediaQuery.sizeOf(context).width >= 720
        ? null
        : modeColor ??
              (activeMode == 'gym' ? _gymStroke : spaceColor(activeMode));

    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (stroke != null)
          Positioned.fill(
            left: insets.left + 4,
            top: insets.top + 4,
            right: insets.right + 4,
            bottom: insets.bottom + 4,
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
    this.onHistory,
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
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final name = workoutName?.trim() ?? '';
    final date = scheduleLabel?.trim() ?? '';
    final preview = exercises.take(5).toList();
    final compact = MediaQuery.sizeOf(context).width < 360;

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
            TextButton.icon(
              onPressed: onPlans,
              style: TextButton.styleFrom(
                padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
              ),
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.chevron_right_rounded, size: 17),
              label: const Text('Plans', semanticsLabel: 'Workout plans'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Material(
          color: raisedPaper,
          surfaceTintColor: Colors.transparent,
          elevation: .6,
          shadowColor: const Color(0x24373b2f),
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
            side: BorderSide(color: line),
            borderRadius: contentSurfaceRadius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (name.isNotEmpty || active)
                _WorkoutPlanHeading(
                  name: name.isNotEmpty ? name : 'Workout in progress',
                  date: date,
                  active: active,
                  compact: compact,
                )
              else
                const Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(17, 17, 17, 0),
                  child: Text(
                    'No workouts planned.',
                    style: contentMetadataStyle,
                  ),
                ),
              if (preview.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 17, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, exercise) in preview.indexed) ...[
                        _ExerciseLine(
                          name: exercise.name,
                          detail: exercise.detail,
                          compact: compact,
                        ),
                        if (index < preview.length - 1) const Divider(),
                      ],
                    ],
                  ),
                ),
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  16,
                  compact ? 6 : 10,
                  16,
                  compact ? 10 : 13,
                ),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (active || canStart)
                      FilledButton.icon(
                        onPressed: onWorkout,
                        icon: const Icon(Icons.play_arrow_rounded, size: 19),
                        label: Text(
                          active ? 'Resume' : 'Start',
                          semanticsLabel: active
                              ? 'Resume workout'
                              : 'Start workout',
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
                    if (onHistory != null)
                      TextButton(
                        onPressed: onHistory,
                        child: const Text('History'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkoutPlanHeading extends StatelessWidget {
  const _WorkoutPlanHeading({
    required this.name,
    required this.date,
    required this.active,
    required this.compact,
  });

  final String name;
  final String date;
  final bool active;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: shellSurface,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          17,
          compact ? 11 : 14,
          17,
          compact ? 12 : 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (date.isNotEmpty) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      active
                          ? Icons.timer_outlined
                          : Icons.calendar_today_outlined,
                      size: 14,
                      color: sidebarText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      date,
                      style: contentMetadataStyle.copyWith(color: sidebarText),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Text(
              name,
              style: TextStyle(
                color: paper,
                fontSize: compact ? 22 : 25,
                fontWeight: FontWeight.w600,
                letterSpacing: -.66,
                height: 1.12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExerciseLine extends StatelessWidget {
  const _ExerciseLine({
    required this.name,
    required this.detail,
    required this.compact,
  });

  final String name;
  final String detail;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 7 : 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              name,
              style: contentTitleStyle.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                detail,
                textAlign: TextAlign.end,
                style: compact
                    ? contentMetadataStyle.copyWith(fontSize: 12)
                    : contentMetadataStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
