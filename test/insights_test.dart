import 'dart:convert';
import 'dart:math';

import 'package:easy/insights/insights.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final day = DateTime(2026, 11, 24);
  final end = shiftInsightDay(day, 1);
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 11, 24, hour, minute);

  test(
    'actual history crosses midnight and leaves unrecorded days unknown',
    () {
      final report = buildInsightReport(
        range: InsightRange(shiftInsightDay(day, -1), shiftInsightDay(end, 1)),
        activities: [
          InsightActivity(
            id: 'night',
            category: 'work',
            spans: [InsightWindow(DateTime(2026, 11, 23, 23, 30), at(0, 45))],
          ),
          InsightActivity(
            id: 'first',
            category: 'work',
            spans: [InsightWindow(at(9), at(11))],
          ),
          InsightActivity(
            id: 'second',
            category: 'study',
            spans: [InsightWindow(at(10), at(12))],
          ),
        ],
        tasks: const [],
      );
      expect(report.actual, const Duration(minutes: 255));
      expect(
        report.days[insightDayKey(day)]?.actual,
        const Duration(minutes: 225),
      );
      expect(report.days[insightDayKey(day)]?.activityCount, 3);
      expect(report.days[insightDayKey(end)], isNull);
      expect(report.byCategory['work'], const Duration(minutes: 195));
      expect(report.byCategory['study'], const Duration(minutes: 120));
      expect(report.toJson()['recordedDays'], 2);
    },
  );

  test(
    'overlap analytics match a minute-by-minute oracle across 600 seeds',
    () {
      final base = at(8);
      for (var seed = 0; seed < 600; seed++) {
        final random = Random(seed);
        final all = <int>{};
        final work = <int>{};
        final study = <int>{};
        final count = random.nextInt(38) + 1;
        final spans = [
          for (var index = 0; index < count; index++)
            (
              id: '$index',
              from: random.nextInt(180),
              size: random.nextInt(90),
              category: random.nextBool() ? 'work' : 'study',
            ),
        ];
        final activities = [
          for (final span in spans)
            InsightActivity(
              id: span.id,
              category: span.category,
              spans: [
                InsightWindow(
                  base.add(Duration(minutes: span.from)),
                  base.add(Duration(minutes: span.from + span.size)),
                ),
              ],
            ),
        ];
        for (final span in spans) {
          final category = span.category == 'work' ? work : study;
          for (
            var minute = span.from;
            minute < span.from + span.size;
            minute++
          ) {
            category.add(minute);
            all.add(minute);
          }
        }
        final report = buildInsightReport(
          range: InsightRange(day, end),
          activities: activities.reversed,
          tasks: const [],
        );
        expect(
          report.actual?.inMinutes,
          all.isEmpty ? null : all.length,
          reason: 'seed $seed',
        );
        expect(
          report.byCategory['work']?.inMinutes,
          work.isEmpty ? null : work.length,
        );
        expect(
          report.byCategory['study']?.inMinutes,
          study.isEmpty ? null : study.length,
        );
      }
    },
  );

  test(
    'completion, deadline and plan comparisons retain their denominators',
    () {
      final report = buildInsightReport(
        range: InsightRange(day, end),
        activities: [
          InsightActivity(
            id: 'confirmed',
            category: 'work',
            taskId: 'late',
            spans: [InsightWindow(at(9), at(9, 30))],
          ),
        ],
        tasks: [
          InsightTask(
            id: 'late',
            title: 'Late',
            category: 'work',
            dueAt: at(12),
            completedAt: at(13),
            forecastMinutes: 50,
          ),
          InsightTask(
            id: 'ontime',
            title: 'Exact',
            category: 'work',
            dueAt: at(11),
            completedAt: at(11),
          ),
          InsightTask(
            id: 'no-deadline',
            title: 'Flexible',
            category: 'work',
            completedAt: at(10),
          ),
          InsightTask(
            id: 'not-confirmed',
            title: 'Missing actual',
            category: 'work',
            dueAt: at(9),
          ),
        ],
        plans: [
          InsightPlan(
            id: 'moved',
            category: 'work',
            initial: InsightWindow(at(9), at(10)),
            accepted: InsightWindow(at(10), at(11)),
            actual: [
              InsightWindow(at(10, 15), at(11, 15)),
              InsightWindow(at(10, 45), at(11, 15)),
            ],
            outcome: InsightPlanOutcome.completed,
          ),
          InsightPlan(
            id: 'skipped',
            category: 'work',
            initial: InsightWindow(at(13), at(14)),
            accepted: InsightWindow(at(13), at(14)),
            outcome: InsightPlanOutcome.skipped,
          ),
          InsightPlan(
            id: 'unconfirmed',
            category: 'study',
            accepted: InsightWindow(at(14), at(15)),
          ),
        ],
      );
      expect(report.completedTasks, 3);
      expect(report.finishedOnTime.toJson(), {'count': 1, 'comparable': 2});
      expect(report.rescheduled.toJson(), {'count': 1, 'comparable': 2});
      expect(report.skipped.toJson(), {'count': 1, 'comparable': 2});
      expect(report.initialStartDelay.median, const Duration(minutes: 75));
      expect(report.acceptedDurationDelta.median, Duration.zero);
      expect(report.durationForecastError.median, const Duration(minutes: 20));
      expect(report.adherence.sampleSize, 1);
      expect(report.adherence.value, .75);
      expect(report.toJson()['acceptedSlotAdherence'], {
        'withinSeconds': 2700,
        'acceptedSeconds': 3600,
        'sampleSize': 1,
      });
    },
  );

  test(
    'a clock-change day uses actual elapsed instants and a civil date key',
    () {
      final spring = DateTime(2026, 3, 29);
      final tomorrow = shiftInsightDay(spring, 1);
      final report = buildInsightReport(
        range: InsightRange(spring, tomorrow),
        activities: [
          InsightActivity(
            id: 'day',
            category: 'work',
            spans: [InsightWindow(spring.toUtc(), tomorrow.toUtc())],
          ),
        ],
        tasks: const [],
      );
      expect(report.actual, tomorrow.difference(spring));
      expect(report.days.keys, ['2026-03-29']);
      expect(report.range.days, 1);
    },
  );

  test('duration learning joins by task, rejects unknown completions and resists an outlier', () {
    final tasks = [
      for (var index = 0; index < 5; index++)
        InsightTask(
          id: 'sample-$index',
          title: 'Review slides',
          category: 'study',
          completedAt: at(19),
        ),
      const InsightTask(
        id: 'unknown',
        title: 'Review slides',
        category: 'study',
      ),
    ];
    final causes = [
      for (final (index, value) in [10, 12, 14, 16, 300].indexed)
        InsightActivity(
          id: 'activity-$index',
          category: 'study',
          taskId: tasks[index].id,
          spans: [
            InsightWindow(at(8), at(8).add(Duration(minutes: value))),
            InsightWindow(at(8), at(8, 2)),
          ],
        ),
      InsightActivity(
        id: 'unfinished',
        category: 'study',
        taskId: 'unknown',
        spans: [InsightWindow(at(8), at(9))],
      ),
    ];
    final observations = buildDurationObservations(
      tasks: tasks,
      activities: causes,
    );
    expect(observations.length, 5);
    final result = learnDuration(
      const InsightTask(
        id: 'query',
        title: '  Review   slides ',
        category: 'study',
      ),
      observations,
    )!;
    expect(result.cohort, DurationCohort.sameTitle);
    expect(result.duration.inMinutes, 14);
    expect(result.lower.inMinutes, 12);
    expect(result.upper.inMinutes, 16);
    expect(result.samples, 5);
    expect(result.hasLimitedEvidence, isFalse);
    expect(
      learnDuration(
        const InsightTask(id: 'different', title: 'A run', category: 'gym'),
        observations,
      ),
      isNull,
    );
  });

  testWidgets('insights filter and export aggregates at a narrow viewport', (
    tester,
  ) async {
    _compact(tester);
    final exported = <String>[];
    await tester.pumpWidget(
      _app(
        InsightsPage(
          initialDay: day,
          activities: [
            InsightActivity(
              id: 'first',
              category: 'work',
              spans: [InsightWindow(at(9), at(11))],
            ),
            InsightActivity(
              id: 'second',
              category: 'study',
              spans: [InsightWindow(at(10), at(12))],
            ),
          ],
          tasks: [
            InsightTask(
              id: 'private-id',
              title: 'Private title',
              category: 'work',
              completedAt: at(11),
            ),
          ],
          onExportJson: (_, data) async {
            exported.add(data);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 h across 1 of 90 days'), findsOneWidget);
    await tester.tap(find.byTooltip('Filter insights by category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.pumpAndSettle();
    expect(find.text('2 h across 1 of 90 days'), findsOneWidget);

    await tester.tap(find.byTooltip('Export insights JSON'));
    await tester.pumpAndSettle();
    expect(jsonDecode(exported.single)['confirmedActualSeconds'], 7200);
    expect(exported.single, isNot(contains('Private title')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('duration evidence presents a sample without applying it', (
    tester,
  ) async {
    _compact(tester);
    final exports = <String>[];
    await tester.pumpWidget(
      _app(
        InsightsPage(
          initialDay: day,
          activities: [
            InsightActivity(
              id: 'first',
              taskId: 'finished',
              category: 'work',
              spans: [InsightWindow(at(9), at(10))],
            ),
          ],
          tasks: [
            InsightTask(
              id: 'finished',
              title: 'Plan launch',
              category: 'work',
              completedAt: at(10),
            ),
            const InsightTask(
              id: 'next',
              title: 'Plan another launch',
              category: 'work',
            ),
          ],
          onExportJson: (_, data) async {
            exports.add(data);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.text('Find a comparable task');
    await tester.scrollUntilVisible(
      open,
      160,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan another launch'));
    await tester.pumpAndSettle();
    expect(find.text('Same category · 1 sample'), findsOneWidget);
    expect(find.text('Observed range 1 h–1 h'), findsOneWidget);
    expect(find.text('Apply'), findsNothing);
    await tester.tap(find.text('Export evidence'));
    await tester.pumpAndSettle();
    expect(jsonDecode(exports.single)['medianSeconds'], 3600);
    expect(tester.takeException(), isNull);
  });
}

void _compact(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _app(Widget page) => MaterialApp(theme: easyTheme(), home: page);
