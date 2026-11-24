import 'package:easy/calendar_page.dart';
import 'package:easy/scheduling/availability_settings.dart';
import 'package:easy/scheduling/plan_day_sheet.dart';
import 'package:easy/scheduling/planner.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime at(int hour, [int minute = 0]) =>
      DateTime.utc(2026, 11, 24, hour, minute);

  test('a fully accepted prerequisite sets the earliest dependent block', () {
    final plan = planWorkspaceDay(
      window: TimeSpan(at(9), at(12)),
      events: [
        CalendarEvent(
          id: 'first',
          title: 'Accepted setup',
          start: at(9, 30),
          end: at(10),
          category: 'work',
          plannedTaskId: 'setup',
        ),
      ],
      tasks: const [
        TaskItem(
          id: 'setup',
          title: 'Set up',
          category: 'work',
          estimatedMinutes: 30,
        ),
        TaskItem(
          id: 'send',
          title: 'Send the handoff',
          category: 'work',
          estimatedMinutes: 30,
          prerequisiteIds: ['setup'],
        ),
      ],
    );
    expect(plan.satisfiedPrerequisites, {'setup'});
    expect(plan.scheduled.single.task.id, 'send');
    expect(plan.scheduled.single.blocks.single.start, at(10));
  });

  test(
    'saved windows, focus and travel constrain the same reviewed planner',
    () {
      final settings = SchedulingSettings(
        timeZoneId: 'Europe/London',
        availability: [
          WeeklyAvailability(
            id: 'work-hours',
            weekdays: const {DateTime.tuesday},
            startMinute: 9 * 60,
            endMinute: 11 * 60,
            categories: const {'work'},
          ),
        ],
        places: [
          SavedPlace(id: 'home', name: 'Home'),
          SavedPlace(id: 'office', name: 'Office'),
        ],
      );
      final early = CalendarEvent(
        id: 'home',
        title: 'Home task',
        start: at(9),
        end: at(9, 15),
        category: 'work',
        savedPlaceId: 'home',
      );
      final late = CalendarEvent(
        id: 'office',
        title: 'Office meeting',
        start: at(10, 30),
        end: at(10, 45),
        category: 'work',
        savedPlaceId: 'office',
      );
      final result = planWorkspaceDay(
        window: TimeSpan(at(9), at(13)),
        events: [early, late],
        tasks: const [
          TaskItem(
            id: 'work',
            title: 'Review',
            category: 'work',
            estimatedMinutes: 15,
          ),
          TaskItem(
            id: 'study',
            title: 'Homework',
            category: 'study',
            estimatedMinutes: 15,
          ),
        ],
        settings: settings,
        categories: {'work'},
      );
      expect(result.scheduled.single.task.id, 'work');
      expect(result.scheduled.single.blocks.single.start, at(10, 45));
      expect(result.advisories, ['Some gaps need a saved travel duration.']);
    },
  );
}
