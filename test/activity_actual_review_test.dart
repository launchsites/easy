import 'package:easy/activities/activities.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _original = ActivityWindow(
  DateTime.utc(2026, 11, 24, 8),
  DateTime.utc(2026, 11, 24, 9),
);
final _scheduled = ActivityWindow(
  DateTime.utc(2026, 11, 24, 10),
  DateTime.utc(2026, 11, 24, 11),
);
final _now = DateTime.utc(2026, 11, 24, 13);

ActivityActualTarget _target({
  String id = 'event-copy-271',
  ActivityWindow? scheduled,
  ActivityTargetKind kind = ActivityTargetKind.event,
}) => ActivityActualTarget(
  record: ActivityTarget(
    id: id,
    title: 'Studio session',
    category: 'work',
    kind: kind,
    plan: _original,
  ),
  scheduled: scheduled ?? _scheduled,
);

void main() {
  test(
    'timer starts at confirmation and leaves the original booked times intact',
    () {
      final target = _target();
      final beginning = ActivityActualSelection.startTimer(target)
          .apply(current: ActivityData(), target: target, now: _now);
      final active = beginning.active!;
      expect(active.target?.id, 'event-copy-271');
      expect(active.target?.kind, ActivityTargetKind.event);
      expect(active.timeSource, ActivityTimeSource.timer);
      expect(active.plan?.start, _original.start);
      expect(active.plan?.end, _original.end);
      expect(active.spans.single.start, _now);
      expect(active.spans.single.end, isNull);

      final ended = _now.add(const Duration(minutes: 22));
      final reopened = ActivityData.decode(beginning.finish(ended).encode());
      final record = reopened.records.single;
      expect(record.status, ActivityStatus.finished);
      expect(record.timeSource, ActivityTimeSource.timer);
      expect(record.plan?.start, _original.start);
      expect(record.spans.single.end, ended);
    },
  );

  test('scheduled and entered logs store distinct provenance', () {
    final target = _target();
    final recorded = ActivityActualSelection.scheduledTimes(target)
        .apply(current: ActivityData(), target: target, now: _now);
    final log = recorded.records.single;
    expect(log.timeSource, ActivityTimeSource.confirmedSchedule);
    expect(log.target?.id, target.record.id);
    expect(log.plan?.start, _original.start);
    expect(log.spans.single.start, _scheduled.start);
    expect(log.spans.single.end, _scheduled.end);
    expect(
      () =>
          ActivityActualSelection.scheduledTimes(target)
              .apply(current: recorded, target: target, now: _now),
      throwsStateError,
    );

    final nextWindow = ActivityWindow(_scheduled.end, _now);
    final edited = ActivityActualSelection.manualTimes(
      target,
      nextWindow,
    ).apply(current: recorded, target: target, now: _now);
    expect(edited.records.last.timeSource, ActivityTimeSource.manual);
    expect(edited.records.last.spans.single.start, _scheduled.end);
    final restored = ActivityData.decode(edited.encode());
    expect(restored.records.map((record) => record.timeSource), [
      ActivityTimeSource.confirmedSchedule,
      ActivityTimeSource.manual,
    ]);

    final legacy = Map<String, dynamic>.of(log.toJson())..remove('timeSource');
    expect(ActivityRecord.fromJson(legacy).timeSource, isNull);
  });

  test(
    'stale identity, moved schedule, future time and overlap are fenced again',
    () {
      final prior = _target();
      final candidate = ActivityActualSelection.scheduledTimes(prior);
      expect(
        candidate.issue(
          current: ActivityData(),
          target: _target(id: 'different'),
          now: _now,
        ),
        contains('changed'),
      );
      expect(
        candidate.issue(
          current: ActivityData(),
          target: _target(kind: ActivityTargetKind.task),
          now: _now,
        ),
        contains('changed'),
      );
      expect(
        candidate.issue(
          current: ActivityData(),
          target: _target(scheduled: ActivityWindow(_scheduled.start, _now)),
          now: _now,
        ),
        contains('changed'),
      );
      expect(
        candidate.issue(
          current: ActivityData(),
          target: prior,
          now: _scheduled.start,
        ),
        contains('future'),
      );
      final other = ActivityData().begin(
        now: _scheduled.start.add(const Duration(minutes: 10)),
        title: 'Another activity',
        category: 'personal',
      );
      expect(
        ActivityActualSelection.startTimer(prior)
            .issue(current: other, target: prior, now: _now),
        contains('current activity'),
      );
      expect(
        () => candidate.apply(current: other, target: prior, now: _now),
        throwsStateError,
      );
      expect(other.records.single.title, 'Another activity');
      expect(other.active?.spans.single.end, isNull);
    },
  );

  testWidgets(
    'an elapsed schedule needs explicit consent at narrow large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ActivityActualSelection? applied;
      await tester.pumpWidget(
        _fixture(_target(), ActivityData(), (value) => applied = value),
      );
      await tester.tap(find.text('Track studio'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use scheduled times'));
      await tester.tap(find.text('Use scheduled times'));
      await tester.pumpAndSettle();
      expect(find.text('Use scheduled times?'), findsOneWidget);
      expect(applied, isNull);
      await tester.ensureVisible(find.text('Confirm scheduled times'));
      await tester.tap(find.text('Confirm scheduled times'));
      await tester.pumpAndSettle();
      expect(applied?.kind, ActivityActualKind.scheduledTimes);
      expect(applied?.window?.start, _scheduled.start);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'active timer and unfinished planned times leave manual entry available',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(568, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ActivityActualSelection? applied;
      final data = ActivityData().begin(
        now: _now,
        title: 'Study',
        category: 'school',
      );
      final target = _target(
        scheduled: ActivityWindow(_now, _now.add(const Duration(hours: 1))),
      );
      await tester.pumpWidget(
        _fixture(target, data, (value) => applied = value),
      );
      await tester.tap(find.text('Track studio'));
      await tester.pumpAndSettle();
      final start = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Start timer'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(start.onPressed, isNull);
      expect(find.text('Use scheduled times'), findsNothing);
      await tester.ensureVisible(find.text('Log actual time'));
      await tester.tap(find.text('Log actual time'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Log these times'));
      await tester.tap(find.text('Log these times'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an exact start and end time.'), findsOneWidget);
      expect(applied, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _fixture(
  ActivityActualTarget target,
  ActivityData data,
  ValueChanged<ActivityActualSelection?> onChoice,
) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async => onChoice(
            await showActivityActualReview(
              context,
              target: target,
              data: data,
              clock: () => _now,
            ),
          ),
          child: const Text('Track studio'),
        ),
      ),
    ),
  ),
);
