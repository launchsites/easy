import 'package:material_ui/material_ui.dart';

import '../task_model.dart';
import '../ui_theme.dart';
import 'plan_review_frame.dart';
import 'task_objective_review.dart';

Future<String?> showTaskObjectives(
  BuildContext context, {
  required TaskObjectiveReview review,
}) => _showObjectiveDialog(
  context,
  title: 'What can I work on?',
  subtitle: switch (review.availableTime) {
    Duration(:final inMicroseconds) when inMicroseconds == 0 =>
      'No unbooked time now',
    final gap? => '${_minutes(gap)} available',
    null => '',
  },
  slivers: (context) => [
    if (review.ready.isEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 18, 14),
          child: Text(
            review.isEmpty
                ? 'No open tasks here.'
                : 'No tasks are ready to start in this review.',
          ),
        ),
      ),
    ..._objectiveSection(context, 'Ready', 'Ready tasks', review.ready, 6),
    ..._objectiveSection(
      context,
      'Needs attention',
      'Tasks needing attention',
      review.needsAttention,
      3,
    ),
    ..._objectiveSection(context, 'Later', 'Tasks for later', review.later, 3),
  ],
);

Future<String?> _showObjectiveDialog(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext) slivers,
  String subtitle = '',
}) => showDialog<String>(
  context: context,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width < 480 ? 12 : 40,
        vertical: size.height < 450 ? 8 : 24,
      ),
      child: PlanReviewFrame(
        title: title,
        subtitle: subtitle,
        closeTooltip: 'Close suggestions',
        slivers: slivers(context),
      ),
    );
  },
);

List<Widget> _objectiveSection(
  BuildContext context,
  String title,
  String fullTitle,
  List<TaskObjective> objectives,
  int previewLimit,
) {
  if (objectives.isEmpty) return const [];
  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 18, 5),
        child: Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
      ),
    ),
    _objectiveRows(objectives, limit: objectives.length.clamp(0, previewLimit)),
    if (objectives.length > previewLimit)
      SliverToBoxAdapter(
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
            child: TextButton(
              onPressed: () async {
                final selected = await _showObjectiveDialog(
                  context,
                  title: fullTitle,
                  slivers: (_) => [
                    _objectiveRows(objectives, limit: objectives.length),
                  ],
                );
                if (context.mounted && selected != null) {
                  Navigator.pop(context, selected);
                }
              },
              child: Text('Show all ${objectives.length}'),
            ),
          ),
        ),
      ),
  ];
}

Widget _objectiveRows(List<TaskObjective> objectives, {required int limit}) =>
    SliverPadding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 7),
      sliver: SliverList.builder(
        itemCount: limit,
        itemBuilder: (context, index) => _ObjectiveTile(
          key: ValueKey(objectives[index].id),
          objective: objectives[index],
        ),
      ),
    );

class _ObjectiveTile extends StatelessWidget {
  const _ObjectiveTile({required this.objective, super.key});

  final TaskObjective objective;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locale = MaterialLocalizations.of(context);
    final clock24 = MediaQuery.alwaysUse24HourFormatOf(context);
    String day(DateTime instant) => locale.formatMediumDate(instant.toLocal());
    String time(DateTime instant) {
      final local = instant.toLocal();
      final clock = locale.formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: clock24,
      );
      return '${day(local)} at $clock';
    }

    final status = switch (objective.readiness) {
      ObjectiveReadiness.needsDetails => objective.hold!.message,
      ObjectiveReadiness.prerequisiteUnavailable => 'Review prerequisites',
      ObjectiveReadiness.waitingForPrerequisite => _waiting(objective),
      ObjectiveReadiness.startsLater =>
        'Starts ${time(objective.earliestStart!)}',
      ObjectiveReadiness.missedDeadline => 'Deadline passed',
      ObjectiveReadiness.reservedTime =>
        objective.inReservedTime
            ? 'Reserved now · until ${time(objective.nextReservation!.end)}'
            : 'Reserved ${time(objective.nextReservation!.start)}',
      ObjectiveReadiness.reservationUnavailable => 'Review calendar blocks',
      ObjectiveReadiness.hasSubtasks => 'Has open subtasks',
      ObjectiveReadiness.ready => switch (objective.fit) {
        ObjectiveFit.split => 'A shorter block fits now',
        ObjectiveFit.needsMoreTime => 'Needs a longer window',
        _ => null,
      },
    };
    final due = objective.dueAt;
    final preferred = objective.preferredDate;
    final effort = objective.unreservedEffort;
    final dependency = objective.dependencyDeadline;
    final notes = [
      ?status,
      if (due != null)
        'Due ${time(due)}'
      else if (preferred != null)
        'Preferred ${day(preferred)}',
      if (dependency != null && objective.availableToStart)
        'Helps unblock ${dependency.title} · due ${time(dependency.dueAt)}',
      if (objective.readiness == ObjectiveReadiness.ready)
        if (effort != null)
          objective.reservedEffort > Duration.zero
              ? '${_minutes(effort)} unbooked'
              : '${_minutes(effort)} estimated'
        else
          'No duration estimate',
      if (objective.priority == TaskPriority.high &&
          objective.availableToStart &&
          due == null &&
          dependency == null)
        'High priority',
    ];

    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      onTap: () => Navigator.pop(context, objective.id),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 9, 6, 9),
        child: Row(
          spacing: 9,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 3,
                children: [
                  Text(
                    objective.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: contentTitleStyle.copyWith(color: colors.onSurface),
                  ),
                  for (final note in notes)
                    Text(
                      note,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: contentMetadataStyle.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

String _waiting(TaskObjective objective) {
  final extra = objective.additionalPrerequisiteCount;
  final title = objective.prerequisiteTitle;
  return extra == 0 ? 'Waiting on $title' : 'Waiting on $title + $extra more';
}

String _minutes(Duration duration) {
  if (duration < const Duration(minutes: 1)) return 'Under 1 min';
  return '${duration.inMinutes} min';
}
