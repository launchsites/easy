import 'package:material_ui/material_ui.dart';

import '../task_model.dart';
import '../ui_theme.dart';
import 'planner.dart';

Map<String, Set<String>> requiredPlanSelections(ScheduleProposal proposal) => {
  for (final choice in proposal.scheduled)
    if (choice.task.prerequisites.isNotEmpty)
      if (choice.task.prerequisites.difference(proposal.satisfiedPrerequisites)
          case final required when required.isNotEmpty)
        choice.task.id: required,
};

bool hasUnselectedPlanPrerequisites(
  Map<String, Set<String>> required,
  Set<String> selected,
) => required.entries.any(
  (entry) => selected.contains(entry.key) && !selected.containsAll(entry.value),
);

Map<String, String> planPrerequisiteTitles(
  Iterable<TaskItem> tasks,
  Iterable<UnscheduledTask> unscheduled,
) {
  final missing = {for (final entry in unscheduled) ?entry.prerequisiteId};
  if (missing.isEmpty) return const {};
  return {
    for (final task in tasks)
      if (missing.contains(task.id)) task.id: task.title,
  };
}

String planningIssueMessage(
  UnscheduledTask issue,
  Map<String, String> titles,
) => switch (issue.problem) {
  PlannerProblem.needsDuration => 'Add an estimated duration',
  PlannerProblem.needsDetails =>
    issue.task.needsDetailsMessage ?? 'Needs more details',
  PlannerProblem.unavailableDependency =>
    switch (titles[issue.prerequisiteId]) {
      final title? => 'Waiting on $title',
      null => 'Prerequisite unavailable',
    },
  PlannerProblem.dependencyCycle => 'Prerequisite cycle',
  PlannerProblem.deadlinePassed => 'Due before this window',
  PlannerProblem.noFeasibleTime => 'No available block fits',
};

class PlanReviewFrame extends StatelessWidget {
  const PlanReviewFrame({
    required this.title,
    this.subtitle = '',
    required this.slivers,
    this.footer,
    this.maxWidth = 555,
    this.closeTooltip = 'Close plan',
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> slivers;
  final Widget? footer;
  final double maxWidth;
  final String? closeTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: screen.height * .86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: CustomScrollView(
                shrinkWrap: true,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        18,
                        14,
                        8,
                        8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: 4,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    title,
                                    style: sectionHeadingStyle.copyWith(
                                      color: colors.onSurface,
                                    ),
                                  ),
                                ),
                                if (subtitle.isNotEmpty)
                                  Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: contentMetadataStyle.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (closeTooltip case final tooltip?)
                            IconButton(
                              tooltip: tooltip,
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close_rounded),
                            ),
                        ],
                      ),
                    ),
                  ),
                  ...slivers,
                ],
              ),
            ),
            if (footer case final widget?) ...[const Divider(), widget],
          ],
        ),
      ),
    );
  }
}
