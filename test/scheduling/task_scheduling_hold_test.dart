import 'dart:convert';

import 'package:easy/calendar_page.dart';
import 'package:easy/record_editor.dart';
import 'package:easy/scheduling/manual_time_block.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/weekly_planner.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_workspace_feed.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _needTime = TaskSchedulingHold(
  reason: TaskSchedulingHoldReason.appointmentTime,
  detail: 'Ask the organizer when the game starts.',
);
const _task = TaskItem(
  id: 'game-ride',
  title: 'Take my sister to the game',
  category: 'personal',
  schedulingHold: _needTime,
  estimatedMinutes: 25,
);
DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2030, 9, 2 + day, hour, minute);
TimeSpan get _block => TimeSpan(_at(0, 10), _at(0, 10, 25));

void main() {
  test('holds survive ordinary edits, workspace storage, and old backups', () {
    final edited = _task
        .withEstimate(40)
        .withDate(_at(0, 0))
        .withPrerequisites(const ['request'])
        .withParent('project')
        .withDone(true, completedAt: _at(0, 8));
    expect(edited.schedulingHold, same(_needTime));
    final snapshot = WorkspaceData(
      tasks: [edited],
      events: const [],
      notes: const [],
    );
    final loaded = WorkspaceData.decode(snapshot.encode()).tasks.single;
    expect(
      loaded.schedulingHold?.reason,
      TaskSchedulingHoldReason.appointmentTime,
    );
    expect(loaded.schedulingHold?.detail, _needTime.detail);
    expect(loaded.done, isTrue);
    expect(loaded.dueAt, isNull);
    final resolved = loaded.withSchedulingHold(null);
    expect(resolved.schedulingHold, isNull);
    expect(resolved.id, edited.id);
    expect(resolved.estimatedMinutes, edited.estimatedMinutes);
    expect(resolved.date, edited.date);
    expect(resolved.completedAt?.isAtSameMomentAs(edited.completedAt!), isTrue);
    expect(resolved.notes, edited.notes);

    final old = jsonDecode(snapshot.encode()) as Map<String, dynamic>;
    final rawTask = (old['tasks'] as List).single as Map<String, dynamic>;
    rawTask.remove('schedulingHold');
    expect(
      WorkspaceData.decode(jsonEncode(old)).tasks.single.schedulingHold,
      isNull,
    );
    rawTask['schedulingHold'] = {
      'reason': 'newerType',
      'detail': 'Check the latest information.',
    };
    final safeDefault = WorkspaceData.decode(jsonEncode(old))
        .tasks
        .single
        .schedulingHold;
    expect(safeDefault?.reason, TaskSchedulingHoldReason.details);
    expect(safeDefault?.detail, 'Check the latest information.');
    rawTask['schedulingHold'] = 'unsupported legacy encoding';
    expect(
      WorkspaceData.decode(jsonEncode(old)).tasks.single.schedulingHold?.reason,
      TaskSchedulingHoldReason.details,
    );
  });

  test('day and week preserve a held task as an explicit unresolved item', () {
    final window = TimeSpan(_at(0, 8), _at(0, 17));
    final day = planWorkspaceDay(
      window: window,
      tasks: [_task],
      events: const [],
    );
    expect(day.scheduled, isEmpty);
    expect(day.unscheduled.single.problem, PlannerProblem.needsDetails);
    expect(day.unscheduled.single.task.needsDetailsMessage, _needTime.message);
    final hours = WeeklyPlanHours(
      weekdays: const [1],
      startMinute: 480,
      endMinute: 1020,
    );
    WeeklyPlanPreview plan(TaskItem task) => planWorkspaceWeek(
      weekStart: _at(0, 0),
      notBefore: _at(0, 8),
      tasks: [task],
      events: const [],
      hours: hours,
    )!;
    final week = plan(_task);
    expect(week.select([_task.id]), isNull);
    expect(
      week.proposal.unscheduled.single.problem,
      PlannerProblem.needsDetails,
    );
    final resolved = _task.withSchedulingHold(null);
    final reviewed = plan(resolved).select([_task.id])!;
    expect(reviewed.tasks.single.blocks.single.start.toLocal(), _at(0, 8));
    expect(
      reviewed.verify(events: const [], tasks: [_task], notBefore: _at(0, 8)),
      isNull,
    );
    expect(resolved.dueAt, isNull);
  });

  test('an accepted block for a held task cannot fulfill a prerequisite', () {
    final child = TaskItem(
      id: 'child',
      title: 'Meet after the ride',
      category: 'personal',
      estimatedMinutes: 20,
      prerequisiteIds: [_task.id],
    );
    final accepted = CalendarEvent(
      id: 'old-block',
      title: _task.title,
      category: _task.category,
      start: _at(0, 9),
      end: _at(0, 9, 25),
      plannedTaskId: _task.id,
    );
    final window = TimeSpan(_at(0, 8), _at(0, 17));
    final plan = planWorkspaceDay(
      window: window,
      tasks: [_task, child],
      events: [accepted],
    );
    expect(plan.scheduled, isEmpty);
    expect(
      {for (final issue in plan.unscheduled) issue.task.id: issue.problem},
      {
        _task.id: PlannerProblem.needsDetails,
        child.id: PlannerProblem.unavailableDependency,
      },
    );
    final manual = reviewManualTimeBlock(
      taskId: child.id,
      span: _block,
      tasks: [_task, child],
      events: [accepted],
      notBefore: _at(0, 8),
    );
    expect(manual.problem, ManualBlockProblem.prerequisite);
    final done = _task.withDone(true, completedAt: _at(0, 8));
    expect(
      reviewManualTimeBlock(
        taskId: child.id,
        span: TimeSpan(_at(0, 10), _at(0, 10, 20)),
        tasks: [done, child],
        events: [accepted],
        notBefore: _at(0, 8),
      ).approve(),
      isNotNull,
    );
  });

  test('manual scheduling rejects held tasks and stale approvals', () {
    ManualBlockReview review(TaskItem task) => reviewManualTimeBlock(
      taskId: task.id,
      span: _block,
      tasks: [task],
      events: const [],
      notBefore: _at(0, 8),
    );
    final held = review(_task);
    expect(held.problem, ManualBlockProblem.needsDetails);
    expect(held.relatedTitle, _needTime.message);
    expect(
      held.approve(allowEstimateOverrun: true, allowSoftDateOverride: true),
      isNull,
    );
    final resolved = _task.withSchedulingHold(null);
    final selected = review(resolved).approve()!;
    expect(
      selected.verify(tasks: [_task], events: const [], notBefore: _at(0, 8)),
      isNull,
    );
    expect(selected.calendarEvent(newId: 'confirmed').plannedTaskId, _task.id);
    expect(resolved.dueAt, isNull);
  });

  test('recurrence preserves holds and can resolve a single occurrence', () {
    final original = RecurringTaskSeries(
      id: _task.id,
      task: _task,
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.daily,
        count: 2,
      ),
      today: _at(0, 9),
    );
    final restored = RecurringTaskSeries.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
    );
    List<RecurringTaskOccurrence> rows(RecurringTaskSeries series) =>
        series.occurrences(windowStart: _at(0, 0), windowEnd: _at(2, 0));
    final held = rows(restored);
    expect(held.map((row) => row.task.schedulingHold?.detail), [
      _needTime.detail,
      _needTime.detail,
    ]);
    expect(held.first.canSchedule, isFalse);
    expect(
      restored.manualScheduleIssue(held.first, span: _block),
      RecurringTaskScheduleIssue.schedulingHold,
    );
    final feed = TaskWorkspaceFeed([restored]);
    final projected = weeklyWorkspaceTasks(
      feed: feed,
      tasks: [_task],
      weekStart: _at(0, 0),
    );
    expect(
      projected.map((task) => task.schedulingHold?.reason),
      List.filled(2, _needTime.reason),
    );
    final changed = restored.edit(
      held.first,
      scope: InternalOccurrenceScope.one,
      task: held.first.task.withSchedulingHold(null),
    );
    final after = rows(changed);
    expect(after.map((row) => row.id), held.map((row) => row.id));
    expect(after.first.canSchedule, isTrue);
    expect(after.last.canSchedule, isFalse);
    expect(after.first.task.dueAt, isNull);
    expect(changed.manualScheduleIssue(after.first, span: _block), isNull);
  });

  testWidgets('320px editor resolves a hold and leaves deadline fields empty', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 680);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    TaskItem? result;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('Open task editor'),
              onPressed: () async {
                result = await Navigator.of(context).push<TaskItem>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: RecordEditor(
                        date: _at(0, 0),
                        kind: RecordKind.task,
                        task: _task,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open task editor'));
    await tester.pumpAndSettle();
    expect(find.textContaining(_needTime.message), findsOneWidget);
    await tester.ensureVisible(find.text('Planning hold'));
    await tester.tap(find.text('Planning hold'));
    await tester.pumpAndSettle();
    expect(find.text('Resolve hold'), findsOneWidget);
    await tester.tap(find.text('Resolve hold'));
    await tester.pumpAndSettle();
    expect(find.textContaining(_needTime.message), findsNothing);
    expect(result, isNull);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(result?.title, _task.title);
    expect(result?.schedulingHold, isNull);
    expect(result?.dueAt, isNull);
    expect(result?.date, isNull);
    expect(tester.takeException(), isNull);
  });
}
