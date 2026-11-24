import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy/storage/attachment_store.dart';
import 'package:easy/storage/media_backup.dart';
import 'package:easy/storage/src/media_staging_native.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late Directory originals;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('easy-interrupted-media-');
    originals = await Directory.fromUri(folder.uri.resolve('originals'))
        .create();
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    addTearDown(() => folder.delete(recursive: true));
  });

  final dartBin = _findDart();
  test(
    'live leases survive review and a killed import can be cleared without its originals',
    () async {
      final attachments = (await openAttachmentStore(
        directoryPath: originals.path,
      ))!;
      addTearDown(attachments.close);
      final maintenance = attachments as InterruptedAttachmentImports;
      final historic = await attachments.putBytes(
        _wave(12),
        kind: AttachmentKind.audio,
      );
      final recovered = await attachments.putBytes(
        _wave(34),
        kind: AttachmentKind.audio,
      );
      final working = await attachments.putBytes(
        _wave(56),
        kind: AttachmentKind.audio,
      );
      final store = (await openWorkspaceStore(
        databasePath: folder.uri.resolve('workspace.sqlite3').toFilePath(),
        preferences: SharedPreferencesAsync(),
        readLegacy: () async => _snapshot(historic),
      )) as WorkspaceHistoryStore;
      addTearDown(store.close);
      await store.nameHistoryPoint(
        'Historical voice draft',
        expectedRevision: 1,
      );
      await store.save(WorkspaceMutation.replace(_snapshot(recovered)));
      final extra = await openWorkspaceStore(
        databasePath: folder.uri.resolve('working.sqlite3').toFilePath(),
        preferences: SharedPreferencesAsync(),
        readLegacy: () async => _snapshot(working),
      );
      addTearDown(extra.close);
      await store.restoreBackup(
        await store.previewBackup(await extra.createBackup()),
        expectedRevision: 2,
      );

      final worker = await Process.start(dartBin!, [
        'test/fixtures/media_staging_worker.dart',
        originals.path,
        MediaStageKind.imports.name,
      ]);
      addTearDown(() async {
        worker.kill(ProcessSignal.sigkill);
        await worker.exitCode;
      });
      final stagePath = await worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      expect((await maintenance.previewInterruptedImports()).stageCount, 0);
      expect(Directory(stagePath).existsSync(), isTrue);
      expect(worker.kill(ProcessSignal.sigkill), isTrue);
      expect(await worker.exitCode, isNot(0));

      final preview = await maintenance.previewInterruptedImports();
      expect(preview.stageCount, 1);
      expect(preview.fileCount, 1);
      expect(preview.bytes, 4096);
      expect(Directory(stagePath).existsSync(), isTrue);
      final removed = await maintenance.removeInterruptedImports(preview);
      expect(removed.removedStages, 1);
      expect(removed.removedBytes, 4096);
      expect(Directory(stagePath).existsSync(), isFalse);
      final repeated = await maintenance.removeInterruptedImports(preview);
      expect(repeated.removedStages, 0);
      expect(repeated.skippedStages, 0);
      expect((await attachments.read(historic.id)).bytes, _wave(12));
      expect((await attachments.read(recovered.id)).bytes, _wave(34));
      expect((await attachments.read(working.id)).bytes, _wave(56));
      expect(
        (await store.previewHistoryPoint(1)).snapshot.workspaceJson,
        _snapshot(historic).workspaceJson,
      );
      final recovery = (await store.readRecoveryBackup())!;
      expect(
        (await store.previewBackup(recovery)).snapshot.workspaceJson,
        _snapshot(recovered).workspaceJson,
      );
      expect(
        (await store.read()).snapshot.workspaceJson,
        _snapshot(working).workspaceJson,
      );
    },
    skip: Platform.isWindows || dartBin == null
        ? 'A native Dart process and kill signal are required.'
        : false,
  );

  test(
    'same-process work is excluded and changed candidates need another review',
    () async {
      final active = await MediaFileStage.create(
        originals,
        MediaStageKind.imports,
      );
      addTearDown(active.close);
      final decoy = await File.fromUri(active.content.uri.resolve('payload'))
          .create();
      await decoy.writeAsBytes([1, 2, 3]);
      final stale = await _abandoned(
        originals,
        MediaStageKind.imports,
        'change-check',
      );
      final preview = await previewMediaStages(
        originals,
        MediaStageKind.imports,
      );
      expect(preview.stageCount, 1);
      final payload = File.fromUri(stale.uri.resolve('content/payload'));
      await payload.writeAsBytes([1, 2, 3, 4]);
      final rejected = await removeMediaStages(
        originals,
        MediaStageKind.imports,
        preview,
      );
      expect(rejected.removedStages, 0);
      expect(rejected.skippedStages, 1);
      expect(payload.existsSync(), isTrue);
      final fresh = await previewMediaStages(originals, MediaStageKind.imports);
      expect(fresh.bytes, 4);
      expect(
        (await removeMediaStages(
          originals,
          MediaStageKind.imports,
          fresh,
        )).removedStages,
        1,
      );
      expect(decoy.existsSync(), isTrue);
    },
  );

  test('large pending sets are batched and an interrupted clear can be reviewed again', () async {
    for (var index = 0; index < 36; index++) {
      await _abandoned(folder, MediaStageKind.backups, 'bulk-$index');
    }
    await _abandoned(
      folder,
      MediaStageKind.backups,
      'already-reviewed',
      discarded: true,
    );
    final preview = await previewInterruptedBackupFiles(
      scratchDirectory: folder.path,
    );
    expect(preview.stageCount, 32);
    expect(preview.hasMore, isTrue);
    final removed = await removeInterruptedBackupFiles(
      preview,
      scratchDirectory: folder.path,
    );
    expect(removed.removedStages, 32);
    final remaining = await previewInterruptedBackupFiles(
      scratchDirectory: folder.path,
    );
    expect(remaining.stageCount, 5);
    expect(remaining.hasMore, isFalse);
    expect(
      (await removeInterruptedBackupFiles(
        remaining,
        scratchDirectory: folder.path,
      )).removedStages,
      5,
    );
    expect(
      (await previewInterruptedBackupFiles(scratchDirectory: folder.path))
          .stageCount,
      0,
    );
    expect(originals.existsSync(), isTrue);
  });

  test(
    'cleanup rejects foreign reviews and preserves suspicious links and unknown files',
    () async {
      final outside = File.fromUri(folder.uri.resolve('real-original'));
      await outside.writeAsBytes([1, 2, 3]);
      final linked = await _abandoned(
        originals,
        MediaStageKind.imports,
        'links',
      );
      final linkedPath = linked.uri.resolve('content/payload').toFilePath();
      await File(linkedPath).delete();
      await Link(linkedPath).create(outside.path);
      final unknown = await _abandoned(
        originals,
        MediaStageKind.imports,
        'unknown',
      );
      await File.fromUri(unknown.uri.resolve('foreign'))
          .writeAsBytes([1, 2, 3]);
      final safe = await _abandoned(originals, MediaStageKind.imports, 'known');
      final preview = await previewMediaStages(
        originals,
        MediaStageKind.imports,
      );
      expect(preview.stageCount, 1);
      await expectLater(
        removeMediaStages(folder, MediaStageKind.imports, preview),
        throwsA(isA<AttachmentStoreException>()),
      );
      expect(
        (await removeMediaStages(
          originals,
          MediaStageKind.imports,
          preview,
        )).removedStages,
        1,
      );
      expect(safe.existsSync(), isFalse);
      expect(unknown.existsSync(), isTrue);
      expect(Link(linkedPath).existsSync(), isTrue);
      expect(await outside.readAsBytes(), [1, 2, 3]);
    },
    skip: Platform.isWindows
        ? 'The test creates a Unix-style symbolic link.'
        : false,
  );
}

String? _findDart() {
  final override = Platform.environment['EASY_DART_BIN'];
  if (override != null && File(override).existsSync()) return override;
  final tester = File(Platform.resolvedExecutable);
  final cache = tester.parent.parent.parent.parent;
  final candidate = File.fromUri(cache.uri.resolve('dart-sdk/bin/dart'));
  return candidate.existsSync() ? candidate.path : null;
}

Future<Directory> _abandoned(
  Directory root,
  MediaStageKind kind,
  String suffix, {
  bool discarded = false,
}) async {
  final fakePid = pid == 1 ? 2 : 1;
  final normal = '.easy-stage-${kind.name}-$fakePid-$suffix';
  final name = discarded
      ? normal.replaceFirst('.easy-', '.easy-discarded-')
      : normal;
  final path = await Directory.fromUri(root.uri.resolve(name)).create();
  final content = await Directory.fromUri(path.uri.resolve('content')).create();
  if (!discarded) {
    await File.fromUri(path.uri.resolve('lease')).create();
    await File.fromUri(path.uri.resolve('ready'))
        .writeAsString('Easy media stage 1\n$normal\n');
  }
  final payload = kind == MediaStageKind.imports ? 'payload' : 'source';
  await File.fromUri(content.uri.resolve(payload)).writeAsBytes([1, 2, 3]);
  return path;
}

WorkspaceSnapshot _snapshot(AttachmentRef audio) => WorkspaceSnapshot(
  workspaceJson: jsonEncode({
    'events': [],
    'tasks': [],
    'notes': [],
    'captures': [
      {
        'id': 'voice-draft',
        'text': 'Synthetic record',
        'capturedAt': '2026-11-24T08:00:00Z',
        'audio': audio.toJson(),
      },
    ],
  }),
  gymSessionJson: [],
  workoutPlanJson: [],
);

Uint8List _wave(int sample) {
  final bytes = Uint8List(46);
  bytes.setAll(0, ascii.encode('RIFF'));
  bytes.setAll(8, ascii.encode('WAVEfmt '));
  bytes.setAll(36, ascii.encode('data'));
  ByteData.sublistView(bytes)
    ..setUint32(4, 38, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, 2, Endian.little)
    ..setUint16(44, sample, Endian.little);
  return bytes;
}
