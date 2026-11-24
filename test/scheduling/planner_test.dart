import 'dart:math';

import 'package:easy/scheduling/planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final origin = DateTime.utc(2026, 11, 24, 9);
  DateTime at(int minute) => origin.add(Duration(minutes: minute));
  TimeSpan span(int a, int b) => TimeSpan(at(a), at(b));
  PlanningTask task(
    String id,
    int? minutes, {
    Set<String> prerequisites = const {},
    bool split = false,
    int min = 15,
    bool completed = false,
    DateTime? release,
    DateTime? due,
    String category = 'work',
    PlannerPriority priority = PlannerPriority.normal,
  }) => PlanningTask(
    id: id,
    title: id,
    category: category,
    remainingMinutes: minutes,
    prerequisites: prerequisites,
    earliest: release,
    deadline: due,
    allowSplit: split,
    minimumChunkMinutes: min,
    completed: completed,
    priority: priority,
  );

  test('reviewed schedules require the same task and exact block instants', () {
    ScheduledTask preview({
      String id = 'draft',
      String title = 'Write draft',
      String category = 'work',
      int minutes = 30,
      int minimum = 15,
      bool split = true,
      bool blocked = false,
      PlannerPriority priority = PlannerPriority.normal,
      DateTime? release,
      DateTime? due,
      Set<String> needs = const {'research', 'brief'},
      List<TimeSpan>? blocks,
      bool local = false,
    }) {
      final earliest = release ?? at(5);
      final deadline = due ?? at(70);
      return ScheduledTask(
        task: PlanningTask(
          id: id,
          title: title,
          category: category,
          remainingMinutes: minutes,
          allowSplit: split,
          minimumChunkMinutes: minimum,
          priority: priority,
          earliest: local ? earliest.toLocal() : earliest,
          deadline: local ? deadline.toLocal() : deadline,
          prerequisites: needs,
          reservationsNeedReview: blocked,
        ),
        blocks:
            blocks ??
            [
              for (final block in [span(15, 30), span(45, 60)])
                if (local)
                  TimeSpan(block.start.toLocal(), block.end.toLocal())
                else
                  block,
            ],
        reason: 'Explicit reservation',
      );
    }

    final original = preview();
    expect(sameReviewedSchedule(original, preview()), isTrue);
    expect(
      sameReviewedSchedule(
        original,
        preview(local: true, needs: {'brief', 'research'}),
      ),
      isTrue,
    );
    for (final changed in [
      preview(id: 'another'),
      preview(title: 'Review draft'),
      preview(category: 'work-alias'),
      preview(minutes: 29),
      preview(minimum: 16),
      preview(split: false),
      preview(blocked: true),
      preview(priority: PlannerPriority.high),
      preview(release: at(6)),
      preview(due: at(71)),
      preview(needs: {'research'}),
      preview(needs: {'research', 'review'}),
      preview(blocks: [span(15, 45)]),
      preview(blocks: [span(45, 60), span(15, 30)]),
      preview(
        blocks: [
          TimeSpan(at(15).add(const Duration(microseconds: 1)), at(30)),
          span(45, 60),
        ],
      ),
    ]) {
      expect(sameReviewedSchedule(original, changed), isFalse);
    }
  });

  test('explicit hours, buffers, release and deadline are hard boundaries', () {
    final result = proposeSchedule(
      horizon: span(0, 300),
      availability: [
        PlanningWindow(span(0, 180), categories: {'work'}),
        PlanningWindow(span(190, 300), categories: {'study'}),
      ],
      commitments: [
        FixedCommitment(
          span(60, 90),
          before: const Duration(minutes: 10),
          after: const Duration(minutes: 15),
        ),
        FixedCommitment(span(-90, -10), after: const Duration(minutes: 20)),
      ],
      tasks: [
        task('draft', 40, release: at(15), due: at(145)),
        task('reading', 45, category: 'study', due: at(235)),
      ],
    );
    expect(result.unscheduled, isEmpty);
    final byId = {
      for (final placement in result.scheduled)
        placement.task.id: placement.blocks.single,
    };
    expect(byId['draft']!.start, at(105));
    expect(byId['draft']!.end, at(145));
    expect(byId['reading']!.start, at(190));
    expect(byId['reading']!.end, at(235));
  });

  test('calendar deadlines do not supply availability', () {
    final result = proposeSchedule(
      horizon: span(0, 100),
      availability: [],
      commitments: [],
      tasks: [
        task('no hours', 20, due: at(90)),
        task('missing estimate', null),
      ],
    );
    expect(result.scheduled, isEmpty);
    expect(
      {for (final value in result.unscheduled) value.task.id: value.problem},
      {
        'no hours': PlannerProblem.noFeasibleTime,
        'missing estimate': PlannerProblem.needsDuration,
      },
    );
  });

  test(
    'successful dependencies finish first and failed ones block children',
    () {
      final result = proposeSchedule(
        horizon: span(0, 200),
        availability: [PlanningWindow(span(0, 200))],
        commitments: [],
        tasks: [
          task('deliver', 30, prerequisites: {'draft'}, due: at(120)),
          task('draft', 30, prerequisites: {'completed'}),
          task('completed', 150, completed: true),
          task('failed', 400),
          task('child', 20, prerequisites: {'failed'}),
          task('cycle a', 20, prerequisites: {'cycle b'}),
          task('cycle b', 20, prerequisites: {'cycle a'}),
          task('missing', 20, prerequisites: {'deleted'}),
        ],
      );
      expect(result.scheduled.map((item) => item.task.id), [
        'draft',
        'deliver',
      ]);
      expect(result.scheduled[0].end, at(30));
      expect(result.scheduled[1].blocks.first.start, at(30));
      expect(
        {for (final value in result.unscheduled) value.task.id: value.problem},
        {
          'failed': PlannerProblem.noFeasibleTime,
          'child': PlannerProblem.unavailableDependency,
          'missing': PlannerProblem.unavailableDependency,
          'cycle a': PlannerProblem.dependencyCycle,
          'cycle b': PlannerProblem.dependencyCycle,
        },
      );
    },
  );

  test(
    'split allocation can bypass a small gap and returns no partial plan',
    () {
      final windows = [
        span(0, 30),
        span(40, 84),
        span(100, 145),
      ].map(PlanningWindow.new).toList();
      final result = proposeSchedule(
        horizon: span(0, 150),
        availability: windows,
        commitments: [],
        tasks: [task('edit', 89, split: true, min: 30)],
      );
      expect(
        result.scheduled.single.blocks.map((block) => block.length.inMinutes),
        [44, 45],
      );
      final impossible = proposeSchedule(
        horizon: span(0, 150),
        availability: windows,
        commitments: [],
        tasks: [task('edit', 119, split: true, min: 40)],
      );
      expect(impossible.scheduled, isEmpty);
      expect(
        impossible.unscheduled.single.problem,
        PlannerProblem.noFeasibleTime,
      );
    },
  );

  test(
    'matches a small exact feasibility oracle across 2500 split scenarios',
    () {
      final random = Random(72);
      for (var seed = 0; seed < 2500; seed++) {
        final count = 1 + random.nextInt(6);
        final min = 2 + random.nextInt(20);
        final minutes = 1 + random.nextInt(140);
        final capacities = List.generate(count, (_) => 1 + random.nextInt(50));
        final windows = <PlanningWindow>[];
        var offset = 0;
        for (final capacity in capacities) {
          windows.add(PlanningWindow(span(offset, offset + capacity)));
          offset += capacity + 1;
        }

        // Enumerate subsets for tiny cases. Within a subset each available
        // duration is a continuous integer range from min to its capacity.
        var feasible = capacities.any((capacity) => capacity >= minutes);
        for (var mask = 1; mask < 1 << count && !feasible; mask++) {
          var upper = 0;
          var lower = 0;
          for (var index = 0; index < count; index++) {
            if ((mask & (1 << index)) == 0) continue;
            final capacity = capacities[index];
            if (capacity < min) {
              lower = minutes + 1;
              break;
            }
            upper += capacity;
            lower += min;
          }
          feasible = lower <= minutes && minutes <= upper;
        }
        final result = proposeSchedule(
          horizon: span(0, offset),
          availability: windows,
          commitments: [],
          tasks: [task('capture', minutes, split: true, min: min)],
        );
        expect(
          result.scheduled.isNotEmpty,
          feasible,
          reason:
              'seed $seed, windows $capacities, effort $minutes, chunk $min',
        );
        if (result.scheduled.isEmpty) continue;
        final blocks = result.scheduled.single.blocks;
        expect(
          blocks.fold<int>(0, (total, block) => total + block.length.inMinutes),
          minutes,
        );
        for (final block in blocks) {
          expect(
            windows.any(
              (window) =>
                  !block.start.isBefore(window.span.start) &&
                  !block.end.isAfter(window.span.end),
            ),
            isTrue,
          );
          if (blocks.length > 1) {
            expect(block.length.inMinutes, greaterThanOrEqualTo(min));
          }
        }
      }
    },
  );

  test('reordered inputs give identical results and no overlapping blocks', () {
    final tasks = List.generate(
      1000,
      (i) => task(
        'task-$i',
        10 + (i % 20),
        split: i % 2 == 0,
        category: ['work', 'study'][i % 2],
        priority: PlannerPriority.values[i % 3],
      ),
    );
    final windows = List.generate(
      36,
      (i) => PlanningWindow(span(i * 720, i * 720 + 480)),
    );
    final busy = List.generate(
      20,
      (i) => FixedCommitment(span(i * 720 + 110, i * 720 + 180)),
    );
    ScheduleProposal solve(Iterable<PlanningTask> input) => proposeSchedule(
      horizon: span(0, 25921),
      availability: windows,
      commitments: busy,
      tasks: input,
    );
    final first = solve(tasks);
    final second = solve(tasks.reversed);
    List<String> signature(ScheduleProposal proposal) => [
      for (final value in proposal.scheduled)
        '${value.task.id} ${value.blocks.map((block) => block.start.toIso8601String()).join(',')}',
      for (final value in proposal.unscheduled)
        '${value.task.id} ${value.problem}',
    ];
    expect(signature(second), signature(first));
    expect(first.scheduled.length + first.unscheduled.length, tasks.length);
    final allBlocks = [for (final item in first.scheduled) ...item.blocks]
      ..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < allBlocks.length; i++) {
      expect(allBlocks[i - 1].overlaps(allBlocks[i]), isFalse);
    }
    expect(
      allBlocks.any((block) => busy.any((fixed) => block.overlaps(fixed.span))),
      isFalse,
    );
  });
}
