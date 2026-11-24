import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'calendar_page.dart';
import 'list_pages.dart';
import 'ui_theme.dart';

export 'ui_theme.dart';

const spaceColors = <String, Color>{
  'work': Color(0xff4e6c9b),
  'personal': Color(0xff8a6235),
  'study': Color(0xff775d96),
  'health': Color(0xff44734f),
};

Color spaceColor(String category) =>
    spaceColors[category.toLowerCase()] ?? accent;

String spaceName(String category) => category.isEmpty
    ? 'General'
    : '${category[0].toUpperCase()}${category.substring(1)}';

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime plusDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

bool sameDay(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;

class WorkspaceData {
  WorkspaceData({
    required this.events,
    required this.tasks,
    required this.notes,
  });

  final List<CalendarEvent> events;
  final List<TaskItem> tasks;
  final List<NoteItem> notes;

  factory WorkspaceData.samples(DateTime today) {
    DateTime at(int hour, [int minute = 0, int days = 0]) =>
        DateTime(today.year, today.month, today.day + days, hour, minute);

    return WorkspaceData(
      events: [
        CalendarEvent(
          id: 'sample-review',
          title: 'Studio review',
          start: at(9, 30),
          end: at(10, 15),
          category: 'work',
          location: 'Studio',
        ),
        CalendarEvent(
          id: 'sample-reading',
          title: 'Reading block',
          start: at(13),
          end: at(14),
          category: 'study',
          location: 'Library',
        ),
        CalendarEvent(
          id: 'sample-training',
          title: 'Strength training',
          start: at(17, 30),
          end: at(18, 15),
          category: 'health',
          location: 'Gym',
        ),
        CalendarEvent(
          id: 'sample-coffee',
          title: 'Coffee with Alex',
          start: at(11, 0, 1),
          end: at(11, 45, 1),
          category: 'personal',
        ),
        CalendarEvent(
          id: 'sample-planning',
          title: 'Project planning',
          start: at(10, 0, 2),
          end: at(11, 0, 2),
          category: 'work',
        ),
        CalendarEvent(
          id: 'sample-class',
          title: 'Evening class',
          start: at(16, 30, 3),
          end: at(18, 0, 3),
          category: 'study',
        ),
      ],
      tasks: [
        TaskItem(
          id: 'sample-venue',
          title: 'Send venue options',
          category: 'work',
          date: plusDays(today, -1),
          done: false,
        ),
        TaskItem(
          id: 'sample-outline',
          title: 'Send the project outline',
          category: 'work',
          date: today,
          done: false,
        ),
        TaskItem(
          id: 'sample-chapters',
          title: 'Review chapter notes',
          category: 'study',
          date: today,
          done: false,
        ),
        TaskItem(
          id: 'sample-pickup',
          title: 'Pick up a prescription',
          category: 'health',
          date: plusDays(today, 1),
          done: false,
        ),
        TaskItem(
          id: 'sample-travel',
          title: 'Check weekend train times',
          category: 'personal',
          date: null,
          done: false,
        ),
        TaskItem(
          id: 'sample-notebook',
          title: 'Order a replacement notebook',
          category: 'personal',
          date: plusDays(today, -1),
          done: true,
        ),
      ],
      notes: [
        NoteItem(
          id: 'sample-studio-note',
          title: 'Studio review notes',
          body: 'Walk through the first draft together.\n\nDecisions to make\n• Confirm the scope for Friday.\n• Choose what to take into the second draft.',
          updated: today,
        ),
        NoteItem(
          id: 'sample-reading-note',
          title: 'Reading list',
          body: 'Start here on the next library visit.\n\n• The Creative Act\n• A Field Guide to Getting Lost\n• The Practice of Everyday Life',
          updated: plusDays(today, -2),
        ),
        NoteItem(
          id: 'sample-weekend-note',
          title: 'A weekend in Glasgow',
          body: 'Take the train before lunch. Meet at the bookshop and come back Sunday evening.',
          updated: plusDays(today, -4),
        ),
        NoteItem(
          id: 'sample-training-note',
          title: 'Training plan',
          body: 'Keep the warm-up short and repeatable. Start the next session with the same weight and focus on control.',
          updated: plusDays(today, -6),
        ),
      ],
    );
  }

  factory WorkspaceData.decode(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return WorkspaceData(
      events: [
        for (final event in data['events'] as List<dynamic>)
          CalendarEvent(
            id: event['id'] as String,
            title: event['title'] as String,
            start: DateTime.parse(event['start'] as String),
            end: DateTime.parse(event['end'] as String),
            category: event['category'] as String,
            allDay: event['allDay'] as bool,
            location: event['location'] as String?,
          ),
      ],
      tasks: [
        for (final task in data['tasks'] as List<dynamic>)
          TaskItem(
            id: task['id'] as String,
            title: task['title'] as String,
            category: task['category'] as String,
            date: task['date'] == null
                ? null
                : DateTime.parse(task['date'] as String),
            done: task['done'] as bool,
          ),
      ],
      notes: [
        for (final note in data['notes'] as List<dynamic>)
          NoteItem(
            id: note['id'] as String,
            title: note['title'] as String,
            body: note['body'] as String,
            updated: DateTime.parse(note['updated'] as String),
          ),
      ],
    );
  }

  String encode() => jsonEncode({
    'events': [
      for (final event in events)
        {
          'id': event.id,
          'title': event.title,
          'start': event.start.toIso8601String(),
          'end': event.end.toIso8601String(),
          'category': event.category,
          'allDay': event.allDay,
          'location': event.location,
        },
    ],
    'tasks': [
      for (final task in tasks)
        {
          'id': task.id,
          'title': task.title,
          'category': task.category,
          'date': task.date?.toIso8601String(),
          'done': task.done,
        },
    ],
    'notes': [
      for (final note in notes)
        {
          'id': note.id,
          'title': note.title,
          'body': note.body,
          'updated': note.updated.toIso8601String(),
        },
    ],
  });
}
