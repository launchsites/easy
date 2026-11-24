import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/manual_time_block.dart';
import 'package:easy/scheduling/manual_time_block_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'manual blocks enforce exact release and deadline without estimating',
    () {
      final task = TaskItem(
        id: 'task',
        title: 'Read the agreement',
        category: 'work',
        earliestStart: _at(0, 9),
        dueAt: _at(0, 11),
      );
      expect(
        _review(task, _span(0, 8, 30)).problem,
        ManualBlockProblem.earliestStart,
      );
      expect(
        _review(task, _span(0, 10, 61)).problem,
        ManualBlockProblem.deadline,
      );
      expect(
        _review(task, _span(0, 10, 60), notBefore: _at(0, 10, 1)).problem,
        ManualBlockProblem.pastStart,
      );
      expect(
        _review(
          task,
          TimeSpan(_at(0, 10), _at(0, 10).add(const Duration(seconds: 59))),
        ).problem,
        ManualBlockProblem.invalidDuration,
      );
      final chosen = _review(task, _span(0, 10, 60));
      expect(chosen.remainingEstimateMinutes, isNull);
      final event = chosen.approve()!.calendarEvent(newId: 'block');
      expect(event.plannedTaskId, task.id);
      expect(event.start, _at(0, 10));
      expect(event.end, _at(0, 11));
      expect(event.initialPlannedStart, event.start);
      expect(event.initialPlannedEnd, event.end);
    },
  );

  test('a preferred date and overestimate each need explicit confirmation', () {
    final task = TaskItem(
      id: 'task',
      title: 'Write summary',
      category: 'work',
      date: _at(1, 0),
      estimatedMinutes: 60,
    );
    final accepted = _event('accepted', _span(0, 11, 20), taskId: task.id);
    final early = _review(task, _span(0, 9, 45), events: [accepted]);
    expect(early.remainingEstimateMinutes, 40);
    expect(early.requiresSoftDateOverride, isTrue);
    expect(early.exceedsRemainingEstimate, isTrue);
    expect(early.approve(allowEstimateOverrun: true), isNull);
    expect(early.approve(allowSoftDateOverride: true), isNull);
    final reviewed = early.approve(
      allowSoftDateOverride: true,
      allowEstimateOverrun: true,
    )!;
    expect(reviewed.overridesEstimate, isTrue);
    expect(reviewed.overridesSoftDate, isTrue);
    expect(
      reviewed.verify(tasks: [task], events: [accepted], notBefore: _at(0, 8)),
      isNotNull,
    );
    expect(
      reviewed.verify(tasks: [task], events: [], notBefore: _at(0, 8)),
      isNull,
    );
    expect(
      () => reviewed.calendarEvent(newId: accepted.id),
      throwsArgumentError,
    );
    expect(_review(task, _span(1, 23, 60)).requiresSoftDateOverride, isFalse);
    expect(_review(task, _span(1, 23, 61)).requiresSoftDateOverride, isTrue);
    expect(_review(task, _span(2, 9, 30)).requiresSoftDateOverride, isTrue);

    final exact = TaskItem(
      id: task.id,
      title: task.title,
      category: task.category,
      date: task.date,
      dueAt: _at(1, 16),
    );
    expect(_review(exact, _span(0, 9, 45)).requiresSoftDateOverride, isFalse);
  });

  test('availability and busy events preserve their exact boundaries', () {
    final task = _task();
    final settings = SchedulingSettings(
      availability: [
        WeeklyAvailability(
          id: 'work',
          weekdays: [1],
          startMinute: 9 * 60,
          endMinute: 17 * 60,
          categories: ['work'],
        ),
        WeeklyAvailability(
          id: 'lunch',
          weekdays: [1],
          startMinute: 12 * 60,
          endMinute: 13 * 60,
          kind: AvailabilityKind.unavailable,
        ),
      ],
    );
    final busy = _event(
      'Fixed call',
      _span(0, 10, 30),
      source: 'Apple Calendar',
    );
    expect(
      _review(
        task,
        _span(0, 9, 60),
        settings: settings,
        events: [busy],
      ).approve(),
      isNotNull,
    );
    final conflict = _review(
      task,
      _span(0, 10, 45),
      settings: settings,
      events: [busy],
    );
    expect(conflict.problem, ManualBlockProblem.busy);
    expect(conflict.relatedTitle, 'Fixed call');
    expect(
      _review(task, _span(0, 12, 30), settings: settings).problem,
      ManualBlockProblem.unavailable,
    );
    expect(
      _review(task, _span(1, 9, 30), settings: settings).problem,
      ManualBlockProblem.unavailable,
    );
    final allDay = _event('Leave', _span(0, 0, 1440), allDay: true);
    expect(
      _review(
        task,
        _span(0, 9, 60),
        settings: settings,
        events: [allDay],
      ).problem,
      ManualBlockProblem.busy,
    );

    final onlyExclusions = SchedulingSettings(
      availability: [settings.availability.last],
    );
    expect(
      _review(task, _span(0, 12, 30), settings: onlyExclusions).problem,
      ManualBlockProblem.unavailable,
    );
    expect(
      _review(task, _span(1, 12, 30), settings: onlyExclusions).approve(),
      isNotNull,
    );
  });

  test('manual blocks preserve setup buffers and unknown travel', () {
    final task = _task();
    final first = _event('Morning', _span(0, 9, 45), place: 'a');
    final next = _event('Afternoon', _span(0, 11, 45), place: 'b');
    final places = [
      SavedPlace(id: 'a', name: 'North'),
      SavedPlace(id: 'b', name: 'South'),
    ];
    final missing = SchedulingSettings(places: places);
    final known = SchedulingSettings(
      places: places,
      beforeMinutes: 10,
      afterMinutes: 5,
      routes: [TravelDuration(fromPlaceId: 'a', toPlaceId: 'b', minutes: 20)],
    );
    expect(
      _review(
        task,
        _span(0, 10, 20),
        events: [first, next],
        settings: missing,
      ).problem,
      ManualBlockProblem.travelUnknown,
    );
    expect(
      _review(
        task,
        _span(0, 10, 30),
        events: [first, next],
        settings: known,
      ).approve(),
      isNotNull,
    );
    expect(
      _review(
        task,
        _span(0, 10, 31),
        events: [first, next],
        settings: known,
      ).problem,
      ManualBlockProblem.buffer,
    );
    expect(
      _review(
        task,
        _span(0, 8, 59),
        events: [first, next],
        settings: known,
      ).problem,
      ManualBlockProblem.buffer,
    );
  });

  test(
    'prerequisites count unioned accepted work and confirmed completion',
    () {
      final task = _task(prerequisites: ['brief']);
      const prior = TaskItem(
        id: 'brief',
        title: 'Read brief',
        category: 'work',
        estimatedMinutes: 60,
      );
      final first = _event('first', _span(0, 8, 35), taskId: prior.id);
      final overlapping = _event(
        'overlap',
        TimeSpan(_at(0, 8, 20), _at(0, 8, 59)),
        taskId: prior.id,
      );
      final missing = _review(
        task,
        _span(0, 10, 30),
        tasks: [prior],
        events: [first, overlapping],
      );
      expect(missing.problem, ManualBlockProblem.prerequisite);
      expect(missing.relatedTitle, prior.title);
      final finalMinute = _event(
        'extra',
        TimeSpan(_at(0, 8, 59), _at(0, 9)),
        taskId: prior.id,
      );
      expect(
        _review(
          task,
          _span(0, 10, 30),
          tasks: [prior],
          events: [first, overlapping, finalMinute],
        ).approve(),
        isNotNull,
      );
      expect(
        _review(
          task,
          _span(0, 10, 30),
          tasks: [
            prior.withPrerequisites([task.id]),
          ],
          events: [first, overlapping, finalMinute],
        ).problem,
        ManualBlockProblem.prerequisite,
      );
      expect(
        _review(
          task,
          _span(0, 10, 30),
          tasks: [prior.withDone(true, completedAt: _at(0, 11))],
        ).problem,
        ManualBlockProblem.prerequisite,
      );
      expect(
        _review(
          task,
          _span(0, 10, 30),
          tasks: [
            prior.withDone(true).withPrerequisites(['removed']),
          ],
        ).approve(),
        isNotNull,
      );
    },
  );

  test(
    'moving a block preserves its accepted baseline and dependent timing',
    () {
      final task = _task(estimate: 60);
      final child = TaskItem(
        id: 'child',
        title: 'Follow up',
        category: 'work',
        prerequisiteIds: [task.id],
      );
      final original = CalendarEvent(
        id: 'selected',
        title: 'Edited accepted title',
        start: _at(0, 9),
        end: _at(0, 10),
        category: 'personal',
        description: 'Calendar context',
        location: 'Meeting room',
        savedPlaceId: 'a',
        color: Colors.purple,
        plannedTaskId: task.id,
        initialPlannedStart: _at(0, 8),
        initialPlannedEnd: _at(0, 9),
      );
      final dependent = _event('Dependent', _span(0, 10, 30), taskId: child.id);
      final blocked = _review(
        task,
        _span(0, 11, 60),
        tasks: [child],
        events: [original, dependent],
        existingId: original.id,
      );
      expect(blocked.problem, ManualBlockProblem.dependent);
      expect(blocked.relatedTitle, child.title);
      final selected = _review(
        task,
        _span(0, 8, 60),
        tasks: [child],
        events: [original, dependent],
        existingId: original.id,
      ).approve()!;
      final updated = selected.calendarEvent();
      expect(updated.id, original.id);
      expect(updated.start, _at(0, 8));
      expect(updated.end, _at(0, 9));
      expect(updated.title, original.title);
      expect(updated.description, original.description);
      expect(updated.location, original.location);
      expect(updated.savedPlaceId, original.savedPlaceId);
      expect(updated.color, original.color);
      expect(updated.category, original.category);
      expect(updated.initialPlannedStart, original.initialPlannedStart);
      expect(updated.initialPlannedEnd, original.initialPlannedEnd);
      expect(
        selected.verify(
          tasks: [task, child],
          events: [original, dependent],
          notBefore: _at(0, 8),
        ),
        isNotNull,
      );
      expect(
        selected.verify(
          tasks: [task, child],
          events: [dependent],
          notBefore: _at(0, 8),
        ),
        isNull,
      );
      expect(
        selected.verify(
          tasks: [task, child],
          events: [updated, dependent],
          notBefore: _at(0, 8),
        ),
        isNull,
      );
      expect(
        _review(
          task,
          _span(0, 8, 60),
          events: [original, updated],
          existingId: original.id,
        ).problem,
        ManualBlockProblem.calendarConflict,
      );
      final readOnly = _event(
        'external',
        _span(0, 11, 60),
        taskId: task.id,
        source: 'Import',
      );
      expect(
        _review(
          task,
          _span(0, 8, 60),
          events: [readOnly],
          existingId: readOnly.id,
        ).problem,
        ManualBlockProblem.missingBlock,
      );
    },
  );

  testWidgets(
    '320px large text review uses fresh records and explicit override',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final task = TaskItem(
        id: 'task',
        title: 'Finish the studio task',
        category: 'work',
        date: _at(1, 0),
        estimatedMinutes: 30,
      );
      var lookups = 0;
      ManualBlockSelection? accepted;
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
                child: const Text('Open schedule'),
                onPressed: () async {
                  accepted = await showModalBottomSheet<ManualBlockSelection>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ManualTimeBlockSheet(
                      task: task,
                      tasks: [task],
                      events: const [],
                      day: _at(0, 0),
                      clock: () => _at(0, 8),
                      loadContext: (span) async {
                        expect(span.start.toLocal(), _at(0, 8, 15));
                        lookups++;
                        return ManualBlockContext(
                          tasks: [task],
                          events: [
                            if (lookups == 1) _event('New busy time', span),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open schedule'));
      await tester.pumpAndSettle();
      final review = find.widgetWithText(FilledButton, 'Review time');
      Future<void> refresh() async {
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        final button = tester.widget<FilledButton>(review);
        await tester.runAsync(
          () async => (button.onPressed! as Future<void> Function())(),
        );
        await tester.pumpAndSettle();
      }

      await refresh();
      expect(find.textContaining('New busy time'), findsOneWidget);
      expect(accepted, isNull);
      await refresh();
      expect(lookups, 2);
      final approve = find.widgetWithText(FilledButton, 'Schedule block');
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      final override = find.text('Allow a block outside the preferred date');
      await tester.ensureVisible(override);
      await tester.pumpAndSettle();
      await tester.tap(override);
      await tester.pumpAndSettle();
      expect(accepted, isNull);
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(accepted?.span.start.toLocal(), _at(0, 8, 15));
      expect(accepted?.overridesSoftDate, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2030, 9, 2 + day, hour, minute);

TimeSpan _span(int day, int hour, int minutes) {
  final start = _at(day, hour);
  return TimeSpan(start, start.add(Duration(minutes: minutes)));
}

TaskItem _task({List<String> prerequisites = const [], int? estimate}) =>
    TaskItem(
      id: 'task',
      title: 'Studio task',
      category: 'work',
      prerequisiteIds: prerequisites,
      estimatedMinutes: estimate,
    );

CalendarEvent _event(
  String id,
  TimeSpan span, {
  String? taskId,
  String? source,
  String? place,
  bool allDay = false,
}) => CalendarEvent(
  id: id,
  title: id,
  start: span.start,
  end: span.end,
  category: 'personal',
  plannedTaskId: taskId,
  sourceLabel: source,
  savedPlaceId: place,
  allDay: allDay,
);

ManualBlockReview _review(
  TaskItem task,
  TimeSpan span, {
  List<TaskItem> tasks = const [],
  List<CalendarEvent> events = const [],
  SchedulingSettings? settings,
  DateTime? notBefore,
  String? existingId,
}) => reviewManualTimeBlock(
  taskId: task.id,
  span: span,
  tasks: [task, ...tasks],
  events: events,
  notBefore: notBefore ?? _at(0, 8),
  settings: settings,
  existingEventId: existingId,
);
