import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy/storage/attachment_store.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';

const _capacityBytes = 96 * 1024;
const _operation = 'retry-after-capacity';
const _acknowledged = 'acknowledged-before-fault';
final _existingWave = _wave(2048);
final _newWave = _wave(256 * 1024);
final _existingAttachment = _reference(_existingWave);
final _newAttachment = _reference(_newWave);
final _head = _document(acknowledged: true);
final _replacement = _document(acknowledged: true, recovered: true);
final _digestName = RegExp(r'^[a-f0-9]{64}$');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final directory = Platform.environment['EASY_STORAGE_CAPACITY_FIXTURE'];
  final phase = Platform.environment['EASY_STORAGE_CAPACITY_PHASE'];
  test(
    'native storage returns an acknowledgement only after a durable save',
    () async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

      final fixture = _Fixture(Directory(directory!));
      final result = switch (phase) {
        'seed' => await fixture.seed(),
        'limited' => await fixture.rejectCapacity(),
        'read-only' => await fixture.rejectPermissions(),
        'retry' => await fixture.retry(),
        'reopen' => await fixture.verifyReopened(),
        _ => throw ArgumentError.value(phase, 'phase'),
      };
      await File.fromUri(fixture.root.uri.resolve('$phase.json'))
          .writeAsString(jsonEncode({'phase': phase, ...result}), flush: true);
    },
    skip: directory == null || phase == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _Fixture {
  _Fixture(this.root);

  final Directory root;

  File get database =>
      File.fromUri(root.uri.resolve('sqlite/workspace.sqlite3'));
  Directory get attachments =>
      Directory.fromUri(root.uri.resolve('attachments'));

  Future<WorkspaceHistoryStore> _open({bool initialize = false}) async =>
      await openWorkspaceStore(
        databasePath: database.path,
        preferences: SharedPreferencesAsync(),
        readLegacy: () async {
          if (!initialize) throw StateError('Unexpected repeated migration.');
          return WorkspaceSnapshot(
            workspaceJson: _document(),
            gymSessionJson: const [],
            workoutPlanJson: const [],
          );
        },
      ) as WorkspaceHistoryStore;

  Future<AttachmentStore> _media() async =>
      (await openAttachmentStore(directoryPath: attachments.path))!;

  Future<Map<String, Object?>> seed() async {
    final media = await _media();
    final workspace = await _open(initialize: true);
    try {
      final savedMedia = await media.putBytes(
        _existingWave,
        kind: AttachmentKind.audio,
      );
      expect(savedMedia.toJson(), _existingAttachment.toJson());
      await workspace.nameHistoryPoint(
        'Before acknowledged work',
        expectedRevision: 1,
      );
      final saved = await workspace.save(
        WorkspaceMutation.workspace(_head),
        expectedRevision: 1,
        operationId: _acknowledged,
      );
      _expectRevision(saved, 2, _head);
      await _expectFiles(media, recovered: false);
    } finally {
      await workspace.close();
      await media.close();
    }
    return _inspect(recovered: false);
  }

  Future<Map<String, Object?>> rejectCapacity() async {
    final workspace = await _open();
    final media = await _media();
    try {
      await _withFileCeiling(_capacityBytes, () async {
        final probe = File.fromUri(root.uri.resolve('ceiling-probe'));
        try {
          expect(await _failedWrite(probe, _capacityBytes + 1), 27); // EFBIG
          expect(await probe.length(), _capacityBytes);
        } finally {
          if (await probe.exists()) await probe.delete();
        }

        // A returned result here would acknowledge a write that the kernel
        // rejected. Both native stores must surface a typed failed future.
        await expectLater(
          workspace.save(
            WorkspaceMutation.workspace(_replacement),
            expectedRevision: 2,
            operationId: _operation,
          ),
          throwsA(isA<WorkspaceStoreException>()),
        );
        await expectLater(
          _publishNewMedia(media),
          throwsA(isA<AttachmentStoreException>()),
        );
        _expectRevision(await workspace.read(), 2, _head);
        await _expectFiles(media, recovered: false);
      });
    } finally {
      await workspace.close();
      await media.close();
    }
    return {
      'fileLimitBytes': _capacityBytes,
      'kernelProbeErrno': 27,
      ..._inspect(recovered: false),
    };
  }

  Future<Map<String, Object?>> rejectPermissions() async {
    final localProbe = File.fromUri(
      database.parent.uri.resolve('permission-probe'),
    );
    expect(await _failedWrite(localProbe, 1), 13); // EACCES
    final mediaProbe = File.fromUri(
      attachments.uri.resolve('permission-probe'),
    );
    expect(await _failedWrite(mediaProbe, 1), 13);

    WorkspaceHistoryStore? workspace;
    try {
      workspace = await _open();
    } on WorkspaceStoreException {
      // A WAL opener may refuse this path before the first application write.
    }
    final media = await _media();
    try {
      if (workspace != null) {
        _expectRevision(await workspace.read(), 2, _head);
        await expectLater(
          workspace.save(
            WorkspaceMutation.workspace(_replacement),
            expectedRevision: 2,
            operationId: _operation,
          ),
          throwsA(isA<WorkspaceStoreException>()),
        );
      }
      await expectLater(
        _publishNewMedia(media),
        throwsA(isA<AttachmentStoreException>()),
      );
      await _expectFiles(media, recovered: false);
    } finally {
      await workspace?.close();
      await media.close();
    }
    return {
      'kernelProbeErrno': 13,
      'workspaceRejectedAt': workspace == null ? 'open' : 'save',
      ..._inspect(recovered: false),
    };
  }

  Future<Map<String, Object?>> retry() async {
    final workspace = await _open();
    final media = await _media();
    try {
      _expectRevision(await workspace.read(), 2, _head);
      await _expectFiles(media, recovered: false);
      final first = await _publishNewMedia(media);
      final replay = await _publishNewMedia(media);
      expect(first.toJson(), _newAttachment.toJson());
      expect(replay.toJson(), first.toJson());

      final mutation = WorkspaceMutation.workspace(_replacement);
      final saved = await workspace.save(
        mutation,
        expectedRevision: 2,
        operationId: _operation,
      );
      final duplicate = await workspace.save(
        mutation,
        expectedRevision: 2,
        operationId: _operation,
      );
      _expectRevision(saved, 3, _replacement);
      _expectRevision(duplicate, 3, _replacement);
      expect(
        (await workspace.previewHistoryPoint(1)).snapshot.workspaceJson,
        _document(),
      );
      _expectRevision(await workspace.read(), 3, _replacement);
      await _expectFiles(media, recovered: true);
    } finally {
      await workspace.close();
      await media.close();
    }
    return {'replayedRevision': 3, ..._inspect(recovered: true)};
  }

  Future<Map<String, Object?>> verifyReopened() async {
    final workspace = await _open();
    final media = await _media();
    try {
      _expectRevision(await workspace.read(), 3, _replacement);
      expect(
        (await workspace.previewHistoryPoint(2)).snapshot.workspaceJson,
        _head,
      );
      await _expectFiles(media, recovered: true);
    } finally {
      await workspace.close();
      await media.close();
    }
    return _inspect(recovered: true);
  }

  Map<String, Object?> _inspect({required bool recovered}) {
    final wal = File('${database.path}-wal');
    expect(!wal.existsSync() || wal.lengthSync() == 0, isTrue);
    // This snapshot has no active connection or uncheckpointed WAL content.
    // Read it without creating new lock sidecars for the permission test.
    final path = database.uri.replace(query: 'immutable=1').toString();
    final connection = sqlite3.open(path, mode: OpenMode.readOnly, uri: true);
    try {
      final quickCheck = connection
          .select('PRAGMA quick_check(1)')
          .single
          .values
          .single;
      expect(quickCheck, 'ok');
      expect(connection.select('PRAGMA foreign_key_check'), isEmpty);
      final operations = connection.select(
        'SELECT id FROM operation_ids ORDER BY id',
      );
      expect(operations.map((row) => row['id']), [
        _acknowledged,
        if (recovered) _operation,
      ]);
      final row = connection
          .select(
            'SELECT revision, workspace FROM revisions ORDER BY revision DESC LIMIT 1',
          )
          .single;
      final digest = sha256
          .convert(utf8.encode(recovered ? _replacement : _head))
          .toString();
      expect(row['revision'], recovered ? 3 : 2);
      expect(row['workspace'], digest);
      final integrity = connection
          .select('PRAGMA integrity_check')
          .single
          .values
          .single;
      expect(integrity, 'ok');
      return {
        'revision': row['revision'],
        'workspaceDigest': digest,
        'integrity': integrity,
        'quickCheck': quickCheck,
        'attachmentDigests': [
          _existingAttachment.id,
          if (recovered) _newAttachment.id,
        ],
      };
    } finally {
      connection.close();
    }
  }

  Future<void> _expectFiles(
    AttachmentStore media, {
    required bool recovered,
  }) async {
    expect((await media.read(_existingAttachment.id)).bytes, _existingWave);
    if (recovered) {
      expect((await media.read(_newAttachment.id)).bytes, _newWave);
    } else {
      await expectLater(
        media.read(_newAttachment.id),
        throwsA(isA<AttachmentStoreException>()),
      );
    }
    final entries = await attachments.list(followLinks: false).toList();
    final ids = [
      for (final item in entries)
        item.uri.pathSegments.where((part) => part.isNotEmpty).last,
    ];
    expect(
      ids.every(_digestName.hasMatch),
      isTrue,
      reason: 'Temporary media staging was not cleaned up.',
    );
    expect(
      ids,
      unorderedEquals([
        _existingAttachment.id,
        if (recovered) _newAttachment.id,
      ]),
    );
  }
}

void _expectRevision(
  WorkspaceRevision snapshot,
  int revision,
  String workspace,
) {
  expect(snapshot.revision, revision);
  expect(snapshot.snapshot.workspaceJson, workspace);
  expect(snapshot.snapshot.gymSessionJson, isEmpty);
  expect(snapshot.snapshot.workoutPlanJson, isEmpty);
}

Future<AttachmentRef> _publishNewMedia(AttachmentStore media) =>
    media.putStream(
      Stream.fromIterable([
        for (var index = 0; index < _newWave.length; index += 32 * 1024)
          Uint8List.sublistView(
            _newWave,
            index,
            min(index + 32 * 1024, _newWave.length),
          ),
      ]),
      kind: AttachmentKind.audio,
      expectedLength: _newWave.length,
      expectedContentId: _newAttachment.id,
    );

Future<int?> _failedWrite(File file, int bytes) async {
  try {
    await file.writeAsBytes(Uint8List(bytes), flush: true);
  } on FileSystemException catch (error) {
    return error.osError?.errorCode;
  }
  throw StateError('The operating system accepted the probe that should fail.');
}

String _document({bool acknowledged = false, bool recovered = false}) =>
    jsonEncode({
      'events': [],
      'tasks': [
        {
          'id': 'original-task',
          'title': 'Keep the earlier record',
          'category': 'work',
          'done': false,
        },
      ],
      'notes': [
        if (acknowledged)
          {
            'id': 'ack-note',
            'title': 'Acknowledged work',
            'body': 'Keep this text.',
            'updated': '2026-11-24T01:00:00Z',
          },
        if (recovered)
          {
            'id': 'recovered-note',
            'title': 'Large recovered edit',
            'body': base64Encode(_noise(256 * 1024)),
            'updated': '2026-11-24T01:02:00Z',
          },
      ],
      'captures': [
        if (acknowledged) _capture('previous', _existingAttachment),
        if (recovered) _capture('recovered', _newAttachment),
      ],
    });

Map<String, Object?> _capture(String id, AttachmentRef audio) => {
  'id': id,
  'text': 'Synthetic $id recording',
  'capturedAt': '2026-11-24T01:00:00Z',
  'audio': audio.toJson(),
};

AttachmentRef _reference(Uint8List bytes) => AttachmentRef(
  id: sha256.convert(bytes).toString(),
  format: AttachmentFormat.wav,
  byteLength: bytes.length,
);

Uint8List _noise(int size) {
  final random = Random(22349);
  return Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
}

Uint8List _wave(int payloadBytes) {
  final bytes = Uint8List(44 + payloadBytes);
  final data = ByteData.sublistView(bytes);
  void label(int index, String value) =>
      bytes.setRange(index, index + value.length, ascii.encode(value));
  void word(int index, int value) =>
      data.setUint16(index, value, Endian.little);
  void length(int index, int value) =>
      data.setUint32(index, value, Endian.little);
  label(0, 'RIFF');
  length(4, bytes.length - 8);
  label(8, 'WAVEfmt ');
  length(16, 16);
  word(20, 1);
  word(22, 1);
  length(24, 16000);
  length(28, 32000);
  word(32, 2);
  word(34, 16);
  label(36, 'data');
  length(40, payloadBytes);
  bytes.setRange(44, bytes.length, _noise(payloadBytes));
  return bytes;
}

final class _Limit extends Struct {
  @UnsignedLong()
  external int soft;

  @UnsignedLong()
  external int hard;
}

/// Applies the Linux process limit inside the disposable Flutter test worker.
/// Compilation, the test launcher and any unrelated process are untouched.
Future<void> _withFileCeiling(int bytes, Future<void> Function() run) async {
  if (Abi.current() != Abi.linuxX64 && Abi.current() != Abi.linuxArm64) {
    throw UnsupportedError(
      'Use Linux x64 or arm64 for the native file-size probe.',
    );
  }
  const fileSize = 1; // RLIMIT_FSIZE on these Linux architectures.
  const fileTooLargeSignal = 25; // SIGXFSZ on these Linux architectures.
  final libc = DynamicLibrary.process();
  final allocate = libc
      .lookupFunction<
        Pointer<_Limit> Function(IntPtr, IntPtr),
        Pointer<_Limit> Function(int, int)
      >('calloc');
  final release = libc
      .lookupFunction<
        Void Function(Pointer<_Limit>),
        void Function(Pointer<_Limit>)
      >('free');
  final getLimit = libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<_Limit>),
        int Function(int, Pointer<_Limit>)
      >('getrlimit');
  final setLimit = libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<_Limit>),
        int Function(int, Pointer<_Limit>)
      >('setrlimit');
  final ignore = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'sigignore',
  );
  final saved = allocate(1, sizeOf<_Limit>());
  final bounded = allocate(1, sizeOf<_Limit>());
  try {
    if (saved == nullptr ||
        bounded == nullptr ||
        getLimit(fileSize, saved) != 0 ||
        ignore(fileTooLargeSignal) != 0) {
      throw StateError(
        'Cannot initialize the disposable Linux file-size probe.',
      );
    }
    bounded.ref
      ..soft = bytes
      ..hard = saved.ref.hard;
    if (setLimit(fileSize, bounded) != 0) {
      throw StateError('Cannot set the file-size ceiling.');
    }
    try {
      await run();
    } finally {
      if (setLimit(fileSize, saved) != 0) {
        throw StateError('Cannot restore the worker file-size ceiling.');
      }
    }
  } finally {
    release(bounded);
    release(saved);
  }
}
