import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'contracts.dart';
import 'snapshot_codec.dart';

Future<WorkspaceStore> openSqliteWorkspaceStore({
  required String path,
  required Future<WorkspaceSnapshot> Function() readLegacy,
}) async {
  final client = _DatabaseClient();
  try {
    await client.start(path);
    if (!(await client.request<bool>(_Request.initialized))) {
      await client.request<WorkspaceRevision>(
        _Request.initialize,
        await readLegacy(),
      );
    }
    return _SqliteWorkspaceStore(client);
  } catch (_) {
    try {
      await client.close();
    } catch (_) {
      // Keep the original error if opening or migrating the database fails.
    }
    rethrow;
  }
}

class _SqliteWorkspaceStore implements WorkspaceStore {
  _SqliteWorkspaceStore(this._client);

  final _DatabaseClient _client;

  @override
  Future<WorkspaceRevision> read() => _client.request(_Request.read);

  @override
  Future<WorkspaceRevision> save(
    WorkspaceMutation mutation, {
    int? expectedRevision,
    String? operationId,
  }) => _client.request(_Request.save, (
    mutation,
    expectedRevision,
    validateOperationId(operationId),
  ));

  @override
  Future<Uint8List> createBackup() => _client.request(_Request.backup);

  @override
  Future<WorkspaceBackupPreview> previewBackup(Uint8List data) =>
      _client.request(_Request.preview, TransferableTypedData.fromList([data]));

  @override
  Future<WorkspaceRevision> restoreBackup(
    WorkspaceBackupPreview preview, {
    required int expectedRevision,
  }) => _client.request(_Request.restore, (preview.snapshot, expectedRevision));

  @override
  Future<Uint8List?> readRecoveryBackup() => _client.request(_Request.recovery);

  @override
  Future<void> close() => _client.close();
}

enum _Request {
  initialized,
  initialize,
  read,
  save,
  backup,
  preview,
  restore,
  recovery,
  close,
}

typedef _SaveArguments = (WorkspaceMutation, int?, String?);
typedef _RestoreArguments = (WorkspaceSnapshot, int);

class _DatabaseClient {
  final _responses = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  SendPort? _commands;
  Future<void>? _closeFuture;
  int _sequence = 0;
  bool _ended = false;

  Future<void> start(String path) async {
    _responses.listen(_receive);
    try {
      final results = await Future.wait<Object>([
        _ready.future,
        Isolate.spawn(
          _startWorker,
          (path, _responses.sendPort),
          onError: _responses.sendPort,
          onExit: _responses.sendPort,
          debugName: 'easy-sqlite',
        ),
      ], eagerError: true);
      _commands = results.first as SendPort;
    } catch (_) {
      _responses.close();
      rethrow;
    }
  }

  Future<T> request<T>(_Request request, [Object? data]) async {
    final port = _commands;
    if (_ended || _closeFuture != null || port == null) {
      throw const WorkspaceStoreException('The workspace is closed.');
    }
    return await _send(request, data) as T;
  }

  Future<Object?> _send(_Request request, Object? data) {
    final id = _sequence++;
    final response = Completer<Object?>();
    _pending[id] = response;
    _commands!.send((id, request, data));
    return response.future;
  }

  void _receive(Object? message) {
    switch (message) {
      case SendPort port:
        _ready.complete(port);
      case (final int id, final bool success, final Object? data):
        final completion = _pending.remove(id);
        if (success) {
          completion?.complete(data);
        } else {
          completion?.completeError(data!);
        }
      case WorkspaceStoreException error:
        _fail(error);
      case null || List<dynamic> _:
        _fail(const WorkspaceStoreException('The workspace database stopped.'));
    }
  }

  void _fail(WorkspaceStoreException error) {
    _ended = true;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _responses.close();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    try {
      if (!_ended && _commands != null) {
        await _send(_Request.close, null);
      }
    } finally {
      _responses.close();
      _ended = true;
    }
  }
}

void _startWorker((String path, SendPort response) configuration) {
  final (path, response) = configuration;
  final _SqliteDatabase store;
  try {
    if (path != ':memory:') File(path).parent.createSync(recursive: true);
    store = _SqliteDatabase.open(path);
  } on WorkspaceStoreException catch (error) {
    response.send(error);
    return;
  } catch (_) {
    response.send(
      const WorkspaceStoreException(
        'The workspace database could not be opened.',
      ),
    );
    return;
  }
  final commands = ReceivePort();
  response.send(commands.sendPort);
  commands.listen((message) {
    final (id, command, data) = message as (int, _Request, Object?);
    try {
      final result = switch (command) {
        _Request.initialized => store.initialized,
        _Request.initialize => store.initialize(data as WorkspaceSnapshot),
        _Request.read => store.read(),
        _Request.save => store.save(data as _SaveArguments),
        _Request.backup => encodeBackup(store.read()),
        _Request.preview => decodeBackup(
          (data as TransferableTypedData).materialize().asUint8List(),
        ),
        _Request.restore => store.restore(data as _RestoreArguments),
        _Request.recovery => store.readRecovery(),
        _Request.close => store.close(),
      };
      response.send((id, true, result));
    } catch (error) {
      final publicError = switch (error) {
        WorkspaceRevisionConflict() || WorkspaceStoreException() => error,
        FormatException() => FormatException(error.message),
        _ => const WorkspaceStoreException(
          'The workspace database could not complete this operation.',
        ),
      };
      response.send((id, false, publicError));
    } finally {
      if (command == _Request.close) commands.close();
    }
  });
}

class _SqliteDatabase {
  _SqliteDatabase(this._database);

  static const _applicationId = 0x45535931;
  static const _schemaVersion = 1;

  final Database _database;

  static _SqliteDatabase open(String path) {
    final database = sqlite3.open(path);
    final store = _SqliteDatabase(database);
    try {
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA trusted_schema = OFF');
      store._ensureSchema();
      final check = database.select('PRAGMA quick_check(1)').single.values;
      if (check.single != 'ok') {
        throw const WorkspaceStoreException(
          'The workspace database is damaged.',
        );
      }
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      final revision = store._readHead();
      if (revision != null) validateSnapshot(revision.snapshot);
      return store;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  void _ensureSchema() => _transaction(() {
    final id = _database.select('PRAGMA application_id').single.values.single;
    final version = _database
        .select('PRAGMA user_version')
        .single
        .values
        .single;
    if (id == _applicationId && version == _schemaVersion) return;
    if (id == _applicationId) {
      throw const WorkspaceStoreException(
        'Unsupported workspace database version.',
      );
    }
    final empty = _database
        .select(
          "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1",
        )
        .isEmpty;
    if (id != 0 || version != 0 || !empty) {
      throw const WorkspaceStoreException('Unrecognized workspace database.');
    }
    _database.execute('''
      CREATE TABLE documents (
        digest TEXT PRIMARY KEY,
        body TEXT NOT NULL CHECK (json_valid(body))
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE revisions (
        revision INTEGER PRIMARY KEY CHECK (revision > 0),
        workspace TEXT NOT NULL REFERENCES documents(digest),
        gym_sessions TEXT NOT NULL REFERENCES documents(digest),
        workout_plans TEXT NOT NULL REFERENCES documents(digest),
        kind TEXT NOT NULL,
        created_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE operation_ids (
        id TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE recovery (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        backup BLOB NOT NULL
      ) STRICT;
      PRAGMA application_id = $_applicationId;
      PRAGMA user_version = $_schemaVersion;
    ''');
  });

  bool get initialized =>
      _database.select('SELECT 1 FROM revisions LIMIT 1').isNotEmpty;

  WorkspaceRevision initialize(WorkspaceSnapshot seed) => _transaction(() {
    final current = _readHead();
    if (current != null) return current;
    validateSnapshot(seed);
    return _append(seed, revision: 1, kind: 'migration');
  });

  WorkspaceRevision read() =>
      _readHead() ??
      (throw const WorkspaceStoreException('The workspace is uninitialized.'));

  WorkspaceRevision? _readHead() {
    final rows = _database.select('''
      SELECT revisions.revision AS revision,
             workspace.body AS workspace, workspace.digest AS workspace_digest,
             sessions.body AS sessions, sessions.digest AS sessions_digest,
             plans.body AS plans, plans.digest AS plans_digest
      FROM revisions
      LEFT JOIN documents workspace ON workspace.digest = revisions.workspace
      LEFT JOIN documents sessions ON sessions.digest = revisions.gym_sessions
      LEFT JOIN documents plans ON plans.digest = revisions.workout_plans
      ORDER BY revisions.revision DESC
      LIMIT 1
    ''');
    if (rows.isEmpty) return null;
    final row = rows.single;
    String checkedBody(String name) {
      final body = row[name];
      if (body is! String || digestText(body) != row['${name}_digest']) {
        throw const WorkspaceStoreException(
          'A workspace document failed its integrity check.',
        );
      }
      return body;
    }

    return WorkspaceRevision(
      revision: positiveRevision(row['revision']),
      snapshot: WorkspaceSnapshot(
        workspaceJson: checkedBody('workspace'),
        gymSessionJson: _decodeList(checkedBody('sessions')),
        workoutPlanJson: _decodeList(checkedBody('plans')),
      ),
    );
  }

  WorkspaceRevision save(_SaveArguments arguments) => _transaction(() {
    final (mutation, expectedRevision, operationId) = arguments;
    final current = read();
    final fingerprint = operationId == null
        ? null
        : mutationFingerprint(mutation);
    if (operationId != null) {
      final prior = _database.select(
        'SELECT fingerprint FROM operation_ids WHERE id = ?',
        [operationId],
      );
      if (prior.isNotEmpty) {
        if (prior.single['fingerprint'] != fingerprint) {
          throw const WorkspaceStoreException(
            'That operation ID already belongs to a different change.',
          );
        }
        return current;
      }
    }
    verifyRevision(expectedRevision, current.revision);
    final updated = mutation.apply(current.snapshot);
    final changed = !snapshotsEqual(current.snapshot, updated);
    final next = changed
        ? _validateAndAppend(updated, current.revision + 1, 'edit')
        : current;
    if (operationId != null) {
      _database.execute(
        'INSERT INTO operation_ids (id, fingerprint) VALUES (?, ?)',
        [operationId, fingerprint],
      );
    }
    return next;
  });

  WorkspaceRevision restore(_RestoreArguments arguments) => _transaction(() {
    final (snapshot, expectedRevision) = arguments;
    final current = read();
    verifyRevision(expectedRevision, current.revision);
    if (snapshotsEqual(current.snapshot, snapshot)) return current;
    final next = _validateAndAppend(snapshot, current.revision + 1, 'restore');
    _database.execute(
      '''
      INSERT INTO recovery (singleton, backup) VALUES (1, ?)
      ON CONFLICT(singleton) DO UPDATE SET backup = excluded.backup
    ''',
      [encodeBackup(current)],
    );
    return next;
  });

  WorkspaceRevision _validateAndAppend(
    WorkspaceSnapshot snapshot,
    int revision,
    String kind,
  ) {
    validateSnapshot(snapshot);
    return _append(snapshot, revision: revision, kind: kind);
  }

  WorkspaceRevision _append(
    WorkspaceSnapshot snapshot, {
    required int revision,
    required String kind,
  }) {
    final documents = [
      snapshot.workspaceJson,
      jsonEncode(snapshot.gymSessionJson),
      jsonEncode(snapshot.workoutPlanJson),
    ];
    final digests = <String>[];
    for (final document in documents) {
      final digest = digestText(document);
      _database.execute(
        'INSERT INTO documents(digest, body) VALUES (?, ?) '
        'ON CONFLICT(digest) DO NOTHING',
        [digest, document],
      );
      digests.add(digest);
    }
    _database.execute(
      '''
      INSERT INTO revisions
        (revision, workspace, gym_sessions, workout_plans, kind, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''',
      [revision, ...digests, kind, DateTime.now().toUtc().toIso8601String()],
    );
    return WorkspaceRevision(revision: revision, snapshot: snapshot);
  }

  Uint8List? readRecovery() {
    final rows = _database.select(
      'SELECT backup FROM recovery WHERE singleton = 1',
    );
    if (rows.isEmpty) return null;
    final backup = rows.single['backup'] as Uint8List;
    decodeBackup(backup);
    return backup;
  }

  T _transaction<T>(T Function() action) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      // SQLite can automatically roll back on full disks and I/O failures.
      if (!_database.autocommit) _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Object? close() {
    _database.close();
    return null;
  }
}

List<String> _decodeList(String source) {
  final array = decodeJson(source, 'record list');
  if (array is! List<dynamic> || array.any((value) => value is! String)) {
    throw const FormatException('Invalid persisted record list.');
  }
  return array.cast<String>();
}
