import 'package:easy/calendar_page.dart';
import 'package:easy/list_pages.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter/services.dart';
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

  testWidgets('compact home supports large text and keyboard note editing', (
    tester,
  ) async {
    var openedNote = false;
    await _show(
      tester,
      MobileHome(
        date: DateTime(2030, 1, 10),
        mode: null,
        modeControl: TextButton(onPressed: () {}, child: const Text('Mode')),
        note: null,
        events: const [],
        tasks: const [],
        onNoteTap: () => openedNote = true,
        onCalendarTap: () {},
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
      size: const Size(320, 568),
      textScale: 1.8,
    );

    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('Mode')).right, lessThan(320));
    expect(tester.getRect(find.text('Write a note')).left, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(openedNote, isTrue);
  });

  testWidgets('wide home keeps content within a readable centered column', (
    tester,
  ) async {
    await _show(
      tester,
      MobileHome(
        date: DateTime(2030, 1, 10),
        mode: 'study',
        modeControl: const Text('Mode'),
        note: null,
        events: const [],
        tasks: const [],
        onNoteTap: () {},
        onCalendarTap: () {},
        onEventTap: (_) {},
        onTaskTap: (_) {},
        onTaskToggle: (_) {},
      ),
      size: const Size(900, 680),
    );

    expect(tester.getTopLeft(find.text('Study')).dx, closeTo(140, 1));
    expect(tester.getTopRight(find.text('Mode')).dx, closeTo(760, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large type keeps a long note bounded and the task action usable',
    (tester) async {
      final title = List.filled(16, 'Studio Tokyo العربية résumé').join(' ');
      final date = DateUtils.dateOnly(DateTime.now());
      var reviewed = false;
      var planned = false;
      await _show(
        tester,
        MobileHome(
          date: date,
          mode: null,
          modeControl: const Text('Mode'),
          note: NoteItem(
            id: 'note',
            title: title,
            body: 'Remember the floor plan.',
            updated: date,
            noteToSelf: true,
          ),
          events: const [],
          tasks: const [],
          onNoteTap: () {},
          onCalendarTap: () {},
          onEventTap: (_) {},
          onTaskTap: (_) {},
          onTaskToggle: (_) {},
          onPlanDay: () => planned = true,
          onWhatFitsNow: () => reviewed = true,
        ),
        size: const Size(320, 568),
        textScale: 2,
      );

      final preview = tester.widget<Text>(find.text(title));
      expect(preview.maxLines, 2);
      expect(preview.overflow, TextOverflow.ellipsis);
      expect(find.text('Remember the floor plan.'), findsOneWidget);
      final action = find.widgetWithText(TextButton, 'What fits now');
      await tester.scrollUntilVisible(action, 120);
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      await tester.tap(action);
      expect(reviewed, isTrue);
      expect(find.text('Plan day'), findsNothing);
      expect(planned, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _show(
  WidgetTester tester,
  MobileHome home, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: home),
    ),
  );
}
