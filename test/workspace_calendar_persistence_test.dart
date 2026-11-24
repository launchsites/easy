import 'dart:convert';

import 'package:easy/calendar_page.dart';
import 'package:easy/sync/src/workspace_sync_record.dart';
import 'package:easy/sync/workspace_sync.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timed events keep both instants in a repeated local hour', () {
    final first = DateTime.utc(2026, 11, 1, 5, 30);
    final repeated = DateTime.utc(2026, 11, 1, 6, 30);
    final workspace = WorkspaceData(
      events: [
        CalendarEvent(
          id: 'clock-fall-back',
          title: 'Clock change',
          start: first.toLocal(),
          end: repeated.toLocal(),
          category: 'work',
        ),
      ],
      tasks: const [],
      notes: const [],
    );
    final encoded = workspace.encode();
    final row = _eventMap(encoded);
    expect(row['start'], '2026-11-01T05:30:00.000Z');
    expect(row['end'], '2026-11-01T06:30:00.000Z');
    final restored = WorkspaceData.decode(encoded).events.single;
    expect(restored.start.isUtc, isFalse);
    expect(restored.end.isUtc, isFalse);
    expect(restored.start.toUtc(), first);
    expect(restored.end.toUtc(), repeated);
    expect(restored.end.difference(restored.start), const Duration(hours: 1));
    if (first.toLocal().timeZoneOffset != repeated.toLocal().timeZoneOffset) {
      expect(restored.start.hour, restored.end.hour);
      expect(restored.start.minute, restored.end.minute);
    }
    expect(WorkspaceData.decode(encoded).encode(), encoded);
  });

  test('legacy offsetless timed records still read as local clock times', () {
    final old = _workspaceWith({
      'start': '2026-11-02T15:15:00.000',
      'end': '2026-11-02T16:30:00.000',
      'allDay': false,
    });
    final restored = WorkspaceData.decode(old);
    final event = restored.events.single;
    expect(event.start, DateTime(2026, 11, 2, 15, 15));
    expect(event.end, DateTime(2026, 11, 2, 16, 30));
    final durable = WorkspaceData.decode(restored.encode()).events.single;
    expect(durable.start, event.start);
    expect(durable.end, event.end);
  });

  test('all-day events keep their start and exclusive end civil dates', () {
    final saved = _workspaceWith({
      'start': '2026-10-31T00:00:00.000',
      'end': '2026-11-03T00:00:00.000',
      'allDay': true,
    });
    final restored = WorkspaceData.decode(saved);
    final event = restored.events.single;
    expect(event.start, DateTime(2026, 10, 31));
    expect(event.end, DateTime(2026, 11, 3));
    final row = _eventMap(restored.encode());
    expect(row['start'], '2026-10-31T00:00:00.000');
    expect(row['end'], '2026-11-03T00:00:00.000');
  });

  test(
    'typed calendar projection preserves a record with explicit offsets',
    () {
      final source = _workspaceWith({
        'start': '2026-11-01T01:30:00-04:00',
        'end': '2026-11-01T01:30:00-05:00',
        'allDay': false,
      });
      final record = WorkspaceSyncRecord.fromSaved(
        SyncRecordKind.calendarEvent,
        _eventMap(source),
      );
      expect(record.toSaved()['start'], '2026-11-01T05:30:00.000Z');
      expect(record.toSaved()['end'], '2026-11-01T06:30:00.000Z');
      final decoded = WorkspaceData.decode(
        _workspaceWith(record.toSaved().cast<String, Object>()),
      ).events.single;
      expect(decoded.start.toUtc(), DateTime.utc(2026, 11, 1, 5, 30));
      expect(decoded.end.toUtc(), DateTime.utc(2026, 11, 1, 6, 30));
    },
  );
}

Map<String, dynamic> _eventMap(String workspace) {
  final document = jsonDecode(workspace) as Map<String, dynamic>;
  return (document['events'] as List).single as Map<String, dynamic>;
}

String _workspaceWith(Map<String, Object> event) => jsonEncode({
  'events': [
    {
      'id': 'test-calendar-event',
      'title': 'Calendar event',
      'category': 'work',
      ...event,
    },
  ],
  'tasks': [],
  'notes': [],
});
