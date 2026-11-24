import 'dart:convert';

import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:easy/calendar_sources/ics_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('count and inclusive civil end limit generated events', () {
    final counted = _series(_rule(count: 4));
    final ranged = _series(_rule(until: DateTime(2026, 11, 26)));
    expect(_visible(counted).map((value) => value.start.day), [24, 25, 26, 27]);
    expect(_visible(ranged).map((value) => value.start.day), [24, 25, 26]);
    expect(counted.event.title, 'Workshop');
    expect(
      () => counted.occurrences(
        windowStart: DateTime.utc(2026),
        windowEnd: DateTime.utc(2030),
      ),
      throwsArgumentError,
    );
    expect(() => _visible(counted, limit: 1), throwsException);
    expect(
      () => _series(_rule(until: DateTime(2026, 11, 23))),
      throwsArgumentError,
    );
  });

  test(
    'a moved occurrence preserves its ID across windows and serialization',
    () {
      final original = _series(_rule(count: 5));
      final firstView = _visible(original);
      final moved = original.edit(
        firstView[1],
        scope: InternalOccurrenceScope.one,
        event: _event(DateTime.utc(2026, 12, 16, 12), title: 'Moved workshop'),
      );
      expect(moved.id, original.id);
      expect(_visible(moved).map((item) => item.id), [
        firstView[0].id,
        firstView[2].id,
        firstView[3].id,
        firstView[4].id,
      ]);
      final restored = InternalRecurringEvent.fromJson(
        jsonDecode(jsonEncode(moved.toJson())) as Map<String, Object?>,
      );
      final detached = restored
          .occurrences(
            windowStart: DateTime.utc(2026, 12, 16),
            windowEnd: DateTime.utc(2026, 12, 17),
          )
          .single;
      expect(detached.id, firstView[1].id);
      expect(detached.event.title, 'Moved workshop');
      expect(detached.start, DateTime.utc(2026, 12, 16, 12));
      expect(
        detached.scheduledStart,
        IcsDateTime.utc(DateTime.utc(2026, 11, 25, 9)),
      );
      expect(restored.toJson(), moved.toJson());
    },
  );

  test('a future move retains past dates and consumes the original count including skips', () {
    final original = _series(_rule(count: 5));
    final ids = _visible(original).map((value) => value.id).toList();
    final skipped = original.skip(
      _visible(original)[1],
      scope: InternalOccurrenceScope.one,
    );
    final pivot = _visible(skipped)[1];
    expect(pivot.identityDate, DateTime.utc(2026, 11, 26));
    final changed = skipped.edit(
      pivot,
      scope: InternalOccurrenceScope.future,
      event: _event(DateTime.utc(2026, 11, 27, 12), title: 'New time'),
    );
    final visible = _visible(changed);
    expect(changed.id, original.id);
    expect(visible.map((value) => value.id), [ids[0], ids[2], ids[3], ids[4]]);
    expect(visible.map((value) => value.start.day), [24, 27, 28, 29]);
    expect(visible.map((value) => value.start.hour), [9, 12, 12, 12]);
    expect(visible.map((value) => value.event.title), [
      'Workshop',
      'New time',
      'New time',
      'New time',
    ]);
    expect(visible[1].rule.count, 3);
  });

  test(
    'a series-wide move keeps canonical IDs and stable selected occurrence',
    () {
      final original = _series(_rule(count: 4));
      final before = _visible(original);
      final edited = original.edit(
        before[1],
        scope: InternalOccurrenceScope.series,
        event: _event(DateTime.utc(2026, 11, 26, 10), title: 'New workshop'),
      );
      final after = _visible(edited);
      expect(edited.id, original.id);
      expect(after.map((value) => value.id), before.map((value) => value.id));
      expect(after.map((value) => value.start.day), [25, 26, 27, 28]);
      expect(after.map((value) => value.event.title).toSet(), {'New workshop'});
      expect(after[1].start, DateTime.utc(2026, 11, 26, 10));
    },
  );

  test(
    'editing series fields from a moved occurrence preserves the regular clock',
    () {
      final original = _series(_rule(count: 4));
      final detached = original.edit(
        _visible(original)[1],
        scope: InternalOccurrenceScope.one,
        event: _event(DateTime.utc(2026, 11, 29, 14)),
      );
      final target = _visible(detached)
          .singleWhere((occurrence) => occurrence.identityDate.day == 25);
      final edited = detached.edit(
        target,
        scope: InternalOccurrenceScope.series,
        event: _event(target.start, title: 'Renamed'),
      );
      expect(_visible(edited).map((occurrence) => occurrence.start), [
        for (final day in [24, 25, 26, 27]) DateTime.utc(2026, 11, day, 9),
      ]);
    },
  );

  test(
    'a new future rule preserves the past and replaces later exceptions',
    () {
      final original = _series(_rule(count: 7));
      final skipped = original.skip(
        _visible(original)[4],
        scope: InternalOccurrenceScope.one,
      );
      final pivot = _visible(skipped)[2];
      final replaced = skipped.edit(
        pivot,
        scope: InternalOccurrenceScope.future,
        event: _event(pivot.start),
        rule: InternalRecurrenceRule(
          frequency: InternalRecurrenceFrequency.weekly,
          weekdays: [DateTime.thursday],
          count: 3,
        ),
      );
      final occurrences = replaced.occurrences(
        windowStart: DateTime.utc(2026, 11, 24),
        windowEnd: DateTime.utc(2026, 12, 15),
      );
      expect(occurrences.map((item) => (item.start.month, item.start.day)), [
        (11, 24),
        (11, 25),
        (11, 26),
        (12, 3),
        (12, 10),
      ]);
      expect(occurrences[2].id, pivot.id);
    },
  );

  test('one, future and series skips survive reopening the event', () {
    final original = _series(_rule(count: 5));
    final firstView = _visible(original);
    final one = original.skip(firstView[1], scope: InternalOccurrenceScope.one);
    expect(_visible(one).map((item) => item.start.day), [24, 26, 27, 28]);
    final future = one.skip(
      _visible(one)[2],
      scope: InternalOccurrenceScope.future,
    );
    expect(_visible(future).map((item) => item.start.day), [24, 26]);
    final all = future.skip(
      _visible(future).first,
      scope: InternalOccurrenceScope.series,
    );
    expect(all.id, original.id);
    final reopened = InternalRecurringEvent.fromJson(
      jsonDecode(jsonEncode(all.toJson())) as Map<String, Object?>,
    );
    expect(_visible(reopened), isEmpty);
    expect(reopened.id, original.id);
  });

  test(
    'stale occurrence revisions and foreign series IDs reject a mutation',
    () {
      final original = _series(_rule(count: 4));
      final occurrence = _visible(original)[1];
      final modified = original.edit(
        occurrence,
        scope: InternalOccurrenceScope.one,
        event: _event(occurrence.start, title: 'Edited'),
      );
      expect(
        () => modified.skip(occurrence, scope: InternalOccurrenceScope.one),
        throwsStateError,
      );
      expect(
        () => _series(
          _rule(count: 4),
          id: 'other',
        ).skip(occurrence, scope: InternalOccurrenceScope.future),
        throwsStateError,
      );
    },
  );

  test(
    'named times keep their wall clock and skip gaps before consuming count',
    () {
      const zone = 'America/New_York';
      final series = InternalRecurringEvent(
        id: 'dst',
        event: InternalEventDraft(
          title: 'Night shift',
          category: 'work',
          start: IcsDateTime.zoned(DateTime.utc(2026, 3, 7, 2, 30), zone),
          end: IcsDateTime.zoned(DateTime.utc(2026, 3, 7, 3, 30), zone),
        ),
        rule: _rule(count: 3),
      );
      final items = series.occurrences(
        windowStart: DateTime.utc(2026, 3, 7),
        windowEnd: DateTime.utc(2026, 3, 11),
      );
      expect(items.map((item) => item.start), [
        DateTime.utc(2026, 3, 7, 7, 30),
        DateTime.utc(2026, 3, 9, 6, 30),
        DateTime.utc(2026, 3, 10, 6, 30),
      ]);
      expect(items.map((item) => item.event.start.components.hour), [2, 2, 2]);
      final changed = series.edit(
        items[1],
        scope: InternalOccurrenceScope.future,
        event: items[1].event,
      );
      final after = changed.occurrences(
        windowStart: DateTime.utc(2026, 3, 7),
        windowEnd: DateTime.utc(2026, 3, 11),
      );
      expect(after.map((item) => item.id), items.map((item) => item.id));
      expect(after.map((item) => item.start), items.map((item) => item.start));
    },
  );

  test('all-day instances keep civil dates and exclusive ends across DST', () {
    final series = InternalRecurringEvent(
      id: 'all-day',
      event: InternalEventDraft.fromDates(
        title: 'Deadline',
        start: DateTime(2026, 3, 28),
        end: DateTime(2026, 3, 30),
        category: 'work',
        allDay: true,
      ),
      rule: _rule(count: 3),
    );
    final items = series.occurrences(
      windowStart: DateTime.utc(2026, 3, 28),
      windowEnd: DateTime.utc(2026, 4),
      floatingTimeZone: 'Europe/London',
    );
    expect(items.map((item) => item.start), [
      DateTime(2026, 3, 28),
      DateTime(2026, 3, 29),
      DateTime(2026, 3, 30),
    ]);
    expect(items.map((item) => item.end), [
      DateTime(2026, 3, 30),
      DateTime(2026, 3, 31),
      DateTime(2026, 4),
    ]);
    expect(items.every((item) => item.allDay), isTrue);
  });
}

InternalRecurringEvent _series(
  InternalRecurrenceRule rule, {
  String id = 'series',
}) => InternalRecurringEvent(
  id: id,
  event: _event(DateTime.utc(2026, 11, 24, 9)),
  rule: rule,
);

InternalRecurrenceRule _rule({int? count, DateTime? until}) =>
    InternalRecurrenceRule(
      frequency: InternalRecurrenceFrequency.daily,
      count: count,
      until: until,
    );

InternalEventDraft _event(DateTime time, {String title = 'Workshop'}) =>
    InternalEventDraft.fromDates(
      title: title,
      start: time,
      end: time.add(const Duration(hours: 1)),
      category: 'study',
      location: 'Studio',
    );

List<InternalEventOccurrence> _visible(
  InternalRecurringEvent value, {
  int limit = 10000,
}) => value.occurrences(
  windowStart: DateTime.utc(2026, 11, 24),
  windowEnd: DateTime.utc(2026, 12, 2),
  limit: limit,
);
