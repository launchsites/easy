import 'package:easy/activities/activities.dart';
import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

DateTime _at(int hour, [int minute = 0]) => DateTime(2030, 5, 6, hour, minute);

void main() {
  test(
    'timer survives serialization with pause gaps and backward wall time',
    () {
      final plan = ActivityWindow(_at(9), _at(9, 30));
      var data = ActivityData().plan(
        title: 'Draft',
        category: 'work',
        window: plan,
      );
      final id = data.records.single.id;
      expect(data.records.single.status, ActivityStatus.planned);
      expect(data.records.single.elapsedAt(_at(11)), Duration.zero);

      data = ActivityData.decode(data.beginPlan(id, _at(10)).encode());
      expect(data.active!.status, ActivityStatus.running);
      expect(data.active!.elapsedAt(_at(10, 20)), const Duration(minutes: 20));
      expect(data.active!.plan!.start.isAtSameMomentAs(_at(9)), isTrue);
      expect(
        () => data.begin(now: _at(10, 1), title: 'Another', category: 'work'),
        throwsStateError,
      );
      data = ActivityData.decode(data.pause(_at(10, 30)).encode());
      expect(data.active!.status, ActivityStatus.paused);
      expect(data.active!.elapsedAt(_at(18)), const Duration(minutes: 30));
      data = data.resume(_at(10, 10));
      expect(
        data.active!.spans.last.start.isAtSameMomentAs(_at(10, 30)),
        isTrue,
      );
      data = ActivityData.decode(data.finish(_at(10, 45)).encode());
      expect(data.active, isNull);
      expect(data.records.single.status, ActivityStatus.finished);
      expect(
        data.records.single.elapsedAt(_at(12)),
        const Duration(minutes: 45),
      );
      expect(data.records.single.plan!.length, const Duration(minutes: 30));
    },
  );

  test('actual corrections retain baseline and reject overlapping time', () {
    final original = ActivityWindow(_at(9), _at(10));
    final linked = ActivityTarget(
      id: 'event',
      title: 'Review',
      category: 'work',
      kind: ActivityTargetKind.event,
      plan: original,
    );
    final base = ActivityData().logActual(
      title: 'Review',
      category: 'work',
      target: linked,
      spans: [ActivitySpan(start: _at(9, 15), end: _at(9, 30))],
    );
    final corrected = base.logActual(
      id: base.records.single.id,
      title: 'Review corrected',
      category: 'work',
      spans: [ActivitySpan(start: _at(9, 15), end: _at(9, 40))],
    );
    expect(corrected.records.single.plan, same(original));
    expect(corrected.records.single.target, same(linked));
    expect(
      corrected.records.single.elapsedAt(_at(12)),
      const Duration(minutes: 25),
    );
    expect(
      () => corrected.logActual(
        title: 'Overlapping',
        category: 'work',
        spans: [ActivitySpan(start: _at(9, 35), end: _at(10))],
      ),
      throwsFormatException,
    );
  });

  test(
    'recurring routines copy per-run checklists without rewriting history',
    () {
      final schedule = WorkoutSchedule(
        kind: WorkoutScheduleKind.weekdays,
        startDate: _at(0),
        weekdays: [_at(0).weekday],
      );
      final routine = RoutineTemplate(
        id: 'routine',
        title: 'Setup',
        category: 'personal',
        schedule: schedule,
        steps: [const RoutineStep(id: 'open', title: 'Open notebook')],
      );
      expect(routine.occursOn(_at(8)), isTrue);
      expect(
        routine.occursOn(DateTime(_at(8).year, _at(8).month, _at(8).day + 1)),
        isFalse,
      );
      var data = ActivityData()
          .saveRoutine(routine)
          .beginRoutine(routine.id, _at(8));
      final firstId = data.active!.id;
      data = data.setStep(firstId, 'open', true).finish(_at(8, 10));
      data = data.saveRoutine(
        RoutineTemplate(
          id: routine.id,
          title: routine.title,
          category: routine.category,
          steps: [const RoutineStep(id: 'review', title: 'Review priorities')],
        ),
      );
      data = ActivityData.decode(
        data.beginRoutine(routine.id, _at(8, 15)).encode(),
      );
      expect(data.active!.steps.single.id, 'review');
      expect(data.active!.checkedStepIds, isEmpty);
      final first = data.records.singleWhere((record) => record.id == firstId);
      expect(first.steps.single.id, 'open');
      expect(first.checkedStepIds, {'open'});
    },
  );

  testWidgets(
    'failed persistence keeps activity draft and pause stays durable',
    (tester) async {
      DateTime now = _at(10);
      var saved = ActivityData();
      var fail = true;
      Future<void> persist(ActivityData next) async {
        if (fail) throw StateError('Simulated write failure');
        saved = ActivityData.decode(next.encode());
      }

      await _mount(tester, saved, persist, () => now);
      await _tap(tester, 'Start activity');
      await _enter(tester, 'Activity name', 'Write a draft');
      await _tap(tester, 'Start timer');
      expect(
        find.text('Could not save this activity change. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Write a draft'), findsOneWidget);
      expect(saved.active, isNull);
      fail = false;
      await _tap(tester, 'Start timer');
      expect(find.text('In progress'), findsOneWidget);
      now = _at(10, 5);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('5:00'), findsOneWidget);
      await _tap(tester, 'Pause');
      expect(saved.active!.status, ActivityStatus.paused);

      await tester.pumpWidget(const SizedBox());
      now = _at(10, 10);
      await _mount(tester, saved, persist, () => now);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('5:00'), findsOneWidget);
      await _tap(tester, 'Resume');
      now = _at(10, 13);
      await _tap(tester, 'Finish');
      expect(find.text('Actual history'), findsOneWidget);
      expect(saved.records.single.elapsedAt(now).inMinutes, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('routine editor adds and reorders a checklist at 320 pixels', (
    tester,
  ) async {
    var saved = ActivityData();
    var now = _at(8);
    await _mount(tester, saved, (data) async => saved = data, () => now);
    await _tap(tester, 'Routines');
    await _tap(tester, 'New routine');
    await _enter(tester, 'Routine name', 'Morning setup');
    await _tap(tester, 'Add step');
    await _enter(tester, 'Step 1', 'Open the notebook');
    await _tap(tester, 'Add step');
    await _enter(tester, 'Step 2', 'Review priorities');
    await tester.ensureVisible(find.byTooltip('Step 2 options'));
    await tester.tap(find.byTooltip('Step 2 options'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Move up');
    await _tap(tester, 'Save routine');
    expect(saved.routines.single.steps.map((step) => step.title), [
      'Review priorities',
      'Open the notebook',
    ]);
    await _tap(tester, 'Start');
    await _tap(tester, 'Review priorities');
    expect(saved.active!.checkedStepIds, {
      saved.routines.single.steps.first.id,
    });
    now = _at(8, 1);
    await _tap(tester, 'Finish');
    await _tap(tester, 'Routines');
    await _tap(tester, 'Start');
    expect(saved.active!.checkedStepIds, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(
  WidgetTester tester,
  ActivityData data,
  Future<void> Function(ActivityData) persist,
  DateTime Function() clock,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: ActivitiesPage(data: data, onChanged: persist, clock: clock),
    ),
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  final element = find.text(label);
  await tester.ensureVisible(element);
  await tester.tap(element);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final element = find.widgetWithText(EditableText, label);
  final field = element.evaluate().isEmpty
      ? find
            .ancestor(of: find.text(label), matching: find.byType(TextField))
            .first
      : element;
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}
