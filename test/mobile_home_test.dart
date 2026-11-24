import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('home puts the note, upcoming events and due tasks in order', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateUtils.dateOnly(now);
    final tomorrow = DateUtils.addDaysToDate(today, 1);
    final due = TaskItem(
      id: 'due',
      title: 'Review the schedule',
      category: 'work',
      date: today,
    );
    final allDay = CalendarEvent(
      id: 'all-day',
      title: 'Library book sale',
      start: today,
      end: tomorrow,
      category: 'personal',
      allDay: true,
    );
    var openedNote = false;
    CalendarEvent? openedEvent;
    TaskItem? toggledTask;
    await _show(
      tester,
      MobileHome(
        date: today,
        mode: null,
        modeControl: const Text('Mode control'),
        note: NoteItem(
          id: 'note',
          title: 'Note to self',
          body: 'Remember to bring the water bottle.',
          updated: today,
          noteToSelf: true,
        ),
        events: [
          allDay,
          CalendarEvent(
            id: 'past',
            title: 'Earlier meeting',
            start: now.subtract(const Duration(hours: 1)),
            end: now.subtract(const Duration(minutes: 1)),
            category: 'work',
          ),
          CalendarEvent(
            id: 'tomorrow',
            title: 'Tomorrow lunch',
            start: tomorrow,
            end: tomorrow.add(const Duration(hours: 1)),
            category: 'personal',
          ),
        ],
        tasks: [
          due,
          const TaskItem(id: 'inbox', title: 'Undated task', category: 'work'),
        ],
        onNoteTap: () => openedNote = true,
        onCalendarTap: () {},
        onEventTap: (event) => openedEvent = event,
        onTaskTap: (_) {},
        onTaskToggle: (task) => toggledTask = task,
      ),
    );

    final date = find.text(
      MaterialLocalizations.of(tester.element(find.byType(MobileHome)))
          .formatMediumDate(today),
    );
    final note = find.text('Note to self');
    final schedule = find.text('Upcoming today');
    final tasks = find.text('Tasks due today');
    expect(tester.getTopLeft(date).dy, lessThan(tester.getTopLeft(note).dy));
    expect(
      tester.getTopLeft(note).dy,
      lessThan(tester.getTopLeft(schedule).dy),
    );
    expect(
      tester.getTopLeft(schedule).dy,
      lessThan(tester.getTopLeft(tasks).dy),
    );
    expect(find.text('Earlier meeting'), findsNothing);
    expect(find.text('Tomorrow lunch'), findsNothing);
    expect(find.text('Undated task'), findsNothing);

    await tester.tap(find.text('Remember to bring the water bottle.'));
    await tester.tap(find.text('Library book sale'));
    await tester.tap(find.byType(Checkbox));
    expect(openedNote, isTrue);
    expect(openedEvent, same(allDay));
    expect(toggledTask, same(due));
  });

  testWidgets('Gym shows custom workout content below its own note', (
    tester,
  ) async {
    final date = DateTime(2030, 1, 10);
    final weights = const TaskItem(
      id: 'weights',
      title: 'Log working weights',
      category: 'gym',
    );
    await _show(
      tester,
      MobileHome(
        date: date,
        mode: 'gym',
        focusedContent: const Text('Upper body workout'),
        modeControl: const Text('Mode control'),
        note: NoteItem(
          id: 'gym-note',
          title: 'Warm-up',
          body: 'Start with the empty bar.',
          updated: date,
          category: 'gym',
          noteToSelf: true,
        ),
        events: [
          CalendarEvent(
            id: 'strength',
            title: 'Strength session',
            start: date.add(const Duration(hours: 12)),
            end: date.add(const Duration(hours: 13)),
            category: 'gym',
          ),
        ],
        tasks: [
          weights,
          TaskItem(
            id: 'later',
            title: 'Book next week',
            category: 'gym',
            date: DateUtils.addDaysToDate(date, 7),
          ),
        ],
        onNoteTap: () {},
        onCalendarTap: () {},
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
    );

    expect(find.text('Gym'), findsOneWidget);
    expect(find.text('Warm-up'), findsOneWidget);
    expect(find.text('Tasks due today'), findsNothing);
    expect(find.text('Book next week'), findsNothing);
    expect(find.text('Log working weights'), findsNothing);
    expect(find.text('Objectives'), findsNothing);
    expect(find.text('Schedule'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Warm-up')).dy,
      lessThan(tester.getTopLeft(find.text('Upper body workout')).dy),
    );
  });

  testWidgets('a mode omits missing note and schedule sections', (
    tester,
  ) async {
    await _show(
      tester,
      MobileHome(
        date: DateTime(2030, 1, 10),
        mode: 'gym',
        modeControl: const Text('Mode control'),
        note: null,
        events: const [],
        tasks: const [],
        onNoteTap: () {},
        onCalendarTap: () {},
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
    );

    expect(find.text('Gym'), findsOneWidget);
    expect(find.text('Objectives'), findsOneWidget);
    expect(find.text('Schedule'), findsNothing);
    expect(find.text('Note to self'), findsNothing);
  });

  testWidgets('a busy home day previews three events and can open Calendar', (
    tester,
  ) async {
    final date = DateTime(2030, 1, 10);
    var openedCalendar = false;
    await _show(
      tester,
      MobileHome(
        date: date,
        mode: null,
        modeControl: const Text('Mode control'),
        note: null,
        events: [
          for (var index = 0; index < 5; index++)
            CalendarEvent(
              id: '$index',
              title: 'Event $index',
              start: date.add(Duration(hours: index + 8)),
              end: date.add(Duration(hours: index + 9)),
              category: 'work',
            ),
        ],
        tasks: const [],
        onNoteTap: () {},
        onCalendarTap: () => openedCalendar = true,
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
    );

    expect(find.text('Event 2'), findsOneWidget);
    expect(find.text('Event 3'), findsNothing);
    expect(find.text('Event 4'), findsNothing);
    await tester.tap(find.text('+2 more'));
    expect(openedCalendar, isTrue);
  });
}

Future<void> _show(WidgetTester tester, MobileHome home) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: Scaffold(body: home),
    ),
  );
}
