import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/scheduling/task_objective_review.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Filtering objective rows preserves the full scheduling context', () {
    final now = DateTime.utc(2026, 11, 24, 9);
    DateTime at(int minutes) => now.add(Duration(minutes: minutes));
    const candidates = {
      'prepare',
      'follow-up',
      'waiting',
      'parent',
      'reserved',
      'long',
    };
    final tasks = [
      const TaskItem(
        id: 'prepare',
        title: 'Prepare',
        category: 'work',
        estimatedMinutes: 15,
      ),
      TaskItem(
        id: 'launch',
        title: 'Launch',
        category: 'personal',
        dueAt: at(30),
        prerequisiteIds: const ['prepare'],
      ),
      const TaskItem(
        id: 'follow-up',
        title: 'Follow up',
        category: 'work',
        estimatedMinutes: 10,
        prerequisiteIds: ['received'],
      ),
      TaskItem(
        id: 'received',
        title: 'Received',
        category: 'personal',
        done: true,
        completedAt: at(-5),
      ),
      const TaskItem(
        id: 'waiting',
        title: 'Waiting',
        category: 'work',
        prerequisiteIds: ['launch'],
      ),
      const TaskItem(id: 'parent', title: 'Parent project', category: 'work'),
      const TaskItem(
        id: 'child',
        title: 'Child task',
        category: 'personal',
        parentId: 'parent',
      ),
      const TaskItem(
        id: 'reserved',
        title: 'Work in its booked block',
        category: 'work',
        estimatedMinutes: 30,
      ),
      const TaskItem(
        id: 'long',
        title: 'Long work',
        category: 'work',
        estimatedMinutes: 50,
        allowSplit: true,
        minimumChunkMinutes: 12,
      ),
    ];
    final events = [
      CalendarEvent(
        id: 'other-commitment',
        title: 'Appointment',
        start: at(25),
        end: at(60),
        category: 'personal',
      ),
      CalendarEvent(
        id: 'reservation',
        title: 'Work in its booked block',
        start: at(60),
        end: at(90),
        category: 'work',
        plannedTaskId: 'reserved',
      ),
    ];
    TaskObjectiveReview review(Set<String>? ids) => reviewTaskObjectives(
      tasks: tasks,
      events: events,
      now: now,
      horizonEnd: at(120),
      workWindow: TimeSpan(now, at(90)),
      candidateIds: ids,
    );

    final all = review(null);
    final filtered = review(candidates);
    for (final (unfiltered, kept) in [
      (all.ready, filtered.ready),
      (all.later, filtered.later),
      (all.needsAttention, filtered.needsAttention),
    ]) {
      expect(
        kept.map(_facts),
        unfiltered.where((row) => candidates.contains(row.id)).map(_facts),
      );
    }
    expect(filtered.ready.first.id, 'prepare');
    expect(filtered.ready.first.dependencyDeadline?.taskId, 'launch');
    expect(
      filtered.ready.singleWhere((row) => row.id == 'long').fit,
      ObjectiveFit.split,
    );
    expect(filtered.needsAttention.single.prerequisiteTitle, 'Launch');
    expect(filtered.availableTime, const Duration(minutes: 25));
    expect(review(const {}).isEmpty, isTrue);
  });
}

Object _facts(TaskObjective row) => (
  row.id,
  row.title,
  row.readiness,
  row.fit,
  row.dueAt,
  row.preferredDate,
  row.priority,
  row.earliestStart,
  row.hold?.reason,
  row.prerequisiteTitle,
  row.additionalPrerequisiteCount,
  row.dependencyDeadline?.taskId,
  row.dependencyDeadline?.dueAt,
  row.unreservedEffort,
  row.reservedEffort,
  row.nextReservation?.start,
  row.nextReservation?.end,
  row.inReservedTime,
);
