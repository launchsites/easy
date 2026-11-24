import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/future_block_removal.dart';
import 'package:easy/scheduling/future_block_removal_sheet.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _completed = TaskItem(
  id: 'host',
  title: 'Set up and test the studio before opening',
  category: 'work',
  done: true,
);
final _now = DateTime.utc(2030, 9, 2, 10);

void main() {
  test(
    'previews unique, local future blocks belonging to a completed task',
    () {
      final first = _event('first', 30);
      final second = _event('second', 90);
      final events = [
        second,
        _event('past', -60),
        _event('current', 0),
        _event('running', -5),
        _event('open', 15, taskId: 'other-task'),
        _event('ordinary', 31, taskId: null),
        _event('all-day', 31, allDay: true),
        _event('recurring', 40, recurring: 'series'),
        _event('external', 48, source: 'Apple Calendar'),
        _event('copied-elsewhere', 50),
        _event('activity-link', 60),
        _event('duplicate', 62),
        _event('duplicate', 62, source: 'Imported source'),
        _event('empty-span', 65, durationMinutes: 0),
        first,
      ];
      final reviewed = FutureBlockRemovalReview.prepare(
        task: _completed,
        events: events,
        now: _now,
        protectedEventIds: {'copied-elsewhere', 'activity-link'},
      );
      expect(reviewed.blocks, [first, second]);
      expect(reviewed.taskId, _completed.id);
      expect(reviewed.taskTitle, _completed.title);
      expect(() => reviewed.blocks.clear(), throwsUnsupportedError);
      expect(reviewed.select(const []), isNull);
      expect(reviewed.select(['first', 'first']), isNull);
      expect(reviewed.select(['first', 'external']), isNull);
      expect(
        FutureBlockRemovalReview.prepare(
          task: _completed.withDone(false),
          events: events,
          now: _now,
        ).blocks,
        isEmpty,
      );
      final chosen = reviewed.select(['second'])!;
      expect(chosen.blocks, [second]);
      expect(
        chosen.remainingEvents(task: _completed, events: events, now: _now),
        events.where((event) => event != second).toList(),
      );
    },
  );

  test(
    'adding a new block preserves it through a previously reviewed selection',
    () {
      final first = _event('first', 60);
      final second = _event('second', 120);
      final later = _event('added afterward', 180);
      final task = _completed.withDone(true, completedAt: _now);
      final selection = FutureBlockRemovalReview.prepare(
        task: task,
        events: [first, second],
        now: _now,
      ).select(['first'])!;
      final remaining = selection.remainingEvents(
        task: task.withDone(true, completedAt: _now.toLocal()),
        events: [first, second, later],
        now: _now.add(const Duration(minutes: 1)),
      );
      expect(remaining, [second, later]);
      expect(() => remaining!.clear(), throwsUnsupportedError);
    },
  );

  test('stale, changed, copied, reopened, or started rows invalidate the whole approval', () {
    final earlier = _event('earlier', 30);
    final later = _event('later', 90);
    final ordinary = _event('ordinary', 35, taskId: null);
    final task = _completed.withDone(true, completedAt: _now);
    final events = [ordinary, earlier, later];
    final selection = FutureBlockRemovalReview.prepare(
      task: task,
      events: events,
      now: _now,
    ).select(['later', 'earlier'])!;
    expect(selection.blocks, [earlier, later]);
    List<CalendarEvent>? apply({
      TaskItem? currentTask,
      List<CalendarEvent>? currentEvents,
      DateTime? now,
      Set<String> protected = const {},
    }) => selection.remainingEvents(
      task: currentTask ?? task,
      events: currentEvents ?? events,
      now: now ?? _now,
      protectedEventIds: protected,
    );
    expect(apply(), [ordinary]);
    expect(apply(currentTask: task.withDone(false)), isNull);
    expect(
      apply(
        currentTask: task.withDone(
          true,
          completedAt: _now.add(const Duration(seconds: 1)),
        ),
      ),
      isNull,
    );
    expect(apply(currentEvents: [ordinary, later]), isNull);
    expect(apply(currentEvents: [ordinary, earlier, earlier, later]), isNull);
    expect(
      apply(currentEvents: [ordinary, earlier.withPlace('remote'), later]),
      isNull,
    );
    expect(
      apply(currentEvents: [ordinary, _event(earlier.id, 35), later]),
      isNull,
    );
    expect(
      apply(
        currentEvents: [
          ordinary,
          _event(earlier.id, 30, source: 'Imported source'),
          later,
        ],
      ),
      isNull,
    );
    expect(apply(protected: {later.id}), isNull);
    expect(apply(now: earlier.start), isNull);
  });

  test(
    'sparse selection preserves a large mixed calendar in its original order',
    () {
      final records = [
        for (var item = 0; item < 100000; item++)
          _event(
            'row-$item',
            item + 1,
            taskId: item % 2000 == 0 ? _completed.id : null,
          ),
      ];
      final review = FutureBlockRemovalReview.prepare(
        task: _completed,
        events: records,
        now: _now,
      );
      expect(review.blocks, hasLength(50));
      final ids = review.blocks.take(15).map((item) => item.id);
      final selection = review.select(ids)!;
      final remaining = selection.remainingEvents(
        task: _completed,
        events: records,
        now: _now,
      )!;
      expect(remaining, hasLength(99985));
      expect(remaining.first.id, 'row-1');
      expect(remaining.last.id, 'row-99999');
      expect(
        remaining.where((event) => event.plannedTaskId == _completed.id),
        hasLength(35),
      );
    },
  );

  for (final size in const [Size(320, 580), Size(568, 320)]) {
    testWidgets('compact removal review keeps selection explicit at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final records = [
        for (var item = 0; item < 1200; item++)
          _event('row-$item', 90 + item * 30),
      ];
      final review = FutureBlockRemovalReview.prepare(
        task: _completed,
        events: records,
        now: _now,
      );
      FutureBlockRemovalSelection? result;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('Open review'),
                onPressed: () async => result =
                    await showFutureBlockRemovalReview(context, review: review),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result, isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Remove selected'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(20));
      final selectAll = find.text('Select all');
      await tester.scrollUntilVisible(selectAll, 50);
      await tester.pumpAndSettle();
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(result, isNull);
      final first = find.byKey(const ValueKey('row-0'));
      await tester.scrollUntilVisible(first, 50);
      await tester.pumpAndSettle();
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('Remove 1199 blocks'));
      await tester.pumpAndSettle();
      expect(result?.blocks, hasLength(1199));
      expect(result?.blocks.first.id, 'row-1');
      expect(tester.takeException(), isNull);
    });
  }
}

CalendarEvent _event(
  String id,
  int startMinutes, {
  String? taskId = 'host',
  String? source,
  String? recurring,
  bool allDay = false,
  int durationMinutes = 25,
}) {
  final start = _now.add(Duration(minutes: startMinutes));
  return CalendarEvent(
    id: id,
    title: _completed.title,
    category: 'work',
    start: start,
    end: start.add(Duration(minutes: durationMinutes)),
    plannedTaskId: taskId,
    sourceLabel: source,
    recurringSeriesId: recurring,
    allDay: allDay,
    initialPlannedStart: start,
    initialPlannedEnd: start.add(Duration(minutes: durationMinutes)),
  );
}
