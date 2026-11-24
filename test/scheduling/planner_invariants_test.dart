import 'dart:math';

import 'package:easy/scheduling/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '5,000 seeded schedules honour time, effort and dependency boundaries',
    () {
      const categories = ['work', 'study', 'personal'];
      final bases = [
        DateTime(2024, 2, 29, 0, 30),
        DateTime(2026, 3, 29, 0, 30),
        DateTime(2026, 10, 25, 0, 30),
        DateTime(2026, 12, 31, 23, 30),
      ];
      for (var seed = 0; seed < 5000; seed++) {
        final random = Random(seed ^ 0x627341);
        final base = bases[seed % bases.length];
        DateTime at(int minutes) => base.add(Duration(minutes: minutes));
        TimeSpan span(int first, int last) => TimeSpan(at(first), at(last));
        final horizon = span(0, 480);
        final windows = [
          for (var segment = 0; segment < 4; segment++)
            PlanningWindow(
              span(
                segment * 120 + random.nextInt(18),
                segment * 120 + 95 + random.nextInt(19),
              ),
              categories: random.nextBool()
                  ? null
                  : {categories[random.nextInt(categories.length)]},
            ),
        ];
        final commitments = List.generate(2 + random.nextInt(5), (_) {
          final start = random.nextInt(600) - 60;
          return FixedCommitment(
            span(start, start + 4 + random.nextInt(45)),
            before: Duration(minutes: random.nextInt(12)),
            after: Duration(minutes: random.nextInt(18)),
          );
        });
        final completed = <String>{'prior'};
        final tasks = <PlanningTask>[];
        for (var i = 0; i < 18; i++) {
          final id = 'item-$i';
          final done = random.nextInt(8) == 0;
          if (done) completed.add(id);
          tasks.add(
            PlanningTask(
              id: id,
              title: id,
              category: categories[random.nextInt(categories.length)],
              remainingMinutes: random.nextInt(8) == 0
                  ? null
                  : 5 + random.nextInt(75),
              earliest: random.nextBool() ? null : at(random.nextInt(420)),
              deadline: random.nextBool() ? null : at(random.nextInt(480) - 5),
              priority: PlannerPriority.values[random.nextInt(3)],
              allowSplit: random.nextBool(),
              minimumChunkMinutes: 1 + random.nextInt(18),
              prerequisites: {
                if (i > 0 && random.nextInt(3) == 0)
                  'item-${random.nextInt(i)}',
                if (random.nextInt(12) == 0) 'prior',
                if (random.nextInt(15) == 0) 'missing',
              },
              completed: done,
              needsDetails: random.nextInt(9) == 0,
            ),
          );
        }
        ScheduleProposal solve(bool reverse) => proposeSchedule(
          horizon: horizon,
          availability: reverse ? windows.reversed : windows,
          commitments: reverse ? commitments.reversed : commitments,
          tasks: reverse ? tasks.reversed : tasks,
          completedPrerequisites: {'prior'},
        );
        final plan = solve(false);
        expect(
          _signature(solve(true)),
          _signature(plan),
          reason: 'seed $seed permutation',
        );
        expect(
          plan.scheduled.length + plan.unscheduled.length,
          18 - (completed.length - 1),
          reason: 'seed $seed record count',
        );
        final scheduled = {
          for (final entry in plan.scheduled) entry.task.id: entry,
        };
        final allBlocks = <TimeSpan>[];
        for (final entry in plan.scheduled) {
          final task = entry.task;
          expect(
            completed.contains(task.id) || task.needsDetails,
            isFalse,
            reason: 'seed $seed task ${task.id}',
          );
          expect(
            entry.blocks
                .map((block) => block.length.inMinutes)
                .reduce((first, next) => first + next),
            task.remainingMinutes,
          );
          if (task.allowSplit && entry.blocks.length > 1) {
            expect(
              entry.blocks.every(
                (block) => block.length.inMinutes >= task.minimumChunkMinutes,
              ),
              isTrue,
              reason: 'seed $seed minimum chunk',
            );
          } else if (!task.allowSplit) {
            expect(entry.blocks, hasLength(1));
          }
          for (final prerequisite in task.prerequisites) {
            if (completed.contains(prerequisite)) continue;
            final previous = scheduled[prerequisite];
            expect(previous, isNotNull, reason: 'seed $seed prerequisite');
            expect(entry.blocks.first.start.isBefore(previous!.end), isFalse);
          }
          for (final block in entry.blocks) {
            expect(
              block.start.isBefore(task.earliest ?? horizon.start),
              isFalse,
            );
            expect(block.end.isAfter(task.deadline ?? horizon.end), isFalse);
            expect(
              windows.any(
                (window) =>
                    window.allows(task.category) &&
                    !block.start.isBefore(window.span.start) &&
                    !block.end.isAfter(window.span.end),
              ),
              isTrue,
              reason: 'seed $seed availability',
            );
            expect(
              commitments.any(
                (event) => block.overlaps(
                  TimeSpan(
                    event.span.start.subtract(event.before),
                    event.span.end.add(event.after),
                  ),
                ),
              ),
              isFalse,
              reason: 'seed $seed commitment buffer',
            );
            allBlocks.add(block);
          }
        }
        allBlocks.sort((first, next) => first.start.compareTo(next.start));
        for (var i = 1; i < allBlocks.length; i++) {
          expect(
            allBlocks[i].overlaps(allBlocks[i - 1]),
            isFalse,
            reason: 'seed $seed overlap',
          );
        }
      }
    },
  );

  test(
    'a 20,000-node dependency cycle terminates without scheduling participants',
    () {
      final start = DateTime.utc(2026, 11, 24);
      final horizon = TimeSpan(start, start.add(const Duration(hours: 12)));
      const count = 20000;
      final tasks = [
        for (var i = 0; i < count; i++)
          PlanningTask(
            id: '$i',
            title: 'Task $i',
            category: 'work',
            remainingMinutes: 10,
            prerequisites: {'${(i + 1) % count}'},
          ),
      ];
      final plan = proposeSchedule(
        horizon: horizon,
        availability: [PlanningWindow(horizon)],
        commitments: [],
        tasks: tasks,
      );
      expect(plan.scheduled, isEmpty);
      expect(plan.unscheduled, hasLength(count));
      expect(
        plan.unscheduled.every(
          (item) => item.problem == PlannerProblem.dependencyCycle,
        ),
        isTrue,
      );
    },
  );
}

List<String> _signature(ScheduleProposal plan) => [
  for (final entry in plan.scheduled)
    '${entry.task.id}:${entry.blocks.map((block) => '${block.start.microsecondsSinceEpoch}/${block.end.microsecondsSinceEpoch}').join(',')}',
  for (final entry in plan.unscheduled)
    '${entry.task.id}:${entry.problem.name}:${entry.prerequisiteId}',
];
