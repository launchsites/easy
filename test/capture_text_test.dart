import 'package:easy/capture_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final monday = DateTime(2026, 11, 23);

  group('Event capture', () {
    test('reads a relative date and shares the range meridiem', () {
      final event = parseEventCapture(
        'Dinner with Alex tomorrow 7–8:30pm',
        date: monday,
      );
      expect(event.title, 'Dinner with Alex');
      expect(event.date, DateTime(2026, 11, 24));
      expect(event.start, DateTime(2026, 11, 24, 19));
      expect(event.end, DateTime(2026, 11, 24, 20, 30));
      expect(event.error, isNull);
    });

    test('reads a weekday and 24-hour range', () {
      final event = parseEventCapture(
        'Design review Thu 14:00-15:00',
        date: monday,
      );
      expect(event.title, 'Design review');
      expect(event.date, DateTime(2026, 11, 26));
      expect(event.start, DateTime(2026, 11, 26, 14));
      expect(event.end, DateTime(2026, 11, 26, 15));
      expect(event.error, isNull);
    });

    test('uses a duration and keeps the selected day as fallback', () {
      final event = parseEventCapture(
        'Coffee with Alex at 10am for 45m',
        date: monday,
        now: DateTime(2026, 11, 18, 14),
      );
      expect(event.title, 'Coffee with Alex');
      expect(event.date, monday);
      expect(event.start, DateTime(2026, 11, 23, 10));
      expect(event.end, DateTime(2026, 11, 23, 10, 45));
      expect(event.duration, const Duration(minutes: 45));
      expect(event.error, isNull);
    });

    test('retains an explicit duration while the start is missing', () {
      final event = parseEventCapture(
        'Focus on Friday for 1h 30m',
        date: monday,
      );
      expect(event.title, 'Focus');
      expect(event.date, DateTime(2026, 11, 27));
      expect(event.start, isNull);
      expect(event.end, isNull);
      expect(event.duration, const Duration(minutes: 90));
      expect(event.error, isNull);
    });

    test('resolves mixed period and clock notation across noon', () {
      final event = parseEventCapture('Workshop 11:30 to 1:15pm', date: monday);
      expect(event.title, 'Workshop');
      expect(event.start, DateTime(2026, 11, 23, 11, 30));
      expect(event.end, DateTime(2026, 11, 23, 13, 15));
      expect(event.error, isNull);

      final coffee = parseEventCapture('Coffee 10–11am', date: monday);
      expect(coffee.title, 'Coffee');
      expect(coffee.start, DateTime(2026, 11, 23, 10));
      expect(coffee.end, DateTime(2026, 11, 23, 11));
    });

    test('rolls an earlier end into the next month and year', () {
      final event = parseEventCapture(
        'New Year party Dec 31, 2026 11pm–1',
        date: monday,
      );
      expect(event.title, 'New Year party');
      expect(event.start, DateTime(2026, 12, 31, 23));
      expect(event.end, DateTime(2027, 1, 1, 1));
      expect(event.error, isNull);
    });

    test('treats a reversed same-half-day range as invalid', () {
      final event = parseEventCapture('Call 18:00–17:00', date: monday);
      expect(event.end, isNull);
      expect(event.error, isNotNull);
    });

    test('allows a leading date and a date between two explicit clocks', () {
      final workshop = parseEventCapture(
        'tomorrow 5pm workshop for 45m',
        date: monday,
      );
      expect(workshop.title, 'workshop');
      expect(workshop.start, DateTime(2026, 11, 24, 17));
      expect(workshop.end, DateTime(2026, 11, 24, 17, 45));

      final event = parseEventCapture(
        'project review 18:00 yesterday 19:00',
        date: monday,
      );
      expect(event.title, 'project review');
      expect(event.start, DateTime(2026, 11, 22, 18));
      expect(event.end, DateTime(2026, 11, 22, 19));
    });

    test('requests a missing end and preserves uncertain title numbers', () {
      final timeOnly = parseEventCapture('Room 7 at 10am', date: monday);
      expect(timeOnly.title, 'Room 7');
      expect(timeOnly.start, DateTime(2026, 11, 23, 10));
      expect(timeOnly.end, isNull);
      expect(timeOnly.error, isNull);

      for (final title in [
        'Review iPhone 15',
        'Read chapters 7–9',
        'Tomorrow Never Dies',
        'All Day Breakfast',
      ]) {
        final event = parseEventCapture(title, date: monday);
        expect(event.title, title);
        expect(event.start, isNull);
        expect(event.date, monday);
      }
    });

    test('leaves times unset for dates and all-day entries', () {
      final dateOnly = parseEventCapture('Lunch tomorrow', date: monday);
      expect(dateOnly.date, DateTime(2026, 11, 24));
      expect(dateOnly.start, isNull);
      expect(dateOnly.end, isNull);

      final day = parseEventCapture(
        'Holiday all day next Monday',
        date: monday,
      );
      expect(day.title, 'Holiday');
      expect(day.date, DateTime(2026, 11, 30));
      expect(day.allDay, isTrue);
      expect(day.start, isNull);
      expect(day.end, isNull);
      expect(day.error, isNull);
    });

    test(
      'keeps quoted date-like title words and reads an explicit location',
      () {
        final event = parseEventCapture(
          'Read "Tomorrow" today at noon @ The Library',
          date: monday,
        );
        expect(event.title, 'Read "Tomorrow"');
        expect(event.date, monday);
        expect(event.location, 'The Library');
        expect(event.start, DateTime(2026, 11, 23, 12));
        expect(event.end, isNull);
      },
    );

    test('does not normalise a malformed date or clock', () {
      final date = parseEventCapture('Dinner 2026-02-30 7pm', date: monday);
      expect(date.title, contains('2026-02-30'));
      expect(date.date, monday);
      expect(date.error, isNotNull);

      for (final text in [
        'Call at 25:30',
        'Call at 7:70',
        'Call at 13pm',
        'Call at 7:3',
      ]) {
        final time = parseEventCapture(text, date: monday);
        expect(time.title, text);
        expect(time.start, isNull);
        expect(time.end, isNull);
        expect(time.error, isNotNull);
      }
    });

    test('rejects equal endpoints and conflicting scheduling cues', () {
      for (final text in [
        'Call 7pm–7pm',
        'Call 7–7pm',
        'Call 7pm–8pm for 30m',
        'Call all day tomorrow at 7pm',
        'Call today tomorrow at 7pm',
      ]) {
        expect(
          parseEventCapture(text, date: monday).error,
          isNotNull,
          reason: text,
        );
      }
    });
  });

  group('Task capture', () {
    test('reads explicit relative and weekday deadlines', () {
      final task = parseTaskCapture('Send the invoice by Fri', date: monday);
      expect(task.title, 'Send the invoice');
      expect(task.dueDate, DateTime(2026, 11, 27));

      final relative = parseTaskCapture(
        'Finish slides tomorrow',
        date: monday,
        now: DateTime(2026, 11, 19, 15),
      );
      expect(relative.title, 'Finish slides');
      expect(relative.dueDate, DateTime(2026, 11, 20));
    });

    test('keeps the phrase when no clear due date is supplied', () {
      for (final title in [
        'Review Friday roadmap',
        'Send the 10am email',
        'Tomorrow',
        'Check 2026-02-30',
      ]) {
        final task = parseTaskCapture(title, date: monday);
        expect(task.title, title);
        expect(task.dueDate, isNull);
      }
    });
  });

  test('standalone time fields accept concise answers', () {
    expect(parseCaptureTime('7', date: monday), DateTime(2026, 11, 23, 7));
    expect(
      parseCaptureTime('at 7:30 p.m.', date: monday),
      DateTime(2026, 11, 23, 19, 30),
    );
    expect(parseCaptureTime('midnight', date: monday), monday);
    expect(parseCaptureTime('24:00', date: monday), isNull);
    expect(parseCaptureTime('8:3', date: monday), isNull);
  });
}
