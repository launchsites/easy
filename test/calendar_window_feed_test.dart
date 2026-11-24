import 'package:easy/calendar_sources/internal_recurrence.dart';
import 'package:easy/calendar_sources/internal_workspace_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'clearing the series during expansion fences the obsolete result',
    () async {
      final day = DateTime(2026, 11, 24);
      final feed = InternalWorkspaceFeed();
      addTearDown(feed.dispose);
      final series = InternalRecurringEvent(
        id: 'teaching',
        event: InternalEventDraft.fromDates(
          title: 'Office hours',
          category: 'study',
          start: DateTime(2026, 11, 24, 14),
          end: DateTime(2026, 11, 24, 15),
        ),
        rule: InternalRecurrenceRule(
          frequency: InternalRecurrenceFrequency.weekly,
        ),
      );
      final obsolete = feed.refresh(day: day, sources: [series]);
      await feed.refresh(day: day, sources: []);
      await obsolete;
      expect(feed.events, isEmpty);
      expect(feed.covers(day), isFalse);

      await feed.refresh(day: day, sources: [series]);
      final first = feed.events.firstWhere((row) => row.event.start.day == 24);
      expect(first.event.recurringSeriesId, 'teaching');
      expect(first.event.start.hour, 14);
      expect(first.event.isReadOnly, isFalse);
      expect(feed.covers(day), isTrue);
    },
  );
}
