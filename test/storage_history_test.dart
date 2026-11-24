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

void main() {
  late Directory directory;
  late String path;
  final stores = <WorkspaceHistoryStore>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('easy-history-');
    path = directory.uri.resolve('workspace.sqlite3').toFilePath();
    final original = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = original);
  });

  tearDown(() async {
    await Future.wait(stores.map((store) => store.close()));
    stores.clear();
    await directory.delete(recursive: true);
  });

  Future<WorkspaceHistoryStore> open({WorkspaceSnapshot? seed}) async {
    final result = await openWorkspaceStore(
      databasePath: path,
      preferences: SharedPreferencesAsync(),
      readLegacy: () async =>
          seed ?? (throw StateError('Unexpected legacy read')),
    ) as WorkspaceHistoryStore;
    stores.add(result);
    return result;
  }

  test(
    'schema v1 upgrade keeps real tiered points and old operation IDs',
    () async {
      final now = DateTime.now().toUtc();
      final stamps = [
        now.subtract(const Duration(days: 500)),
        ..._tier(now, const Duration(days: 156), const Duration(days: 7)),
        ..._tier(now, const Duration(days: 16), const Duration(days: 1)),
        ..._tier(now, const Duration(days: 3), const Duration(hours: 12)),
        ..._tier(now, const Duration(hours: 4), const Duration(hours: 1)),
        ..._tier(now, const Duration(minutes: 30), const Duration(minutes: 5)),
        for (var index = 0; index < 26; index++)
          now.add(Duration(microseconds: index)),
      ];
      _createSchemaV1(path, stamps);
      final store = await open();
      final points = await store.listHistory();
      expect(points.map((point) => point.revision), [
        37,
        36,
        35,
        34,
        33,
        32,
        11,
        9,
        7,
        5,
        3,
      ]);
      expect(points.last.recordedAt, stamps[2]);
      for (final point in points) {
        final preview = await store.previewHistoryPoint(point.revision);
        expect(preview.sourceRevision, point.revision);
        expect(
          preview.snapshot.workspaceJson,
          _workspace('Legacy ${point.revision}'),
        );
      }
      await expectLater(
        store.previewHistoryPoint(1),
        throwsA(isA<WorkspaceStoreException>()),
      );
      final staleRetry = await store.save(
        WorkspaceMutation.workspace(_workspace('Legacy 1')),
        operationId: 'v1-op',
        expectedRevision: 1,
      );
      expect(staleRetry.revision, 37);
      final latest = await store.save(
        WorkspaceMutation.workspace(_workspace('New schema change')),
      );
      expect(latest.revision, 38);
      final db = sqlite3.open(path);
      try {
        expect(db.select('PRAGMA user_version').single.values.single, 2);
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        db.close();
      }
    },
  );

  test('rapid edits share chunks and preserve named points and pre-restore recovery', () async {
    final original = _workspace('Original café 👋', tasks: 2000);
    final store = await open(seed: _snapshot(original));
    final named = await store.nameHistoryPoint(
      'Before planning',
      expectedRevision: 1,
    );
    expect(named.recordedAt.isUtc, isTrue);
    for (var index = 0; index < 26; index++) {
      await store.save(
        WorkspaceMutation.workspace(_workspace('Edit-$index', tasks: 2000)),
      );
    }
    final points = await store.listHistory();
    expect(points, hasLength(7));
    expect(points.last.name, 'Before planning');
    final db = sqlite3.open(path);
    try {
      final shared =
          db.select('''
        SELECT COUNT(*) AS shared
        FROM document_chunk_refs old
        JOIN document_chunk_refs new ON old.chunk = new.chunk
        WHERE old.document = (SELECT workspace FROM revisions WHERE revision = 1)
          AND new.document = (SELECT workspace FROM revisions WHERE revision = 27)
      ''').single['shared']
              as int;
      expect(shared, greaterThan(2));
      final physical =
          db
                  .select(
                    'SELECT SUM(length(compressed)) AS bytes FROM document_chunks',
                  )
                  .single['bytes']
              as int;
      expect(physical, lessThan(utf8.encode(original).length));
    } finally {
      db.close();
    }

    await expectLater(
      store.nameHistoryPoint('Stale', expectedRevision: 26),
      throwsA(isA<WorkspaceRevisionConflict>()),
    );
    final previous = await store.previewHistoryPoint(1);
    expect(previous.snapshot.workspaceJson, original);
    final restored = await store.restoreBackup(previous, expectedRevision: 27);
    expect(restored.revision, 28);
    expect(restored.snapshot.workspaceJson, original);
    final recovery = (await store.readRecoveryBackup())!;
    await store.removeHistoryPointName(1, expectedRevision: 28);
    for (var index = 0; index < 12; index++) {
      await store.save(
        WorkspaceMutation.workspace(_workspace('Later-$index', tasks: 2000)),
      );
    }
    await store.close();
    final reopened = await open();
    expect((await reopened.read()).revision, 40);
    expect(
      (await reopened.listHistory()).where((point) => point.name != null),
      isEmpty,
    );
    expect(await reopened.readRecoveryBackup(), recovery);
    expect(
      (await reopened.previewBackup(recovery)).snapshot.workspaceJson,
      _workspace('Edit-25', tasks: 2000),
    );
  });

  test(
    'shared WAL readers retain their view while writers prune old points',
    () async {
      final store = await open(
        seed: _snapshot(_workspace('First', tasks: 100)),
      );
      final reader = sqlite3.open(path);
      addTearDown(reader.close);
      reader.execute('BEGIN');
      final old = reader
          .select('SELECT workspace FROM revisions WHERE revision = 1')
          .single['workspace'];
      for (var index = 0; index < 12; index++) {
        await store.save(
          WorkspaceMutation.workspace(_workspace('Change-$index', tasks: 100)),
        );
      }
      expect(
        (await store.listHistory()).any((point) => point.revision == 1),
        isFalse,
      );
      expect(
        reader.select('SELECT 1 FROM documents WHERE digest = ?', [old]),
        isNotEmpty,
      );
      reader.execute('COMMIT');
      expect(
        reader.select('SELECT 1 FROM documents WHERE digest = ?', [old]),
        isEmpty,
      );
      expect(reader.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'an interrupted GC rolls back the new revision, new chunks and write id',
    () async {
      final store = await open(
        seed: _snapshot(_workspace('First', tasks: 120)),
      );
      for (var index = 0; index < 5; index++) {
        await store.save(
          WorkspaceMutation.workspace(_workspace('Change-$index', tasks: 120)),
        );
      }
      final db = sqlite3.open(path);
      addTearDown(db.close);
      final before = db
          .select('SELECT COUNT(*) AS count FROM document_chunks')
          .single['count'];
      db.execute('''
      CREATE TRIGGER reject_prune BEFORE DELETE ON revisions
      BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END;
    ''');
      final mutation = WorkspaceMutation.workspace(
        _workspace('Intended edit', tasks: 120),
      );
      await expectLater(
        store.save(mutation, expectedRevision: 6, operationId: 'retry'),
        throwsA(isA<WorkspaceStoreException>()),
      );
      expect((await store.read()).revision, 6);
      expect(
        db
            .select('SELECT COUNT(*) AS count FROM document_chunks')
            .single['count'],
        before,
      );
      expect(
        db.select("SELECT 1 FROM operation_ids WHERE id = 'retry'"),
        isEmpty,
      );
      db.execute('DROP TRIGGER reject_prune');
      expect(
        (await store.save(
          mutation,
          expectedRevision: 6,
          operationId: 'retry',
        )).revision,
        7,
      );
      expect(
        (await store.save(
          mutation,
          expectedRevision: 6,
          operationId: 'retry',
        )).revision,
        7,
      );
    },
  );

  test('checkpoint corruption is isolated and the named point cap preserves earlier points', () async {
    final store = await open(seed: _snapshot(_workspace('First')));
    await store.nameHistoryPoint('First', expectedRevision: 1);
    for (var index = 2; index <= 16; index++) {
      await store.save(
        WorkspaceMutation.workspace(_workspace('Version-$index')),
      );
      await store.nameHistoryPoint('Point $index', expectedRevision: index);
    }
    await store.save(WorkspaceMutation.workspace(_workspace('Latest')));
    await expectLater(
      store.nameHistoryPoint('Over limit', expectedRevision: 17),
      throwsA(isA<WorkspaceStoreException>()),
    );
    expect(
      (await store.listHistory()).where((point) => point.name != null),
      hasLength(16),
    );
    final db = sqlite3.open(path);
    addTearDown(db.close);
    final row = db.select('''
      SELECT chunks.digest, chunks.compressed
      FROM document_chunk_refs refs JOIN document_chunks chunks ON chunks.digest = refs.chunk
      WHERE refs.document = (SELECT workspace FROM revisions WHERE revision = 1)
    ''').single;
    final altered = Uint8List.fromList(row['compressed'] as Uint8List)
      ..[3] ^= 1;
    db.execute('UPDATE document_chunks SET compressed = ? WHERE digest = ?', [
      altered,
      row['digest'],
    ]);
    await expectLater(
      store.previewHistoryPoint(1),
      throwsA(isA<WorkspaceStoreException>()),
    );
    expect((await store.read()).snapshot.workspaceJson, _workspace('Latest'));
  });

  test('selected restore changes only chosen records and preserves pending later edits', () async {
    final archived = jsonDecode(_workspace('Original')) as Map<String, dynamic>;
    archived['tasks'] = [_task('recovered', 'Previous task')];
    archived['nutrition'] = {
      'version': 1,
      'foods': [],
      'meals': [_meal('meal-1', 'Previous meal')],
    };
    archived['customView'] = {'style': 'original'};
    final store = await open(seed: _snapshot(jsonEncode(archived)));
    final active =
        jsonDecode(_workspace('My new note')) as Map<String, dynamic>;
    active['tasks'] = [_task('current', 'Current task')];
    active['nutrition'] = {
      'version': 1,
      'foods': [],
      'meals': [_meal('meal-1', 'Edited meal'), _meal('meal-2', 'New meal')],
    };
    active['customView'] = {'style': 'keep current'};
    await store.save(WorkspaceMutation.workspace(jsonEncode(active)));

    final firstPage = await store.diffHistoryPoint(1, limit: 2);
    final secondPage = await store.diffHistoryPoint(
      1,
      offset: 2,
      expectedRevision: firstPage.expectedRevision,
    );
    expect(firstPage.totalChanges, 5);
    expect(firstPage.changes, hasLength(2));
    expect(secondPage.changes, hasLength(3));
    expect(
      [
        ...firstPage.changes,
        ...secondPage.changes,
      ].map((change) => change.reversion).toSet(),
      WorkspaceHistoryReversion.values.toSet(),
    );

    final preview = await store.previewHistorySelection(
      sourceRevision: 1,
      expectedRevision: 2,
      records: {
        (kind: WorkspaceHistoryRecordKind.task, id: 'recovered'),
        (kind: WorkspaceHistoryRecordKind.meal, id: 'meal-1'),
      },
    );
    expect(preview.backup.counts.tasks, 2);
    expect(preview.backup.counts.meals, 2);
    expect((await store.read()).revision, 2);
    final updated = jsonDecode(
      preview.backup.snapshot.workspaceJson,
    ) as Map<String, dynamic>;
    expect(updated['customView'], {'style': 'keep current'});
    expect(updated['notes'], active['notes']);
    expect(updated['tasks'], [
      _task('current', 'Current task'),
      _task('recovered', 'Previous task'),
    ]);
    expect(updated['nutrition']['meals'], [
      _meal('meal-1', 'Previous meal'),
      _meal('meal-2', 'New meal'),
    ]);
    await store.save(
      WorkspaceMutation.workspace(
        jsonEncode({
          ...active,
          'customView': {'style': 'edit after preview'},
        }),
      ),
    );
    await expectLater(
      store.restoreBackup(
        preview.backup,
        expectedRevision: preview.expectedRevision,
      ),
      throwsA(isA<WorkspaceRevisionConflict>()),
    );
    expect(await store.readRecoveryBackup(), isNull);
    final fresh = await store.previewHistorySelection(
      sourceRevision: 1,
      expectedRevision: 3,
      records: {(kind: WorkspaceHistoryRecordKind.meal, id: 'meal-1')},
    );
    expect(
      (await store.restoreBackup(fresh.backup, expectedRevision: 3)).revision,
      4,
    );
    expect(await store.readRecoveryBackup(), isNotNull);
  });

  test(
    'selected deletion must include tasks with dependent references',
    () async {
      final store = await open(seed: _snapshot(_workspace('Original')));
      final active = jsonDecode(_workspace('Current')) as Map<String, dynamic>;
      active['tasks'] = [
        _task('parent', 'Parent'),
        {..._task('dependent', 'Dependent'), 'parentId': 'parent'},
      ];
      await store.save(WorkspaceMutation.workspace(jsonEncode(active)));
      const parent = (kind: WorkspaceHistoryRecordKind.task, id: 'parent');
      const dependent = (
        kind: WorkspaceHistoryRecordKind.task,
        id: 'dependent',
      );
      await expectLater(
        store.previewHistorySelection(
          sourceRevision: 1,
          expectedRevision: 2,
          records: {parent},
        ),
        throwsA(isA<WorkspaceStoreException>()),
      );
      final preview = await store.previewHistorySelection(
        sourceRevision: 1,
        expectedRevision: 2,
        records: {parent, dependent},
      );
      expect(preview.backup.counts.tasks, 0);
      expect(preview.changes.map((change) => change.reversion).toSet(), {
        WorkspaceHistoryReversion.removeAdded,
      });
      expect((await store.read()).revision, 2);
    },
  );
}

Map<String, Object?> _task(String id, String title) => {
  'id': id,
  'title': title,
  'category': 'Work',
  'done': false,
};

Map<String, Object?> _meal(String id, String title) => {
  'id': id,
  'name': title,
  'eatenAt': '2026-01-01T12:00:00Z',
  'portions': [],
  'draft': true,
};

WorkspaceSnapshot _snapshot(String workspace) => WorkspaceSnapshot(
  workspaceJson: workspace,
  gymSessionJson: const [],
  workoutPlanJson: const [],
);

String _workspace(String title, {int tasks = 0}) => jsonEncode({
  'events': [],
  'tasks': [
    for (var index = 0; index < tasks; index++)
      {
        'id': 'task-$index',
        'title':
            'Prepare milestone ${index % 19} and share status with the team',
        'category': 'Work',
        'date': null,
        'done': false,
      },
  ],
  'notes': [
    {
      'id': 'one',
      'title': title,
      'body': 'Synthetic record',
      'updated': '2026-01-01T12:00:00Z',
    },
  ],
});

List<DateTime> _tier(DateTime now, Duration age, Duration interval) {
  final milliseconds = now.subtract(age).millisecondsSinceEpoch;
  final aligned = DateTime.fromMillisecondsSinceEpoch(
    milliseconds ~/ interval.inMilliseconds * interval.inMilliseconds,
    isUtc: true,
  );
  return [
    aligned.add(const Duration(seconds: 1)),
    aligned.add(const Duration(seconds: 10)),
  ];
}

void _createSchemaV1(String path, List<DateTime> stamps) {
  final db = sqlite3.open(path);
  String digest(String text) => sha256.convert(utf8.encode(text)).toString();
  try {
    db.execute('''
      CREATE TABLE documents (digest TEXT PRIMARY KEY, body TEXT NOT NULL CHECK(json_valid(body))) STRICT, WITHOUT ROWID;
      CREATE TABLE revisions (
        revision INTEGER PRIMARY KEY CHECK(revision > 0),
        workspace TEXT NOT NULL REFERENCES documents(digest),
        gym_sessions TEXT NOT NULL REFERENCES documents(digest),
        workout_plans TEXT NOT NULL REFERENCES documents(digest),
        kind TEXT NOT NULL, created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE operation_ids (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL) STRICT, WITHOUT ROWID;
      CREATE TABLE recovery (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), backup BLOB NOT NULL) STRICT;
      PRAGMA application_id = 1163090225;
      PRAGMA user_version = 1;
    ''');
    final empty = digest('[]');
    db.execute('INSERT INTO documents VALUES (?, ?)', [empty, '[]']);
    for (var index = 0; index < stamps.length; index++) {
      final revision = index + 1;
      final source = _workspace('Legacy $revision');
      final hash = digest(source);
      db.execute('INSERT INTO documents VALUES (?, ?)', [hash, source]);
      db.execute('INSERT INTO revisions VALUES (?, ?, ?, ?, ?, ?)', [
        revision,
        hash,
        empty,
        empty,
        'edit',
        stamps[index].toIso8601String(),
      ]);
    }
    db.execute('INSERT INTO operation_ids VALUES (?, ?)', [
      'v1-op',
      digest(jsonEncode(['workspace', _workspace('Legacy 1')])),
    ]);
  } finally {
    db.close();
  }
}
