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

    test('reads labeled clock endpoints with explicit 24-hour times', () {
      for (final text in [
        'Workshop Thu, starts at 14:30, ends at 15:45',
        'Workshop Thursday starts 14:30 and ends 15:45',
        'Workshop on Thu end time: 15:45 and start time: 14:30',
        'Workshop on Thursday begins at 14:30–15:45',
        'Workshop starts at 14:30 on Thursday ends at 15:45',
      ]) {
        final event = parseEventCapture(text, date: monday);
        expect(event.error, isNull, reason: text);
        expect(event.title, 'Workshop', reason: text);
        expect(event.start, DateTime(2026, 11, 26, 14, 30), reason: text);
        expect(event.end, DateTime(2026, 11, 26, 15, 45), reason: text);
      }
    });

    test('never turns a range boundary or uncertain time into a start', () {
      for (final text in [
        'Workshop ends at 15:30',
        'Workshop ends at 14:00–15:30',
        'Workshop until 15:30',
        'Workshop from 7 to 8',
        'Workshop begins at 7 and ends at 8',
        'Workshop after 7–8pm',
        'Workshop around 14:00 to 15:00',
        'Workshop by 14:00',
        'Workshop starts at 14:00 and starts at 15:00',
      ]) {
        final event = parseEventCapture(text, date: monday);
        expect(event.error, isNotNull, reason: text);
        expect(event.start, isNull, reason: text);
        expect(event.end, isNull, reason: text);
      }

      final title = parseEventCapture('Review after 5 meetings', date: monday);
      expect(title.title, 'Review after 5 meetings');
      expect(title.start, isNull);
      expect(title.error, isNull);
    });

    test(
      'requires exact local schedule when the date or zone is unresolved',
      () {
        for (final text in [
          'Call 03/04',
          'Call on 03/04 14:00–15:00',
          'Call 04/05/26 at 14:00',
          'Call next weekend 14:00 to 15:00',
          'Call in 3 days 14:00–15:00',
          'Call at 14:00Z',
          'Call at 14:00+02:00',
          'Call at 14:00 -0500',
          'Call 14:00–15:00 GMT',
          'Call from 14:00 to 15:00 on Thu GMT',
          'Call 14:00–15:00 @Europe/London',
          'Call at 2pm in America/Argentina/Buenos_Aires',
          'Call 2026-11-24T14:00:00Z',
        ]) {
          final event = parseEventCapture(text, date: monday);
          expect(event.error, isNotNull, reason: text);
          expect(event.start, isNull, reason: text);
          expect(event.end, isNull, reason: text);
        }

        final quoted = parseEventCapture(
          'Review “Call at 2pm PST” 14:00-15:00',
          date: monday,
        );
        expect(quoted.title, 'Review “Call at 2pm PST”');
        expect(quoted.start, DateTime(2026, 11, 23, 14));
        expect(quoted.error, isNull);
      },
    );

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

    test('consumes a spoken clock with its date and duration', () {
      for (final input in [
        "Coffee tomorrow at 10 o'clock for 30 minutes",
        'Coffee tomorrow, 10 o’clock for 30 minutes.',
        'Coffee Tomorrow at 10 o clock for 30 minutes!',
      ]) {
        final event = parseEventCapture(input, date: monday);
        expect(event.title, 'Coffee', reason: input);
        expect(event.date, DateTime(2026, 11, 24), reason: input);
        expect(event.start, DateTime(2026, 11, 24, 10), reason: input);
        expect(event.end, DateTime(2026, 11, 24, 10, 30), reason: input);
        expect(event.duration, const Duration(minutes: 30), reason: input);
        expect(event.error, isNull, reason: input);
      }

      final noEnd = parseEventCapture(
        'Coffee tomorrow at 10 o’clock',
        date: monday,
      );
      expect(noEnd.start, DateTime(2026, 11, 24, 10));
      expect(noEnd.end, isNull);
      expect(noEnd.error, isNull);
    });

    test(
      'uses explicit range periods and preserves ambiguous spoken times',
      () {
        final event = parseEventCapture(
          'Coffee tomorrow from 10 o’clock to 11 o’clock a.m.',
          date: monday,
        );
        expect(event.title, 'Coffee');
        expect(event.start, DateTime(2026, 11, 24, 10));
        expect(event.end, DateTime(2026, 11, 24, 11));
        expect(event.error, isNull);

        for (final input in [
          'Coffee tomorrow from 10 o’clock to 11 o’clock',
          'Coffee tomorrow around 10 o’clock for 30 minutes',
          'Coffee tomorrow at 10 o’clock UTC for 30 minutes',
          'Coffee tomorrow at 24 o’clock for 30 minutes',
        ]) {
          final unsafe = parseEventCapture(input, date: monday);
          expect(unsafe.start, isNull, reason: input);
          expect(unsafe.end, isNull, reason: input);
          expect(unsafe.error, isNotNull, reason: input);
        }

        final quoted = parseEventCapture(
          'Review “10 o’clock” tomorrow',
          date: monday,
        );
        expect(quoted.title, 'Review “10 o’clock”');
        expect(quoted.date, DateTime(2026, 11, 24));
        expect(quoted.start, isNull);
        expect(quoted.error, isNull);
      },
    );

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
        'Read chapters 13–15',
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

    test('keeps the explicit date when a part of the day is too vague', () {
      final event = parseEventCapture('Lunch tomorrow afternoon', date: monday);
      expect(event.date, DateTime(2026, 11, 24));
      expect(event.title, 'Lunch');
      expect(event.start, isNull);
      expect(event.end, isNull);
      expect(event.error, isNull);

      final compatible = parseEventCapture(
        'Lunch tomorrow afternoon 14:00–15:00',
        date: monday,
      );
      expect(compatible.title, 'Lunch');
      expect(compatible.start, DateTime(2026, 11, 24, 14));
      expect(compatible.end, DateTime(2026, 11, 24, 15));

      final unresolved = parseEventCapture(
        'Dinner tomorrow evening at 7 for 1h',
        date: monday,
      );
      expect(unresolved.date, DateTime(2026, 11, 24));
      expect(unresolved.start, isNull);
      expect(unresolved.error, contains('Check the time of day'));
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
        expect(task.dueAt, isNull);
      }
    });

    test('reads a punctuated spoken deadline and keeps a clean task title', () {
      for (final input in [
        "Web Design Tomorrow, 10 o'clock",
        'Web Design Tomorrow: 10 o’clock.',
        'Web Design — Tomorrow; 10 oʼclock',
        'Web Design Tomorrow — 10 o clock!',
        'Web Design Tomorrow. 10 o’clock',
        'Web Design tomorrow at 10',
      ]) {
        final task = parseTaskCapture(input, date: monday);
        expect(task.title, 'Web Design', reason: input);
        expect(task.dueDate, DateTime(2026, 11, 24), reason: input);
        expect(task.dueAt, DateTime(2026, 11, 24, 10), reason: input);
        expect(task.error, isNull, reason: input);
      }
    });

    test(
      'uses the explicit clock period and the current relative date anchor',
      () {
        final task = parseTaskCapture(
          "Web Design due tomorrow, 10 o'clock p.m.",
          date: monday,
          now: DateTime(2026, 12, 31, 23),
        );
        expect(task.title, 'Web Design');
        expect(task.dueDate, DateTime(2027));
        expect(task.dueAt, DateTime(2027, 1, 1, 22));

        final weekday = parseTaskCapture(
          'Web Design by Fri at 18:40',
          date: monday,
        );
        expect(weekday.title, 'Web Design');
        expect(weekday.dueAt, DateTime(2026, 11, 27, 18, 40));
      },
    );

    test(
      'leaves in-title clocks and undated clocks free of an exact deadline',
      () {
        final titled = parseTaskCapture(
          'Review the 10am report tomorrow',
          date: monday,
        );
        expect(titled.title, 'Review the 10am report');
        expect(titled.dueDate, DateTime(2026, 11, 24));
        expect(titled.dueAt, isNull);

        for (final input in [
          "Web Design at 10 o'clock",
          'Review “tomorrow, 10 o’clock”',
          'Compare tomorrow 10am and 11am',
        ]) {
          final task = parseTaskCapture(input, date: monday);
          expect(task.title, input);
          expect(task.dueAt, isNull);
        }
      },
    );

    test('rejects unsafe compound deadlines without discarding the text', () {
      for (final input in [
        "Web Design tomorrow, 24 o'clock",
        'Web Design tomorrow at 10:61',
        'Web Design tomorrow at 10:2',
        'Web Design tomorrow around 10 o’clock',
        'Web Design tomorrow, 10 o’clock UTC',
        'Web Design today tomorrow at 10am',
        'Web Design 11/12/2026 at 10am',
      ]) {
        final task = parseTaskCapture(input, date: monday);
        expect(task.title, input);
        expect(task.dueDate, isNull, reason: input);
        expect(task.dueAt, isNull, reason: input);
        expect(task.error, isNotNull, reason: input);
      }
    });
  });

  test('standalone time fields accept concise answers', () {
    expect(parseCaptureTime('7', date: monday), DateTime(2026, 11, 23, 7));
    expect(
      parseCaptureTime('10 o’clock', date: monday),
      DateTime(2026, 11, 23, 10),
    );
    expect(
      parseCaptureTime('at 7:30 p.m.', date: monday),
      DateTime(2026, 11, 23, 19, 30),
    );
    expect(parseCaptureTime('midnight', date: monday), monday);
    expect(parseCaptureTime('24:00', date: monday), isNull);
    expect(parseCaptureTime('8:3', date: monday), isNull);
  });

  final newYork =
      DateTime(2026, 11, 1, 0).timeZoneOffset == const Duration(hours: -4) &&
      DateTime(2026, 11, 1, 3).timeZoneOffset == const Duration(hours: -5);
  test('New York distinguishes a skipped hour and both fall-back instants', () {
    final gap = parseEventCapture('Gap 2026-03-08 02:30–04:30', date: monday);
    expect(gap.start, isNull);
    expect(gap.error, contains('skipped'));
    expect(parseCaptureTime('02:30', date: DateTime(2026, 3, 8)), isNull);

    final fold = parseEventCapture('Fold 2026-11-01 00:30–01:30', date: monday);
    expect(fold.start!.toUtc(), DateTime.utc(2026, 11, 1, 4, 30));
    expect(fold.end, isNull);
    expect(fold.error, contains('twice'));
    expect(parseCaptureTime('01:30', date: DateTime(2026, 11, 1)), isNull);

    final crossFold = parseEventCapture(
      'Fold 2026-11-01 00:30–02:30',
      date: monday,
    );
    expect(crossFold.error, isNull);
    expect(
      crossFold.end!.difference(crossFold.start!),
      const Duration(hours: 3),
    );

    final elapsed = parseEventCapture(
      'Gap 2026-03-08 01:50 for 30m',
      date: monday,
    );
    expect(elapsed.end, DateTime(2026, 3, 8, 3, 20));

    final taskGap = parseTaskCapture(
      'Finish 2026-03-08 at 02:30',
      date: monday,
    );
    expect(taskGap.dueAt, isNull);
    expect(taskGap.error, contains('skipped'));
    final taskFold = parseTaskCapture(
      'Finish 2026-11-01 at 01:30',
      date: monday,
    );
    expect(taskFold.dueAt, isNull);
    expect(taskFold.error, contains('twice'));
  }, skip: !newYork);

  final apiaSkippedDay = DateTime(2011, 12, 30).day != 30;
  test('a skipped civil day cannot silently move a task deadline', () {
    const input = "Web Design tomorrow, 10 o'clock";
    final task = parseTaskCapture(input, date: DateTime(2011, 12, 29));
    expect(task.title, input);
    expect(task.dueDate, isNull);
    expect(task.dueAt, isNull);
    expect(task.error, isNotNull);
  }, skip: !apiaSkippedDay);

  final lordHowe =
      DateTime(2026, 4, 5, 0).timeZoneOffset == const Duration(hours: 11) &&
      DateTime(2026, 4, 5, 3).timeZoneOffset ==
          const Duration(hours: 10, minutes: 30);
  test('Lord Howe validates half-hour transitions without rounding', () {
    final fold = parseEventCapture('Fold 2026-04-05 01:45–03:00', date: monday);
    expect(fold.start, isNull);
    expect(fold.error, contains('twice'));
    expect(parseCaptureTime('01:45', date: DateTime(2026, 4, 5)), isNull);

    final gap = parseEventCapture('Gap 2026-10-04 01:50–02:15', date: monday);
    expect(gap.end, isNull);
    expect(gap.error, contains('skipped'));
    expect(parseCaptureTime('02:15', date: DateTime(2026, 10, 4)), isNull);

    final elapsed = parseEventCapture(
      'Gap 2026-10-04 01:50 for 30m',
      date: monday,
    );
    expect(elapsed.end, DateTime(2026, 10, 4, 2, 50));
  }, skip: !lordHowe);
}
