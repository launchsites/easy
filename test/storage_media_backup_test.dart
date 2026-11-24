import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy/storage/attachment_store.dart';
import 'package:easy/storage/encrypted_backup.dart';
import 'package:easy/storage/media_backup.dart';
import 'package:easy/storage/src/media_backup_frames.dart';
import 'package:easy/storage/src/media_backup_manifest.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';

const _password = 'Synthetic portable media passphrase';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+bB6sAAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory base;
  late Directory scratch;
  final databases = <WorkspaceStore>[];
  final attachments = <AttachmentStore>[];
  final files = <WorkspaceMediaBackupFile>[];
  final previews = <WorkspaceMediaBackupPreview>[];

  setUp(() async {
    base = await Directory.systemTemp.createTemp('easy-media-bundle-');
    scratch = await Directory.fromUri(base.uri.resolve('scratch')).create();
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  tearDown(() async {
    await Future.wait(previews.map((preview) => preview.close()));
    await Future.wait(files.map((file) => file.close()));
    await Future.wait(attachments.map((store) => store.close()));
    await Future.wait(databases.map((store) => store.close()));
    previews.clear();
    files.clear();
    attachments.clear();
    databases.clear();
    await base.delete(recursive: true);
  });

  String dbPath(String name) => base.uri.resolve('$name.sqlite3').toFilePath();

  Future<WorkspaceHistoryStore> workspace(String name, String data) async {
    final database = (await openWorkspaceStore(
      databasePath: dbPath(name),
      preferences: SharedPreferencesAsync(),
      readLegacy: () async => _snapshot(data),
    )) as WorkspaceHistoryStore;
    databases.add(database);
    return database;
  }

  Future<AttachmentStore> media(String name) async {
    final store = (await openAttachmentStore(
      directoryPath: base.uri.resolve(name).toFilePath(),
    ))!;
    attachments.add(store);
    return store;
  }

  Future<WorkspaceMediaBackupFile> export(
    WorkspaceStore store,
    AttachmentStore media, {
    WorkspaceMediaBackupLimits limits = const WorkspaceMediaBackupLimits(),
  }) async {
    final file = await createWorkspaceMediaBackup(
      store: store,
      attachments: media,
      passphrase: _password,
      scratchDirectory: scratch.path,
      limits: limits,
    );
    files.add(file);
    return file;
  }

  Future<WorkspaceMediaBackupPreview> inspect(
    WorkspaceStore store,
    Stream<List<int>> data, {
    String password = _password,
    WorkspaceMediaBackupLimits limits = const WorkspaceMediaBackupLimits(),
  }) async {
    final preview = await previewWorkspaceMediaBackup(
      store: store,
      source: data,
      passphrase: password,
      scratchDirectory: scratch.path,
      limits: limits,
    );
    previews.add(preview);
    return preview;
  }

  Future<(WorkspaceHistoryStore, AttachmentStore, AttachmentRef, AttachmentRef)>
  source() async {
    final original = await media('original-files');
    final audio = await original.putBytes(
      _tinyWave(),
      kind: AttachmentKind.audio,
    );
    final photo = await original.putBytes(_png, kind: AttachmentKind.photo);
    final database = await workspace(
      'original',
      _workspace('Archived record', audio: audio, photo: photo),
    );
    return (database, original, audio, photo);
  }

  test('portable restore preserves original shared refs, byte contents, history and recovery', () async {
    final (originalDb, originalMedia, audio, photo) = await source();
    final previous = _workspace('Current workspace record');
    final target = await workspace('target', previous);
    final targetMedia = await media('target-files');
    await target.nameHistoryPoint(
      'Before portable restore',
      expectedRevision: 1,
    );
    final archive = await export(originalDb, originalMedia);
    final bytes = await _collect(archive.openRead());
    expect(isWorkspaceMediaBackup(bytes), isTrue);
    expect(isEncryptedWorkspaceBackup(bytes), isFalse);
    expect(latin1.decode(bytes), isNot(contains('Archived record')));
    expect(bytes.length, archive.byteLength);
    final preview = await inspect(target, _fragments(bytes));
    expect(preview.backup.counts.captures, 2);
    expect(preview.backup.counts.meals, 1);
    expect(
      preview.attachments.map((ref) => ref.id),
      [audio.id, photo.id]..sort(),
    );
    expect(preview.mediaBytes, _png.length + _tinyWave().length);
    expect((await target.read()).revision, 1);
    await expectLater(
      targetMedia.read(photo.id),
      throwsA(isA<AttachmentStoreException>()),
    );

    final restored = await restoreWorkspaceMediaBackup(
      store: target,
      attachments: targetMedia,
      preview: preview,
    );
    expect(restored.revision, 2);
    expect(
      restored.snapshot.workspaceJson,
      _workspace('Archived record', audio: audio, photo: photo),
    );
    expect((await targetMedia.read(audio.id)).bytes, _tinyWave());
    expect((await targetMedia.read(photo.id)).bytes, _png);
    expect(
      (await target.previewHistoryPoint(1)).snapshot.workspaceJson,
      previous,
    );
    final recovery = (await target.readRecoveryBackup())!;
    expect(
      (await target.previewBackup(recovery)).snapshot.workspaceJson,
      previous,
    );

    final later = _workspace(
      'Edit after portable restore',
      audio: audio,
      photo: photo,
    );
    await target.save(WorkspaceMutation.workspace(later));
    final retry = await restoreWorkspaceMediaBackup(
      store: target,
      attachments: targetMedia,
      preview: preview,
    );
    expect(retry.revision, 3);
    expect(retry.snapshot.workspaceJson, later);
    expect(await target.readRecoveryBackup(), recovery);
    await preview.close();
    await archive.close();
    expect(await scratch.list().toList(), isEmpty);
    final database = sqlite3.open(dbPath('target'));
    try {
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      database.close();
    }
  });

  test('wrong password, truncation, edited tags or extra bytes leave no review files', () async {
    final (original, originalMedia, _, _) = await source();
    final target = await workspace('target', _workspace('Leave untouched'));
    final archive = await export(original, originalMedia);
    final bytes = await _collect(archive.openRead());
    await archive.close();
    final authenticatedError = throwsA(
      isA<WorkspaceMediaBackupAuthenticationException>(),
    );
    var tailReads = 0;
    Stream<Uint8List> withLargeTail() async* {
      yield bytes;
      tailReads++;
      yield Uint8List(1024 * 1024);
    }

    await expectLater(
      inspect(target, withLargeTail(), password: 'Wrong password'),
      authenticatedError,
    );
    expect(tailReads, 0);
    final damaged = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    await expectLater(
      inspect(target, Stream.value(damaged)),
      authenticatedError,
    );
    await expectLater(
      inspect(
        target,
        Stream.value(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      ),
      throwsFormatException,
    );
    await expectLater(
      inspect(target, Stream.value(Uint8List.fromList([...bytes, 0]))),
      throwsFormatException,
    );
    final cryptogram = Uint8List.fromList(bytes)..[37] ^= 1;
    await expectLater(
      inspect(target, Stream.value(cryptogram)),
      authenticatedError,
    );
    expect((await target.read()).revision, 1);
    expect(await scratch.list().toList(), isEmpty);
  });

  test('strict exact manifests reject an unassociated media file and mismatched bytes', () async {
    final (original, originalMedia, audio, photo) = await source();
    final destination = await workspace('destination', _workspace('Keep'));
    final recordOnly = await workspace(
      'records',
      _workspace('No photos', audio: audio),
    );
    final unrelated = await _syntheticArchive(
      base,
      await recordOnly.createBackup(),
      [audio, photo],
      {audio.id: _tinyWave(), photo.id: _png},
    );
    await expectLater(
      inspect(destination, unrelated.openRead()),
      throwsFormatException,
    );
    final alteredPhoto = Uint8List.fromList(_png)..[53] ^= 1;
    final mismatched = await _syntheticArchive(
      base,
      await original.createBackup(),
      [audio, photo],
      {audio.id: _tinyWave(), photo.id: alteredPhoto},
    );
    await expectLater(
      inspect(destination, mismatched.openRead()),
      throwsFormatException,
    );
    await expectLater(
      export(
        original,
        originalMedia,
        limits: const WorkspaceMediaBackupLimits(attachments: 1),
      ),
      throwsFormatException,
    );
    final archive = await export(original, originalMedia);
    await expectLater(
      inspect(
        destination,
        archive.openRead(),
        limits: const WorkspaceMediaBackupLimits(mediaBytes: 1),
      ),
      throwsFormatException,
    );
    await archive.close();
    expect(await scratch.list().toList(), isEmpty);
    expect((await destination.read()).revision, 1);
  });

  test('unavailable original file aborts export and old logical backups remain supported', () async {
    final (original, _, _, _) = await source();
    final missing = await media('empty-attachment-folder');
    await expectLater(
      export(original, missing),
      throwsA(isA<AttachmentStoreException>()),
    );
    expect(await scratch.list().toList(), isEmpty);
    final logical = await original.createEncryptedBackup(_password);
    expect(isEncryptedWorkspaceBackup(logical), isTrue);
    expect(isWorkspaceMediaBackup(logical), isFalse);
    final preview = await original.previewEncryptedBackup(logical, _password);
    expect(preview.counts.captures, 2);
    expect(preview.counts.meals, 1);
  });

  test('failed media publication leaves the workspace unchanged and a matching retry completes', () async {
    final (original, originalMedia, _, _) = await source();
    final destination = await workspace('destination', _workspace('Old notes'));
    final target = await media('failed-target');
    final archive = await export(original, originalMedia);
    final preview = await inspect(destination, archive.openRead());
    final failing = _FailingAttachmentStore(target)..failAfter = 1;
    await expectLater(
      restoreWorkspaceMediaBackup(
        store: destination,
        attachments: failing,
        preview: preview,
      ),
      throwsA(isA<AttachmentStoreException>()),
    );
    expect((await destination.read()).revision, 1);
    expect(await destination.readRecoveryBackup(), isNull);
    expect(
      await Directory(base.uri.resolve('failed-target').toFilePath())
          .list()
          .length,
      1,
    );
    failing.failAfter = null;
    expect(
      (await restoreWorkspaceMediaBackup(
        store: destination,
        attachments: failing,
        preview: preview,
      )).revision,
      2,
    );
    expect(
      await Directory(base.uri.resolve('failed-target').toFilePath())
          .list()
          .length,
      2,
    );
    expect(await destination.readRecoveryBackup(), isNotNull);
  });

  test('stale review fails before publishing and reviewed attachment tampering fails closed', () async {
    final (original, originalMedia, _, _) = await source();
    final destination = await workspace('destination', _workspace('Before'));
    final target = await media('stale-target');
    final archive = await export(original, originalMedia);
    final preview = await inspect(destination, archive.openRead());
    await destination.save(
      WorkspaceMutation.workspace(_workspace('Other window edited')),
    );
    final monitored = _FailingAttachmentStore(target);
    await expectLater(
      restoreWorkspaceMediaBackup(
        store: destination,
        attachments: monitored,
        preview: preview,
      ),
      throwsA(isA<WorkspaceRevisionConflict>()),
    );
    expect(monitored.puts, 0);
    await preview.close();
    final fresh = await inspect(destination, archive.openRead());
    final directories = await scratch
        .list()
        .where((entry) => entry is Directory)
        .toList();
    final candidates = [
      for (final directory in directories)
        File(Uri.directory(directory.path).resolve('source').toFilePath()),
    ];
    final body = candidates.singleWhere((file) => file.existsSync());
    expect(await body.parent.list().length, 1);
    final data = await body.readAsBytes();
    data[mediaFrameHeaderLength + 6] ^= 1;
    await body.writeAsBytes(data);
    await expectLater(
      restoreWorkspaceMediaBackup(
        store: destination,
        attachments: monitored,
        preview: fresh,
      ),
      throwsA(isA<WorkspaceMediaBackupAuthenticationException>()),
    );
    expect(
      (await destination.read()).snapshot.workspaceJson,
      _workspace('Other window edited'),
    );
    expect(await destination.readRecoveryBackup(), isNull);
    expect(
      await Directory(base.uri.resolve('stale-target').toFilePath())
          .list()
          .length,
      0,
    );
  });

  test('large streamed audio validates and moves without materializing the archive', () async {
    const payloadBytes = 24 * 1024 * 1024;
    final largeMedia = await media('large-files');
    final audio = await largeMedia.putStream(
      _waveStream(payloadBytes),
      kind: AttachmentKind.audio,
      expectedLength: payloadBytes + 44,
    );
    final original = await workspace(
      'large-source',
      _workspace('Large voice recording', audio: audio),
    );
    final archive = await export(original, largeMedia);
    expect(archive.byteLength, greaterThan(payloadBytes));
    final target = await workspace('large-target', _workspace('Before'));
    final targetFiles = await media('large-target-files');
    final preview = await inspect(target, archive.openRead());
    expect(preview.mediaBytes, payloadBytes + 44);
    final restored = await restoreWorkspaceMediaBackup(
      store: target,
      attachments: targetFiles,
      preview: preview,
    );
    expect(restored.revision, 2);
    final verified = await sha256
        .bind((targetFiles as StreamingAttachmentStore).readStream(audio))
        .first;
    expect(verified.toString(), audio.id);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

WorkspaceSnapshot _snapshot(String workspace) => WorkspaceSnapshot(
  workspaceJson: workspace,
  gymSessionJson: const [],
  workoutPlanJson: const [],
);

String _workspace(String text, {AttachmentRef? audio, AttachmentRef? photo}) =>
    jsonEncode({
      'events': [],
      'tasks': [],
      'notes': [
        {
          'id': 'note-1',
          'title': text,
          'body': 'Local note',
          'updated': '2026-11-24T01:00:00Z',
        },
      ],
      if (audio != null)
        'captures': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'capture-$i',
              'text': text,
              'capturedAt': '2026-11-24T02:00:00Z',
              'audio': audio.toJson(),
            },
        ],
      if (photo != null)
        'nutrition': {
          'version': 1,
          'foods': [],
          'meals': [
            {
              'id': 'meal-1',
              'name': 'Lunch photo',
              'eatenAt': '2026-11-24T03:00:00Z',
              'draft': true,
              'portions': [],
              'photo': photo.toJson(),
            },
          ],
        },
    });

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final piece in stream) {
    bytes.add(piece);
  }
  return bytes.takeBytes();
}

Stream<Uint8List> _fragments(Uint8List bytes) async* {
  for (var offset = 0; offset < bytes.length; offset += 19) {
    yield Uint8List.sublistView(
      bytes,
      offset,
      (offset + 19).clamp(0, bytes.length),
    );
  }
}

Uint8List _waveHeader(int body) {
  final header = Uint8List(44);
  header.setAll(0, ascii.encode('RIFF'));
  header.setAll(8, ascii.encode('WAVEfmt '));
  header.setAll(36, ascii.encode('data'));
  ByteData.sublistView(header)
    ..setUint32(4, body + 36, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, body, Endian.little);
  return header;
}

Uint8List _tinyWave() =>
    Uint8List.fromList([..._waveHeader(8), 0, 0, 2, 0, 8, 0, 9, 0]);

Stream<Uint8List> _waveStream(int bytes) async* {
  yield _waveHeader(bytes);
  final block = Uint8List(64 * 1024)..[100] = 71;
  for (var offset = 0; offset < bytes; offset += block.length) {
    yield Uint8List.sublistView(
      block,
      0,
      (bytes - offset).clamp(0, block.length),
    );
  }
}

Future<File> _syntheticArchive(
  Directory base,
  Uint8List backup,
  List<AttachmentRef> refs,
  Map<String, Uint8List> bodies,
) async {
  final directory = await base.createTemp('synthetic-media-');
  final file = File.fromUri(directory.uri.resolve('backup'));
  final sorted = refs.toList()..sort((a, b) => a.id.compareTo(b.id));
  final manifest = utf8.encode(
    MediaBackupManifest(
      backupLength: backup.length,
      backupDigest: sha256.convert(backup).toString(),
      attachments: sorted,
    ).encode(),
  );
  final writer = await MediaFrameWriter.open(file, _password);
  try {
    await writer.add(
      (ByteData(4)..setUint32(0, manifest.length)).buffer.asUint8List(),
    );
    await writer.add(manifest);
    await writer.add(backup);
    for (final ref in sorted) {
      await writer.add(bodies[ref.id]!);
    }
    await writer.finish();
  } finally {
    await writer.close();
  }
  return file;
}

final class _FailingAttachmentStore implements AttachmentStore {
  _FailingAttachmentStore(this.delegate);

  final AttachmentStore delegate;
  int? failAfter;
  var puts = 0;

  @override
  Future<AttachmentRef> putStream(
    Stream<List<int>> source, {
    required AttachmentKind kind,
    String? declaredMimeType,
    int? expectedLength,
    String? expectedContentId,
  }) async {
    if (puts++ == failAfter) {
      throw const AttachmentStoreException('Synthetic disk interruption.');
    }
    return delegate.putStream(
      source,
      kind: kind,
      declaredMimeType: declaredMimeType,
      expectedLength: expectedLength,
      expectedContentId: expectedContentId,
    );
  }

  @override
  Future<AttachmentRef> putBytes(
    Uint8List bytes, {
    required AttachmentKind kind,
    String? declaredMimeType,
  }) =>
      delegate.putBytes(bytes, kind: kind, declaredMimeType: declaredMimeType);

  @override
  Future<StoredAttachment> read(String id) => delegate.read(id);

  @override
  Future<void> close() async {}
}
