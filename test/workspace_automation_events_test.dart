import 'dart:convert';

import 'package:easy/automation/automation_models.dart';
import 'package:easy/automation/workspace_automation_events.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/review/review_data.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

final _firstFold = DateTime.parse('2026-11-01T01:30:00.123456-04:00');
final _secondFold = DateTime.parse('2026-11-01T01:30:00.123456-05:00');

TaskItem _task({
  String id = 'review-draft',
  String title = 'Review a draft',
  String category = 'work',
  bool done = true,
  DateTime? completed,
  DateTime? due,
  String? notes,
  List<String> prerequisites = const ['prep', 'reference'],
}) => TaskItem(
  id: id,
  title: title,
  category: category,
  done: done,
  completedAt: completed,
  dueAt: due,
  notes: notes,
  prerequisiteIds: prerequisites,
);

CalendarEvent _event({
  String id = 'workshop',
  String title = 'Meet with the team',
  String category = 'work',
  DateTime? start,
  DateTime? end,
  String? source,
  String? series,
  bool allDay = false,
}) => CalendarEvent(
  id: id,
  title: title,
  category: category,
  start: start ?? _firstFold,
  end: end ?? _firstFold.add(const Duration(minutes: 20)),
  allDay: allDay,
  recurringSeriesId: series,
  sourceLabel: source,
  description: 'Private calendar body',
  location: 'Private calendar location',
);

GymSession _workout(DateTime started, DateTime? finished, {String? name}) =>
    GymSession.decode(
      jsonEncode({
        'planned': name != null,
        'planName': ?name,
        'startedAt': started.toIso8601String(),
        'finishedAt': finished?.toIso8601String(),
        'entries': [
          {
            'id': 'row-one',
            'title': 'Private exercise note',
            'loggedAt': started.toIso8601String(),
            'captureText': 'Private voice transcript',
          },
        ],
      }),
    );

void main() {
  test('only a checked task with an exact completion emits an occurrence', () {
    expect(automationForTask(_task()), isNull);
    expect(
      automationForTask(_task(done: false, completed: _firstFold)),
      isNull,
    );
    expect(automationForTask(_task(id: ' ', completed: _firstFold)), isNull);
    expect(
      automationForTask(_task(id: 'm' * 1501, completed: _firstFold)),
      isNull,
    );
    final first = automationForTask(_task(completed: _firstFold))!;
    final retry = automationForTask(
      _task(
        completed: _firstFold.toLocal(),
        prerequisites: ['reference', 'prep', 'reference'],
        notes: 'Private task notes',
      ),
    )!;
    final second = automationForTask(_task(completed: _secondFold))!;
    expect(first.trigger, AutomationTrigger.taskCompleted);
    expect(first.sourceId, 'review-draft');
    expect(first.category, 'work');
    expect(first.origin, AutomationOrigin.user);
    expect(first.occurredAt, _firstFold);
    expect(first.occurrenceId, '${_firstFold.microsecondsSinceEpoch}');
    expect(retry.toJson(), first.toJson());
    expect(second.key, isNot(first.key));
    expect(jsonEncode(retry.toJson()), isNot(contains('Private task notes')));
  });

  test(
    'changes to title, category or scheduling facts invalidate a task proof',
    () {
      final original = automationForTask(_task(completed: _firstFold))!;
      for (final changed in [
        _task(completed: _firstFold, title: 'Read the draft'),
        _task(completed: _firstFold, category: 'study'),
        _task(completed: _firstFold, due: _secondFold),
        _task(completed: _firstFold, prerequisites: ['reference']),
      ]) {
        final current = automationForTask(changed)!;
        expect(current.key, original.key);
        expect(current.sourceRevision, isNot(original.sourceRevision));
        expect(current.sourceRevision, inInclusiveRange(0, 281474976710655));
      }
      final title = '${'n' * 478}🌱${'x' * 20}';
      final a = automationForTask(_task(completed: _firstFold, title: title))!;
      final b = automationForTask(
        _task(completed: _firstFold, title: '${title}y'),
      )!;
      expect(a.sourceTitle, '${'n' * 478}…');
      expect(b.sourceTitle, a.sourceTitle);
      expect(b.sourceRevision, isNot(a.sourceRevision));
    },
  );

  test('only valid timed local accepted events can start', () {
    expect(automationForCalendar(_event(source: 'Apple Calendar')), isNull);
    expect(automationForCalendar(_event(source: 'Imported ICS')), isNull);
    expect(automationForCalendar(_event(allDay: true)), isNull);
    expect(automationForCalendar(_event(id: '')), isNull);
    expect(automationForCalendar(_event(end: _firstFold)), isNull);
    expect(automationForCalendar(_event(start: _secondFold)), isNull);

    final event = automationForCalendar(_event(series: 'repeat'))!;
    expect(event.trigger, AutomationTrigger.acceptedEventStarted);
    expect(event.sourceId, 'workshop');
    expect(event.origin, AutomationOrigin.acceptedSchedule);
    expect(event.eligibleUntil, _firstFold.add(const Duration(minutes: 20)));
    expect(jsonEncode(event.toJson()), isNot(contains('Private calendar')));
  });

  test('calendar proof distinguishes both folded instants and exact edits', () {
    final first = automationForCalendar(_event())!;
    final second = automationForCalendar(
      _event(
        start: _secondFold.toLocal(),
        end: _secondFold.add(const Duration(minutes: 20)).toLocal(),
      ),
    )!;
    expect(first.occurredAt, _firstFold);
    expect(second.occurredAt, _secondFold);
    expect(second.occurredAt.difference(first.occurredAt).inHours, 1);
    expect(first.key, isNot(second.key));
    expect(first.sourceRevision, isNot(second.sourceRevision));
    final longer = automationForCalendar(
      _event(end: first.eligibleUntil!.add(const Duration(microseconds: 1))),
    )!;
    expect(longer.key, first.key);
    expect(longer.sourceRevision, isNot(first.sourceRevision));
    expect(AutomationEvent.fromJson(second.toJson()).toJson(), second.toJson());
  });

  test(
    'finished workouts keep their own identity and require elapsed activity',
    () {
      final point = GymSession.loggedCapture(
        at: _firstFold,
        entry: GymLogEntry(id: 'voice', title: 'A note', loggedAt: _firstFold),
      );
      expect(automationForWorkout(point), isNull);
      expect(automationForWorkout(GymSession.start(now: _firstFold)), isNull);
      expect(automationForWorkout(_workout(_secondFold, _firstFold)), isNull);
      final workout = _workout(_firstFold, _secondFold, name: 'Gym day');
      final event = automationForWorkout(workout)!;
      expect(event.trigger, AutomationTrigger.workoutFinished);
      expect(event.sourceId, 'workout-${_firstFold.microsecondsSinceEpoch}');
      expect(event.occurrenceId, '${_secondFold.microsecondsSinceEpoch}');
      expect(event.sourceTitle, 'Gym day');
      expect(event.category, 'gym');
      expect(event.origin, AutomationOrigin.user);
      expect(event.occurredAt, _secondFold);
      expect(event.eligibleUntil, isNull);
      final replay = automationForWorkout(GymSession.decode(workout.encode()))!;
      expect(replay.toJson(), event.toJson());
      expect(jsonEncode(event.toJson()), isNot(contains('Private')));
    },
  );

  test('a saved reflection exposes a constant preview and no private text', () {
    final note = ReviewReflection(
      id: 'daily-note',
      savedAt: _secondFold,
      achieved: 'Private result',
      obstacle: 'Private distraction',
      tomorrow: 'Private follow-up',
    );
    final reflection = automationForReflection(note)!;
    expect(reflection.trigger, AutomationTrigger.reviewSaved);
    expect(reflection.origin, AutomationOrigin.user);
    expect(reflection.sourceId, note.id);
    expect(reflection.sourceTitle, 'Reflection saved');
    expect(reflection.occurredAt, note.savedAt);
    expect(reflection.category, isNull);
    expect(jsonEncode(reflection.toJson()), isNot(contains('Private')));
    expect(reflection.sourceRevision, inInclusiveRange(0, 281474976710655));
  });
}
