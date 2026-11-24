import 'package:easy/calendar_page.dart';
import 'package:easy/calendar_sources/calendar_directory.dart';
import 'package:easy/calendar_sources/calendar_settings_page.dart';
import 'package:easy/calendar_sources/ics_workspace.dart';
import 'package:easy/main.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/planner.dart' show TimeSpan;
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:easy/tasks/task_workspace_feed.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _readyTaskTitle = 'Send updated studio hours';

void main() {
  testWidgets('Only an immediately runnable unreserved task gets the label', (
    tester,
  ) async {
    final now = DateTime.now();
    final day = dateOnly(now);
    final reservedStart = now.add(const Duration(hours: 2));
    await _openToday(
      tester,
      day: day,
      tasks: [
        _workTask(
          'a-future',
          'Wait for the office to open',
          day,
          earliestStart: now.add(const Duration(minutes: 15)),
          priority: TaskPriority.high,
        ),
        _workTask(
          'b-short',
          'Submit before the cutoff',
          day,
          dueAt: now.add(const Duration(seconds: 30)),
        ),
        _workTask(
          'c-partial',
          'Work already on the calendar',
          day,
          priority: TaskPriority.high,
        ),
        _workTask('z-ready', _readyTaskTitle, day),
      ],
      events: [
        CalendarEvent(
          id: 'reserved',
          title: 'Work already on the calendar',
          start: reservedStart,
          end: reservedStart.add(const Duration(seconds: 30)),
          category: 'work',
          plannedTaskId: 'c-partial',
        ),
      ],
    );
    expect(find.text(_readyTaskTitle), findsOneWidget);
    if (_canFitMinute(now)) {
      expect(find.text('Fits now'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_readyTaskTitle)).dy,
        lessThan(
          tester.getTopLeft(find.text('Wait for the office to open')).dy,
        ),
      );
    }
  });

  testWidgets('A commitment in another category keeps the current time busy', (
    tester,
  ) async {
    final now = DateTime.now();
    final day = dateOnly(now);
    await _openToday(
      tester,
      day: day,
      tasks: [_workTask('ready', _readyTaskTitle, day)],
      events: [
        CalendarEvent(
          id: 'personal-commitment',
          title: 'Collect prescription',
          start: now.subtract(const Duration(minutes: 5)),
          end: now.add(const Duration(minutes: 10)),
          category: 'personal',
        ),
      ],
    );
    expect(find.text(_readyTaskTitle), findsOneWidget);
    expect(find.text('Fits now'), findsNothing);
  });

  for (final offset in [0, -1]) {
    testWidgets('A placement from day $offset keeps the current time busy', (
      tester,
    ) async {
      final now = DateTime.now();
      final day = dateOnly(now);
      final sourceDay = plusDays(day, offset);
      const placedTitle = 'Record daily studio costs';
      final repeating = RecurringTaskSeries(
        id: 'recurring-studio-costs',
        task: _workTask('studio-costs', placedTitle, sourceDay),
        rule: InternalRecurrenceRule(
          frequency: InternalRecurrenceFrequency.daily,
          count: 1,
        ),
        timeZoneId: 'Etc/UTC',
      );
      final occurrence = repeating
          .occurrences(
            windowStart: sourceDay,
            windowEnd: plusDays(sourceDay, 1),
          )
          .single;
      final placed = repeating.scheduleManually(
        occurrence,
        span: TimeSpan(
          now.subtract(const Duration(minutes: 5)),
          now.add(const Duration(minutes: 10)),
        ),
        allowOutsideSoftDate: true,
      );
      await _openToday(
        tester,
        day: day,
        tasks: [_workTask('ready', _readyTaskTitle, day)],
        sections: {
          'recurringTasks': [placed.toJson()],
        },
      );
      expect(
        find.text(placedTitle),
        offset == 0 ? findsOneWidget : findsNothing,
      );
      expect(find.text(_readyTaskTitle), findsOneWidget);
      expect(find.text('Fits now'), findsNothing);
    });
  }

  test('The recurring rows retain their timing issue through a spring gap', () {
    final start = DateTime(2026, 3, 7);
    final gapDay = DateTime(2026, 3, 8);
    final followingDay = DateTime(2026, 3, 9);
    final series = RecurringTaskSeries(
      id: 'recurring-studio-lockup',
      task: _workTask(
        'studio-lockup',
        'Lock the studio',
        start,
        dueAt: DateTime.utc(2026, 3, 7, 7, 30),
      ),
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.daily,
        count: 3,
      ),
      timeZoneId: 'America/New_York',
    );
    final feed = TaskWorkspaceFeed([
      RecurringTaskSeries.fromJson(series.toJson()),
    ]);
    const tasks = <TaskItem>[];
    final projections = feed.workspaceTasks(tasks, gapDay);
    final occurrences = feed.workspaceOccurrences(tasks, gapDay).toList();
    final gap = occurrences.first;
    final following = occurrences.last;

    expect(gap.scheduledDate.day, gapDay.day);
    expect(gap.constraintIssue, RecurringTaskScheduleIssue.unavailableClock);
    expect(gap.task.dueAt, isNull);
    expect(projections.first.id, gap.id);
    expect(following.scheduledDate.day, followingDay.day);
    expect(following.constraintIssue, isNull);
    expect(following.task.dueAt, DateTime.utc(2026, 3, 9, 6, 30));
  });

  final unknownSources = <String, Map<String, Object?>>{
    'a selected Apple calendar': {
      'calendarPreferences': CalendarSourcePreferences(
        allCalendars: const [
          CalendarIdentity(accountId: 'apple', calendarId: 'appointments'),
        ],
      ).toJson(),
    },
    'a selected calendar missing from the saved imports': {
      'calendarPreferences': CalendarSourcePreferences(
        allCalendars: const [
          CalendarIdentity(
            accountId: workspaceIcsAccountId,
            calendarId: 'import-unavailable',
          ),
        ],
      ).toJson(),
    },
    'unreadable calendar preferences': {
      'calendarPreferences': {'allCalendars': true},
    },
    'an unreadable repeating event': {
      'recurringEvents': [{}],
    },
    'an unreadable repeating task': {
      'recurringTasks': [{}],
    },
  };
  for (final MapEntry(key: source, value: sections) in unknownSources.entries) {
    testWidgets('Today leaves timing unknown with $source', (tester) async {
      final day = dateOnly(DateTime.now());
      await _openToday(
        tester,
        day: day,
        tasks: [_workTask('ready', _readyTaskTitle, day)],
        sections: sections,
      );
      expect(find.text(_readyTaskTitle), findsOneWidget);
      expect(find.text('Fits now'), findsNothing);
    });
  }
}

bool _canFitMinute(DateTime now) =>
    plusDays(dateOnly(now), 1).difference(now) >
    const Duration(minutes: 1, seconds: 4);

TaskItem _workTask(
  String id,
  String title,
  DateTime day, {
  DateTime? earliestStart,
  DateTime? dueAt,
  TaskPriority? priority,
}) => TaskItem(
  id: id,
  title: title,
  date: day,
  category: 'work',
  estimatedMinutes: 1,
  earliestStart: earliestStart,
  dueAt: dueAt,
  priority: priority,
);

Future<void> _openToday(
  WidgetTester tester, {
  required DateTime day,
  required List<TaskItem> tasks,
  List<CalendarEvent> events = const [],
  Map<String, Object?> sections = const {},
}) async {
  final previous = SharedPreferencesAsyncPlatform.instance;
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final data = WorkspaceData(
    tasks: tasks,
    events: events,
    notes: [],
    sections: {
      'schedulingSettings': SchedulingSettings(
        availability: [
          WeeklyAvailability(
            id: 'work-hours',
            weekdays: [day.weekday],
            startMinute: 0,
            endMinute: 1440,
            categories: ['work'],
          ),
        ],
      ).toJson(),
      ...sections,
    },
  );
  await SharedPreferencesAsync().setString('easy.workspace.v1', data.encode());
  await tester.pumpWidget(
    const EasyApp(openStore: openPreferenceWorkspaceStore),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}
