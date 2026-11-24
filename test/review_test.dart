import 'package:easy/review/review.dart';
import 'package:easy/ui_theme.dart';
import 'package:easy/workout_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'briefings clip and merge busy windows without guessing absent evidence',
    () {
      final day = DateTime(2026, 11, 24);
      DateTime at(int hour, [int minute = 0]) =>
          DateTime(2026, 11, 24, hour, minute);
      final events = [
        ReviewEvent(
          id: 'night',
          title: 'Shift',
          start: DateTime(2026, 11, 23, 23),
          end: at(0, 30),
        ),
        ReviewEvent(id: 'first', title: 'Lecture', start: at(9), end: at(10)),
        ReviewEvent(
          id: 'overlap',
          title: 'Class',
          start: at(9, 30),
          end: at(11),
        ),
        ReviewEvent(
          id: 'birthday',
          title: 'Birthday',
          allDay: true,
          start: day,
          end: nextReviewDay(day),
        ),
        ReviewEvent(
          id: 'outside',
          title: 'Tomorrow',
          start: nextReviewDay(day),
          end: nextReviewDay(day, 2),
        ),
      ];
      final tasks = [
        ReviewTask(
          id: 'due',
          title: 'Write notes',
          date: day,
          estimatedMinutes: 45,
        ),
        ReviewTask(id: 'hard', title: 'Send draft', dueAt: at(18).toUtc()),
        const ReviewTask(id: 'unknown', title: 'Find a date'),
        ReviewTask(
          id: 'done-unknown',
          title: 'Previously done',
          done: true,
          date: day,
        ),
        ReviewTask(
          id: 'done-known',
          title: 'Finished today',
          done: true,
          completedAt: at(12),
        ),
      ];
      final unknown = ReviewAgenda(events: events, tasks: tasks).forDay(day);
      expect(unknown.events.map((event) => event.id), [
        'night',
        'birthday',
        'first',
        'overlap',
      ]);
      expect(unknown.freeMinutes, isNull);
      expect(unknown.confirmedActivityMinutes, isNull);
      expect(unknown.scheduledMinutes, 150);
      expect(unknown.openDueTasks.map((task) => task.id), ['due', 'hard']);
      expect(unknown.knownEffortMinutes, 45);
      expect(unknown.unestimatedTasks, 1);
      expect(unknown.completedTasks.map((task) => task.id), ['done-known']);

      final known = ReviewAgenda(
        events: events,
        tasks: tasks,
        availability: [
          ReviewWindow(at(8, 30), at(9, 30)),
          ReviewWindow(at(9, 15), at(12)),
        ],
        confirmedActivityMinutes: 35,
      ).forDay(day);
      expect(known.freeMinutes, 90);
      expect(known.confirmedActivityMinutes, 35);
    },
  );

  test('reflection originals survive later entries and serialization', () {
    final day = DateTime(2026, 11, 24);
    final original = ReviewReflection(
      id: 'one',
      savedAt: day,
      achieved: 'First line\r\n  keep whitespace ',
    );
    final later = ReviewReflection(
      id: 'two',
      savedAt: day.add(const Duration(hours: 1)),
      tomorrow: 'Pick up the project',
    );
    final initial = DailyReview(day: day).withPriorities('Study then go home');
    final full = initial
        .withReflection(original)
        .withReflection(later)
        .withOutcome('event', ReviewOutcome.partial);
    expect(full.withReflection(original), same(full));
    expect(
      () => full.withReflection(
        ReviewReflection(id: 'one', savedAt: day, achieved: 'Rewrite'),
      ),
      throwsFormatException,
    );
    final saved = ReviewData().withDay(full);
    final roundtrip = ReviewData.decode(saved.encode()).dayFor(day);
    expect(roundtrip.reflections.map((entry) => entry.id), ['one', 'two']);
    expect(roundtrip.reflections.first.achieved, original.achieved);
    expect(roundtrip.priorities, initial.priorities);
    expect(roundtrip.outcomes, {'event': ReviewOutcome.partial});
    final altered = saved.toJson();
    final row = (altered['days'] as List).single as Map<String, Object?>;
    row['day'] = '2026-02-30';
    expect(() => ReviewData.fromJson(altered), throwsFormatException);
  });

  test('habit revisions and pauses preserve recorded occurrences', () {
    final start = DateTime(2026, 11, 21);
    final old = Habit(
      id: 'walk',
      revisions: [
        HabitRevision(
          effectiveOn: start,
          name: 'Lunch walk',
          schedule: WorkoutSchedule(
            kind: WorkoutScheduleKind.interval,
            startDate: start,
            intervalDays: 2,
          ),
        ),
      ],
    );
    final logged = nextReviewDay(start, 2);
    var data = ReviewData()
        .withHabit(old)
        .checkIn(id: old.id, day: logged, outcome: HabitOutcome.done);
    final changed = DateTime(2026, 11, 30);
    final next = old
        .withPause(
          HabitPause(
            start: DateTime(2026, 11, 24),
            end: DateTime(2026, 11, 26),
          ),
        )
        .withRevision(
          HabitRevision(
            effectiveOn: changed,
            name: 'Monday walk',
            schedule: WorkoutSchedule(
              kind: WorkoutScheduleKind.weekdays,
              startDate: changed,
              weekdays: [DateTime.monday],
            ),
          ),
        );
    data = data.withHabit(next);
    expect(data.habitsOn(DateTime(2026, 11, 25)), isEmpty);
    expect(data.habitsOn(DateTime(2026, 11, 27)), [next]);
    expect(data.habitsOn(changed), [next]);
    expect(data.habitsOn(nextReviewDay(changed)), isEmpty);
    expect(
      () => data.checkIn(
        id: old.id,
        day: nextReviewDay(changed),
        outcome: HabitOutcome.done,
      ),
      throwsFormatException,
    );

    final reopened = ReviewData.decode(
      data.withHabit(next.archivedFrom(changed)).encode(),
    );
    expect(reopened.habitsOn(changed), isEmpty);
    expect(reopened.habitCheckin(old.id, logged)?.outcome, HabitOutcome.done);
    expect(
      reopened.habitsOn(logged).single.revisionFor(logged)?.name,
      'Lunch walk',
    );
  });

  test('availability uses actual duration across a civil day boundary', () {
    final day = DateTime(2026, 3, 29);
    final last = nextReviewDay(day);
    final brief = ReviewAgenda(
      availability: [
        ReviewWindow(DateTime(2026, 3, 28, 23), DateTime(2026, 3, 30, 2)),
      ],
    ).forDay(day);
    expect(brief.freeMinutes, last.difference(day).inMinutes);
  });

  testWidgets(
    'a failed reflection save preserves the draft for retry on a compact phone',
    (tester) async {
      _phone(tester);
      var data = ReviewData();
      var fail = true;
      final day = DateTime(2026, 11, 24, 19);
      await tester.pumpWidget(
        _app(
          day: day,
          data: data,
          onChanged: (next) async {
            if (fail) throw StateError('storage busy');
            data = next;
          },
        ),
      );
      final write = find.text('Write reflection');
      await tester.ensureVisible(write);
      await tester.pumpAndSettle();
      await tester.tap(write);
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'What did you get done?');
      await tester.enterText(field, 'Fixed the checklist');
      await tester.tap(find.text('Save reflection'));
      await tester.pumpAndSettle();
      expect(
        find.text('The entry could not be saved. Try again.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Fixed the checklist',
      );
      fail = false;
      await tester.tap(find.text('Save reflection'));
      await tester.pumpAndSettle();
      expect(find.text('Reflect on the day'), findsNothing);
      expect(
        data.dayFor(day).reflections.single.achieved,
        'Fixed the checklist',
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'History'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 reflection ·'), findsOneWidget);
      await tester.tap(find.text('Show month'));
      await tester.pumpAndSettle();
      expect(find.text('November 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'habit check-ins remain available after a new recurring habit is saved',
    (tester) async {
      _phone(tester);
      var data = ReviewData();
      final day = DateTime(2026, 11, 24, 19);
      await tester.pumpWidget(
        _app(day: day, data: data, onChanged: (next) async => data = next),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Habits'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New habit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Habit name'),
        'Read ten pages',
      );
      await tester.tap(find.text('Save habit'));
      await tester.pumpAndSettle();
      expect(data.habits.single.revisionFor(day)?.name, 'Read ten pages');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Day'));
      await tester.pumpAndSettle();
      final done = find.byTooltip('Mark Read ten pages done');
      await tester.ensureVisible(done);
      await tester.pumpAndSettle();
      await tester.tap(done);
      await tester.pumpAndSettle();

      expect(
        data.habitCheckin(data.habits.single.id, day)?.outcome,
        HabitOutcome.done,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('roll forward is explicit and skips tasks with exact deadlines', (
    tester,
  ) async {
    _phone(tester);
    final day = DateTime(2026, 11, 24, 19);
    final flexible = ReviewTask(
      id: 'flexible',
      title: 'Review notes',
      date: day,
    );
    final hard = ReviewTask(
      id: 'hard',
      title: 'Submit assignment',
      date: day,
      dueAt: day.add(const Duration(hours: 1)),
    );
    final moved = <(String, String)>[];
    await tester.pumpWidget(
      _app(
        day: day,
        agenda: ReviewAgenda(tasks: [flexible, hard]),
        onRollForward: (task, date) async =>
            moved.add((task.id, reviewDayKey(date))),
      ),
    );
    expect(
      find.byTooltip('Move Submit assignment to another day'),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Move Review notes to another day'));
    await tester.pumpAndSettle();
    expect(moved, isEmpty);
    await tester.tap(find.text('Move task'));
    await tester.pumpAndSettle();
    expect(moved, [('flexible', '2026-11-25')]);
  });
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _app({
  required DateTime day,
  ReviewData? data,
  ReviewAgenda agenda = const ReviewAgenda(),
  Future<void> Function(ReviewData)? onChanged,
  Future<void> Function(ReviewTask, DateTime)? onRollForward,
}) => MaterialApp(
  theme: easyTheme(),
  home: ReviewPage(
    data: data ?? ReviewData(),
    clock: () => day,
    agendaForDay: (_) => agenda,
    onChanged: onChanged ?? (_) async {},
    onRollForward: onRollForward,
  ),
);
