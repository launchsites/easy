import 'dart:convert';
import 'dart:io';

import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SQLite editing churn keeps history and storage bounded', () async {
    final editCount = int.parse(
      Platform.environment['EASY_STORAGE_EDITS'] ?? '10000',
    );
    expect(editCount, greaterThan(0));
    final temporary = await Directory.systemTemp.createTemp(
      'easy-storage-churn-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final path = temporary.uri.resolve('workspace.sqlite3').toFilePath();
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    const taskCount = 2400;
    const eventCount = 1200;
    const noteCount = 500;
    const sessionCount = 400;
    final content = _fixture(taskCount, eventCount, noteCount);
    final base = jsonEncode(content);
    final sessions = [
      for (var index = 0; index < sessionCount; index++)
        jsonEncode({
          'startedAt': DateTime.utc(
            2025,
            1,
            1,
          ).add(Duration(days: index)).toIso8601String(),
          'planned': index.isEven,
          'entries': [],
        }),
    ];
    Future<WorkspaceHistoryStore> connect({required bool initialize}) async =>
        await openWorkspaceStore(
          databasePath: path,
          preferences: SharedPreferencesAsync(),
          readLegacy: () async {
            if (!initialize) throw StateError('Unexpected repeated migration');
            return WorkspaceSnapshot(
              workspaceJson: base,
              gymSessionJson: sessions,
              workoutPlanJson: const [],
            );
          },
        ) as WorkspaceHistoryStore;

    var journal = await connect(initialize: true);
    addTearDown(() => journal.close());
    await journal.nameHistoryPoint('Benchmark start', expectedRevision: 1);
    final tasks = content['tasks']!;
    final samples = <int>[];
    final timer = Stopwatch();
    final wall = Stopwatch()..start();
    var maximumDatabaseBytes = 0;
    var maximumWalBytes = 0;
    WorkspaceMutation? firstRetry;
    var last = base;
    for (var index = 0; index < editCount; index++) {
      final task = tasks[index * 541 % tasks.length];
      task['done'] = !(task['done']! as bool);
      last = jsonEncode(content);
      final mutation = WorkspaceMutation.workspace(last);
      final operationId = index % 50 == 0 ? 'benchmark-$index' : null;
      if (index == 0) firstRetry = mutation;
      timer
        ..reset()
        ..start();
      final result = await journal.save(
        mutation,
        expectedRevision: index + 1,
        operationId: operationId,
      );
      timer.stop();
      samples.add(timer.elapsedMicroseconds);
      if (result.revision != index + 2) {
        throw StateError('An edit did not advance the workspace');
      }
      if (index % 250 == 0) {
        final bytes = await File(path).length();
        final wal = File('$path-wal');
        final walBytes = await wal.exists() ? await wal.length() : 0;
        if (bytes > maximumDatabaseBytes) maximumDatabaseBytes = bytes;
        if (walBytes > maximumWalBytes) maximumWalBytes = walBytes;
      }
      if ((index + 1) % 2500 == 0) {
        await journal.close();
        journal = await connect(initialize: false);
        expect((await journal.read()).snapshot.workspaceJson, last);
        stdout.writeln('Committed and reopened ${index + 1} edits');
      }
    }
    wall.stop();
    expect((await journal.read()).snapshot.workspaceJson, last);
    final history = await journal.listHistory();
    expect(history, hasLength(greaterThanOrEqualTo(2)));
    expect(history.length, lessThanOrEqualTo(145));
    expect(history.last.name, 'Benchmark start');
    expect((await journal.previewHistoryPoint(1)).snapshot.workspaceJson, base);
    final duplicate = await journal.save(
      firstRetry!,
      expectedRevision: 1,
      operationId: 'benchmark-0',
    );
    expect(duplicate.revision, editCount + 1);
    expect(duplicate.snapshot.workspaceJson, last);

    await journal.close();
    final finalBytes = await File(path).length();
    final db = sqlite3.open(path);
    try {
      expect(db.select('PRAGMA quick_check(1)').single.values.single, 'ok');
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      db.close();
    }
    samples.sort();
    double percentile(double fraction) =>
        samples[((samples.length - 1) * fraction).round()] / 1000;
    stdout.writeln(
      jsonEncode({
        'edits': editCount,
        'tasks': taskCount,
        'events': eventCount,
        'notes': noteCount,
        'gymSessions': sessionCount,
        'workspaceBytes': utf8.encode(base).length,
        'editMillisecondsP50': percentile(.5),
        'editMillisecondsP95': percentile(.95),
        'editMillisecondsP99': percentile(.99),
        'totalElapsedMilliseconds': wall.elapsedMilliseconds,
        'historyPoints': history.length,
        'databaseBytes': finalBytes,
        'maximumSampledDatabaseBytes': maximumDatabaseBytes,
        'maximumSampledWalBytes': maximumWalBytes,
      }),
    );
    expect(finalBytes, lessThan(16 * 1024 * 1024));
    expect(maximumWalBytes, lessThanOrEqualTo(8 * 1024 * 1024));
  }, timeout: const Timeout(Duration(minutes: 40)));
}

Map<String, List<Map<String, Object?>>> _fixture(
  int tasks,
  int events,
  int notes,
) => {
  'tasks': [
    for (var index = 0; index < tasks; index++)
      {
        'id': 'task-$index',
        'title': 'Prepare ${index % 29} for synthetic project ${index % 13}',
        'category': 'work',
        'done': index.isEven,
        'notes': 'Confirm details and send the checklist to the project group.',
      },
  ],
  'events': [
    for (var index = 0; index < events; index++)
      {
        'id': 'event-$index',
        'title': 'Synthetic appointment ${index % 51}',
        'category': 'personal',
        'allDay': false,
        'start': DateTime.utc(
          2025,
          1,
          1,
          10,
        ).add(Duration(hours: index)).toIso8601String(),
        'end': DateTime.utc(
          2025,
          1,
          1,
          11,
        ).add(Duration(hours: index)).toIso8601String(),
      },
  ],
  'notes': [
    for (var index = 0; index < notes; index++)
      {
        'id': 'note-$index',
        'title': 'Meeting notes week $index',
        'body':
            'Action items and a list of decisions from the synthetic meeting. ' *
            5,
        'updated': DateTime.utc(
          2025,
          1,
          1,
        ).add(Duration(days: index)).toIso8601String(),
      },
  ],
};
