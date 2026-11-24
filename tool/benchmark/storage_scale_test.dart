import 'dart:convert';
import 'dart:io';

import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const taskCount = 100000;
const eventCount = 30000;
const sessionCount = 50000;
const noteCount = 3000;
const mealMetadataCount = 10000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SQLite migration and backup scale on a large synthetic workspace',
    () async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      final temporary = await Directory.systemTemp.createTemp(
        'easy-storage-scale-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final path = temporary.uri.resolve('workspace.sqlite3').toFilePath();
      final fixture = _fixture();

      final stage = Stopwatch()..start();
      final store = await openWorkspaceStore(
        databasePath: path,
        preferences: SharedPreferencesAsync(),
        readLegacy: () async => fixture,
      );
      addTearDown(store.close);
      final migrationMs = stage.elapsedMilliseconds;

      stage.reset();
      final backup = await store.createBackup();
      final exportMs = stage.elapsedMilliseconds;

      stage.reset();
      final preview = await store.previewBackup(backup);
      final previewMs = stage.elapsedMilliseconds;
      expect(preview.counts.tasks, taskCount);
      expect(preview.counts.events, eventCount);
      expect(preview.counts.gymSessions, sessionCount);
      expect(preview.counts.notes, noteCount);
      expect(preview.snapshot.workspaceJson, fixture.workspaceJson);

      stage.reset();
      await store.close();
      final reopened = await openWorkspaceStore(
        databasePath: path,
        preferences: SharedPreferencesAsync(),
        readLegacy: () async =>
            throw StateError('Migration should be complete.'),
      );
      final reopenMs = stage.elapsedMilliseconds;
      await reopened.close();

      stdout.writeln(
        jsonEncode({
          'tasks': taskCount,
          'events': eventCount,
          'gymSessions': sessionCount,
          'notes': noteCount,
          'mealMetadataRecords': mealMetadataCount,
          'attachmentPayloads': 0,
          'migrationMs': migrationMs,
          'exportMs': exportMs,
          'previewMs': previewMs,
          'closeAndReopenMs': reopenMs,
          'databaseBytes': await File(path).length(),
          'backupBytes': backup.length,
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

WorkspaceSnapshot _fixture() {
  final origin = DateTime.utc(2016, 11, 24);
  String hour(int index) =>
      origin.add(Duration(hours: index)).toIso8601String();
  String day(int index) => origin.add(Duration(days: index)).toIso8601String();
  String minute(int index) =>
      origin.add(Duration(minutes: index)).toIso8601String();

  final workspace = jsonEncode({
    'events': List.generate(
      eventCount,
      (index) => {
        'id': 'event-$index',
        'title': 'Synthetic calendar event $index',
        'category': 'study',
        'start': hour(index),
        'end': hour(index + 1),
        'allDay': false,
      },
    ),
    'tasks': List.generate(
      taskCount,
      (index) => {
        'id': 'task-$index',
        'title': 'Synthetic workspace task $index',
        'category': 'work',
        'date': hour(index),
        'done': index.isEven,
        'notes':
            'A bounded synthetic task description for storage stress checks.',
      },
    ),
    'notes': List.generate(
      noteCount,
      (index) => {
        'id': 'note-$index',
        'title': 'Synthetic note $index',
        'body': List.filled(
          24,
          'A synthetic paragraph about workspace behaviour.',
        ).join('\n\n'),
        'updated': day(index),
      },
    ),
    'meals': List.generate(
      mealMetadataCount,
      (index) => {
        'id': 'meal-$index',
        'name': 'Synthetic meal',
        'source': 'manual',
        'recordedAt': hour(index),
      },
    ),
  });
  final sessions = List.generate(
    sessionCount,
    (index) => jsonEncode({
      'planned': index.isEven,
      'startedAt': minute(index),
      'finishedAt': minute(index + 1),
      'entries': [
        {
          'id': 'entry',
          'title': 'Synthetic session entry',
          'actual': '50 kg × 8',
          'loggedAt': minute(index),
        },
      ],
    }),
  );
  return WorkspaceSnapshot(
    workspaceJson: workspace,
    gymSessionJson: sessions,
    workoutPlanJson: const [],
  );
}
