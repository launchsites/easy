import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';

const _emptyGym =
    '{"planned":false,"startedAt":"2026-01-02T10:00:00",'
    '"finishedAt":null,"entries":[]}';
const _plan =
    '{"id":"plan","name":"Tuesday","schedule":{"kind":"once",'
    '"startDate":"2026-01-02"},"exercises":[]}';

String _workspace(String note) => jsonEncode({
  'events': [],
  'tasks': [],
  'notes': [
    {
      'id': 'one',
      'title': 'Notice',
      'body': note,
      'updated': '2026-01-02T12:00:00',
      'futureFlag': {'keep': true},
    },
  ],
});

WorkspaceSnapshot _seed(String note) => WorkspaceSnapshot(
  workspaceJson: _workspace(note),
  gymSessionJson: [_emptyGym],
  workoutPlanJson: [_plan],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late String path;
  late SharedPreferencesAsync preferences;
  final stores = <WorkspaceStore>[];

  setUp(() async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    preferences = SharedPreferencesAsync();
    temporary = await Directory.systemTemp.createTemp('easy-storage-test-');
    path = temporary.uri.resolve('workspace.sqlite3').toFilePath();
  });

  tearDown(() async {
    await Future.wait(stores.map((store) => store.close()));
    stores.clear();
    await temporary.delete(recursive: true);
  });

  Future<WorkspaceStore> open({
    Future<WorkspaceSnapshot> Function()? legacy,
    bool usePreferences = false,
  }) async {
    final store = await openWorkspaceStore(
      databasePath: usePreferences ? null : path,
      preferences: preferences,
      readLegacy: legacy ?? () async => _seed('original'),
      usePreferences: usePreferences,
    );
    stores.add(store);
    return store;
  }

  test(
    'migration preserves all legacy documents and future fields once',
    () async {
      await preferences.setString('easy.workspace.v1', _workspace('👋 café'));
      await preferences.setStringList('easy.gym-sessions.v1', [_emptyGym]);
      await preferences.setStringList('easy.workout-plans.v1', [_plan]);
      var legacyReads = 0;
      Future<WorkspaceSnapshot> fromLegacy() async {
        legacyReads++;
        return WorkspaceSnapshot(
          workspaceJson: (await preferences.getString('easy.workspace.v1'))!,
          gymSessionJson: (await preferences.getStringList(
            'easy.gym-sessions.v1',
          ))!,
          workoutPlanJson: (await preferences.getStringList(
            'easy.workout-plans.v1',
          ))!,
        );
      }

      final first = await open(legacy: fromLegacy);
      final migrated = await first.read();
      expect(migrated.revision, 1);
      expect(migrated.snapshot.workspaceJson, _workspace('👋 café'));
      expect(migrated.snapshot.gymSessionJson, [_emptyGym]);
      expect(migrated.snapshot.workoutPlanJson, [_plan]);
      await first.save(WorkspaceMutation.workspace(_workspace('edited')));
      await first.close();

      final reopened = await open(legacy: fromLegacy);
      expect(legacyReads, 1);
      expect(
        (await reopened.read()).snapshot.workspaceJson,
        _workspace('edited'),
      );
      expect(
        await preferences.getString('easy.workspace.v1'),
        _workspace('👋 café'),
      );
    },
  );

  test(
    'migration failure leaves the store empty for an explicit retry',
    () async {
      await expectLater(
        open(
          legacy: () async => WorkspaceSnapshot(
            workspaceJson: _workspace('keep'),
            gymSessionJson: ['{"invalid":true}'],
            workoutPlanJson: [_plan],
          ),
        ),
        throwsFormatException,
      );
      final store = await open();
      expect((await store.read()).revision, 1);
      expect((await store.read()).snapshot.gymSessionJson, [_emptyGym]);
    },
  );

  test('concurrent connections preserve independent changes', () async {
    final first = await open();
    final second = await open();
    final result = await Future.wait([
      first.save(WorkspaceMutation.workspace(_workspace('changed'))),
      second.save(WorkspaceMutation.gymSessions(const [])),
      first.save(WorkspaceMutation.workoutPlans(const [])),
    ]);
    expect(result.map((revision) => revision.revision).toSet(), {2, 3, 4});
    final current = await second.read();
    expect(current.revision, 4);
    expect(current.snapshot.workspaceJson, _workspace('changed'));
    expect(current.snapshot.gymSessionJson, isEmpty);
    expect(current.snapshot.workoutPlanJson, isEmpty);
  });

  test('separate openers do not overwrite an already migrated store', () async {
    final stores = await Future.wait([
      open(legacy: () async => _seed('first seed')),
      open(legacy: () async => _seed('second seed')),
    ]);
    final revisions = await Future.wait(stores.map((store) => store.read()));
    expect(revisions.map((revision) => revision.revision), [1, 1]);
    expect(
      revisions.first.snapshot.workspaceJson,
      revisions.last.snapshot.workspaceJson,
    );
  });

  test('stale writers fail without changing the saved revision', () async {
    final first = await open();
    final second = await open();
    final prior = (await second.read()).revision;
    await first.save(WorkspaceMutation.workspace(_workspace('winner')));
    await expectLater(
      second.save(
        WorkspaceMutation.workspace(_workspace('stale')),
        expectedRevision: prior,
      ),
      throwsA(
        isA<WorkspaceRevisionConflict>().having(
          (failure) => failure.actual,
          'actual',
          2,
        ),
      ),
    );
    expect((await second.read()).snapshot.workspaceJson, _workspace('winner'));
  });

  test(
    'operation IDs remain idempotent after newer revisions and reopen',
    () async {
      final first = await open();
      final original = WorkspaceMutation.workspace(_workspace('first change'));
      await first.save(
        original,
        operationId: 'retry-token',
        expectedRevision: 1,
      );
      await first.save(WorkspaceMutation.workspace(_workspace('newer')));
      await first.close();
      final reopened = await open();
      final retry = await reopened.save(
        original,
        operationId: 'retry-token',
        expectedRevision: 1,
      );
      expect(retry.revision, 3);
      expect(retry.snapshot.workspaceJson, _workspace('newer'));
      await expectLater(
        reopened.save(
          WorkspaceMutation.workspace(_workspace('bad reuse')),
          operationId: 'retry-token',
        ),
        throwsA(isA<WorkspaceStoreException>()),
      );
      expect((await reopened.read()).revision, 3);
    },
  );

  test('recovery preview rejects damaged and forged-format backups', () async {
    final store = await open();
    final backup = await store.createBackup();
    await expectLater(
      store.previewBackup(Uint8List.sublistView(backup, 0, backup.length - 1)),
      throwsFormatException,
    );
    final envelope = jsonDecode(utf8.decode(backup)) as Map<String, dynamic>;
    envelope['payload'] = (envelope['payload'] as String).replaceFirst(
      'original',
      'forged',
    );
    await expectLater(
      store.previewBackup(_bytes(envelope)),
      throwsFormatException,
    );
    envelope['payload'] = jsonEncode({
      'revision': 1,
      'workspace': '{"events":[],"tasks":[],"notes":null}',
      'gymSessions': [],
      'workoutPlans': [],
    });
    envelope['sha256'] = sha256
        .convert(utf8.encode(envelope['payload'] as String))
        .toString();
    await expectLater(
      store.previewBackup(_bytes(envelope)),
      throwsFormatException,
    );
    await expectLater(
      store.previewBackup(
        Uint8List.fromList([...List.filled(500, 91), ...List.filled(500, 93)]),
      ),
      throwsFormatException,
    );
    expect((await store.read()).revision, 1);
    expect(await store.readRecoveryBackup(), isNull);
  });

  test('backup checks newer metadata and counts saved captures', () async {
    final store = await open();
    final workspace = jsonDecode(_workspace('edited')) as Map<String, dynamic>;
    final capture = <String, Object>{
      'id': 'capture-1',
      'text': 'Schedule follow-up',
      'capturedAt': '2026-01-02T12:00:00',
      'revision': 2,
      'applied': false,
    };
    final task = <String, Object>{
      'id': 'task-1',
      'title': 'Follow-up',
      'category': 'Work',
      'done': false,
      'dueAt': '2026-01-02T12:00:00',
      'estimatedMinutes': 15,
      'prerequisiteIds': ['previous-task'],
    };
    workspace['captures'] = [capture];
    workspace['tasks'] = [task];
    await store.save(WorkspaceMutation.workspace(jsonEncode(workspace)));
    final original = await store.createBackup();
    final preview = await store.previewBackup(original);
    expect(preview.counts.captures, 1);
    expect(preview.counts.tasks, 1);

    final envelope = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    final payload =
        jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    Uint8List reencoded() {
      payload['workspace'] = jsonEncode(workspace);
      final encoded = jsonEncode(payload);
      envelope['payload'] = encoded;
      envelope['sha256'] = sha256.convert(utf8.encode(encoded)).toString();
      return _bytes(envelope);
    }

    task['prerequisiteIds'] = [42];
    await expectLater(store.previewBackup(reencoded()), throwsFormatException);
    task['prerequisiteIds'] = ['previous-task'];
    capture['revision'] = '2';
    await expectLater(store.previewBackup(reencoded()), throwsFormatException);
    expect((await store.read()).revision, 2);
  });

  test(
    'restore checks freshness and atomically makes a recovery point',
    () async {
      final store = await open();
      final snapshot = await store.previewBackup(await store.createBackup());
      expect(snapshot.sourceRevision, 1);
      expect(snapshot.counts.notes, 1);
      expect(snapshot.counts.gymSessions, 1);
      expect(snapshot.counts.workoutPlans, 1);
      await store.save(WorkspaceMutation.workspace(_workspace('later')));
      await expectLater(
        store.restoreBackup(snapshot, expectedRevision: 1),
        throwsA(isA<WorkspaceRevisionConflict>()),
      );
      expect(await store.readRecoveryBackup(), isNull);
      final restored = await store.restoreBackup(snapshot, expectedRevision: 2);
      expect(restored.revision, 3);
      expect(restored.snapshot.workspaceJson, _workspace('original'));
      await store.close();
      final reopened = await open();
      final rollback = await reopened.previewBackup(
        (await reopened.readRecoveryBackup())!,
      );
      expect(rollback.sourceRevision, 2);
      expect(rollback.snapshot.workspaceJson, _workspace('later'));
      expect((await reopened.read()).revision, 3);
    },
  );

  for (final usePreferences in [false, true]) {
    test(
      'restore operation IDs preserve later edits and the recovery point (${usePreferences ? 'preferences' : 'SQLite'})',
      () async {
        final store = await open(usePreferences: usePreferences);
        final backup = await store.previewBackup(await store.createBackup());
        await store.save(
          WorkspaceMutation.workspace(_workspace('before restore')),
        );
        final applied = await store.restoreBackup(
          backup,
          expectedRevision: 2,
          operationId: 'confirmed-projection',
        );
        expect(applied.revision, 3);
        final recovery = await store.readRecoveryBackup();
        expect(recovery, isNotNull);
        await store.save(
          WorkspaceMutation.workspace(_workspace('after restore')),
        );
        final retry = await store.restoreBackup(
          backup,
          expectedRevision: 2,
          operationId: 'confirmed-projection',
        );
        expect(retry.revision, 4);
        expect(retry.snapshot.workspaceJson, _workspace('after restore'));
        expect(await store.readRecoveryBackup(), recovery);
        final different = await store.previewBackup(recovery!);
        await expectLater(
          store.restoreBackup(
            different,
            expectedRevision: 4,
            operationId: 'confirmed-projection',
          ),
          throwsA(isA<WorkspaceStoreException>()),
        );
        expect((await store.read()).revision, 4);
      },
    );
  }

  test('restore rolls back when writing its recovery point fails', () async {
    final store = await open();
    final backup = await store.previewBackup(await store.createBackup());
    await store.save(WorkspaceMutation.workspace(_workspace('later')));
    final connection = sqlite3.open(path);
    try {
      connection.execute('''
        CREATE TRIGGER test_recovery_failure BEFORE INSERT ON recovery
        BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END
      ''');
    } finally {
      connection.close();
    }
    await expectLater(
      store.restoreBackup(backup, expectedRevision: 2),
      throwsA(isA<WorkspaceStoreException>()),
    );
    expect((await store.read()).revision, 2);
    expect((await store.read()).snapshot.workspaceJson, _workspace('later'));
    expect(await store.readRecoveryBackup(), isNull);
  });

  test(
    'unknown databases and corrupted workspace data are not overwritten',
    () async {
      var connection = sqlite3.open(path);
      connection.execute('CREATE TABLE other (value TEXT)');
      connection.execute("INSERT INTO other VALUES ('keep')");
      connection.close();
      await expectLater(open(), throwsA(isA<WorkspaceStoreException>()));
      connection = sqlite3.open(path);
      expect(
        connection.select('SELECT value FROM other').single['value'],
        'keep',
      );
      connection.close();

      await File(path).delete();
      final store = await open();
      await store.close();
      connection = sqlite3.open(path);
      connection.execute(
        'UPDATE documents SET body = ? '
        'WHERE digest = (SELECT workspace FROM revisions WHERE revision = 1)',
        [_workspace('corruption')],
      );
      connection.close();
      await expectLater(open(), throwsA(isA<WorkspaceStoreException>()));
    },
  );

  test(
    'preferences fallback migrates once and supports preview and restore',
    () async {
      final first = await open(usePreferences: true);
      final preview = await first.previewBackup(await first.createBackup());
      await first.save(
        WorkspaceMutation.workspace(_workspace('browser change')),
        operationId: 'browser-edit',
      );
      await first.close();
      final reopened = await open(
        usePreferences: true,
        legacy: () async => throw StateError('Migration already ran.'),
      );
      final revision = await reopened.restoreBackup(
        preview,
        expectedRevision: 2,
      );
      expect(revision.revision, 3);
      expect(revision.snapshot.workspaceJson, _workspace('original'));
      final rollback = await reopened.previewBackup(
        (await reopened.readRecoveryBackup())!,
      );
      expect(rollback.snapshot.workspaceJson, _workspace('browser change'));
    },
  );
}

Uint8List _bytes(Map<String, dynamic> object) =>
    Uint8List.fromList(utf8.encode(jsonEncode(object)));
