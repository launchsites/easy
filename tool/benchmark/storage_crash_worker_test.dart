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
  final environment = Platform.environment;
  final directory = environment['EASY_CRASH_FIXTURE'];
  final phase = environment['EASY_CRASH_PHASE'];
  test(
    'process death inside a SQLite write preserves the last acknowledged workspace',
    () async {
      final path = '$directory/workspace.sqlite3';
      final priorPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = priorPrefs);
      final store = await openWorkspaceStore(
        databasePath: path,
        preferences: SharedPreferencesAsync(),
        readLegacy: () async {
          if (phase != 'write')
            throw StateError('The crash fixture lost its migration.');
          return WorkspaceSnapshot(
            workspaceJson: _workspace('Initial'),
            gymSessionJson: const [],
            workoutPlanJson: const [],
          );
        },
      ) as WorkspaceHistoryStore;
      addTearDown(store.close);
      final candidate = _workspace(
        'In-flight edit',
        padding: 'version text ♩ ' * 800000,
      );
      final mutation = WorkspaceMutation.workspace(candidate);
      if (phase == 'write') {
        await store.nameHistoryPoint(
          'Before interruption',
          expectedRevision: 1,
        );
        final saved = await store.save(
          WorkspaceMutation.workspace(_workspace('Acknowledged edit')),
          expectedRevision: 1,
          operationId: 'acknowledged',
        );
        expect(saved.revision, 2);
        await File('$directory/writer.pid')
            .writeAsString('$pid\n', flush: true);
        await store.save(
          mutation,
          expectedRevision: 2,
          operationId: 'in-flight',
        );
        await File('$directory/committed').writeAsString('3\n', flush: true);
        throw StateError(
          'The process did not stop while the write lock was held.',
        );
      }
      expect(phase, 'verify');
      expect(File('$directory/committed').existsSync(), isFalse);
      final current = await store.read();
      expect(current.revision, 2);
      expect(current.snapshot.workspaceJson, _workspace('Acknowledged edit'));
      final retry = await store.save(
        mutation,
        expectedRevision: 2,
        operationId: 'in-flight',
      );
      expect(retry.revision, 3);
      expect(retry.snapshot.workspaceJson, candidate);
      expect(
        (await store.save(
          mutation,
          expectedRevision: 2,
          operationId: 'in-flight',
        )).revision,
        3,
      );
      expect(
        (await store.previewHistoryPoint(1)).snapshot.workspaceJson,
        _workspace('Initial'),
      );
      final db = sqlite3.open(path);
      try {
        expect(db.select('PRAGMA quick_check(1)').single.values.single, 'ok');
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        db.close();
      }
    },
    skip: directory == null || phase == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _workspace(String title, {String padding = ''}) => jsonEncode({
  'events': [],
  'tasks': [],
  'notes': [
    {
      'id': 'synthetic-note',
      'title': title,
      'body': padding,
      'updated': '2026-11-24T01:00:00Z',
    },
  ],
});
