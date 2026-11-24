import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_contracts.dart';
import 'attachment_media.dart';
import 'backup_password.dart';
import 'contracts.dart';
import 'media_backup_contracts.dart';
import 'media_backup_frames.dart';
import 'media_backup_manifest.dart';
import 'media_staging_contracts.dart';
import 'media_staging_native.dart';
import 'snapshot_codec.dart';

var _jobs = 0;
const _maxJobs = 2;

Future<WorkspaceMediaBackupFile> createMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required String passphrase,
  required WorkspaceMediaBackupLimits limits,
  required String? scratchDirectory,
}) => _job(() async {
  validateBackupPassphrase(passphrase);
  limits.validate();
  final saved = await store.read();
  final (backup, manifest) = await _encodeSnapshot(saved, limits);
  final encodedManifest = utf8.encode(manifest.encode());
  if (encodedManifest.length > mediaManifestByteLimit) {
    throw const FormatException('The media backup manifest is too large.');
  }
  final stage = await _scratch(scratchDirectory);
  var retained = false;
  try {
    final filename = _mediaBackupFilename(DateTime.now());
    final output = _within(stage.content, filename);
    final writer = await MediaFrameWriter.open(output, passphrase);
    try {
      final size = ByteData(4)..setUint32(0, encodedManifest.length);
      await writer.add(size.buffer.asUint8List());
      await writer.add(encodedManifest);
      await writer.add(backup);
      for (final reference in manifest.attachments) {
        await _copyVerified(
          _attachmentBytes(attachments, reference),
          length: reference.byteLength,
          digest: reference.id,
          write: writer.add,
        );
      }
      await writer.finish();
    } finally {
      await writer.close();
    }
    final length = await output.length();
    if (length > mediaArchiveLengthLimit(limits)) {
      throw const FormatException('The media backup is too large.');
    }
    final result = _MediaBackupFile(stage, output, length, filename);
    retained = true;
    return result;
  } finally {
    if (!retained) await stage.close();
  }
});

Future<WorkspaceMediaBackupPreview> previewMediaBackup({
  required WorkspaceStore store,
  required Stream<List<int>> source,
  required String passphrase,
  required WorkspaceMediaBackupLimits limits,
  required String? scratchDirectory,
}) => _job(() async {
  validateBackupPassphrase(passphrase);
  limits.validate();
  final expected = (await store.read()).revision;
  final stage = await _scratch(scratchDirectory);
  var retained = false;
  try {
    final encrypted = _within(stage.content, 'source');
    final reader = await MediaFrameReader.open(
      _retainEncryptedInput(source, encrypted, mediaArchiveLengthLimit(limits)),
      passphrase,
    );
    final MediaBackupManifest manifest;
    final WorkspaceBackupPreview backup;
    final String identity;
    try {
      (manifest, identity) = await _readManifest(reader, limits);

      final workspace = Uint8List(manifest.backupLength);
      var offset = 0;
      await _copyVerified(
        reader.take(workspace.length),
        length: workspace.length,
        digest: manifest.backupDigest,
        write: (bytes) async {
          workspace.setRange(offset, offset + bytes.length, bytes);
          offset += bytes.length;
        },
      );
      backup = await store.previewBackup(workspace);
      await _verifyManifestRefs(
        backup.snapshot.workspaceJson,
        manifest,
        limits,
      );
      for (final attachment in manifest.attachments) {
        await _validateAttachment(reader, stage.content, attachment);
      }
      await reader.expectEnd();
    } finally {
      await reader.close();
    }
    final result = _MediaBackupPreview(
      store,
      stage,
      encrypted,
      backup,
      manifest,
      identity,
      passphrase,
      limits,
      expected,
    );
    retained = true;
    return result;
  } finally {
    if (!retained) await stage.close();
  }
});

Future<WorkspaceRevision> restoreMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required WorkspaceMediaBackupPreview preview,
}) async {
  if (preview is! _MediaBackupPreview || !identical(preview._store, store)) {
    throw const WorkspaceMediaBackupException(
      'Open this media backup in the current workspace first.',
    );
  }
  return preview._use(
    () => _job(() async {
      final id =
          'media-restore-${preview._identity}-${preview.expectedRevision}';
      final current = await store.read();
      if (current.revision < preview.expectedRevision) {
        throw WorkspaceRevisionConflict(
          expected: preview.expectedRevision,
          actual: current.revision,
        );
      }
      if (current.revision > preview.expectedRevision) {
        // Workspace revisions only increase. With an older expectation, the
        // store can return the committed retry or reject without a write.
        return store.restoreBackup(
          preview.backup,
          expectedRevision: preview.expectedRevision,
          operationId: id,
        );
      }

      await _publishAttachments(preview, attachments);
      return store.restoreBackup(
        preview.backup,
        expectedRevision: preview.expectedRevision,
        operationId: id,
      );
    }),
  );
}

Future<(MediaBackupManifest, String)> _readManifest(
  MediaFrameReader reader,
  WorkspaceMediaBackupLimits limits,
) async {
  final size = ByteData.sublistView(await reader.read(4)).getUint32(0);
  if (size < 1 || size > mediaManifestByteLimit) {
    throw const FormatException('Invalid media backup manifest size.');
  }
  return _decodeManifest(await reader.read(size), limits);
}

Future<void> _publishAttachments(
  _MediaBackupPreview preview,
  AttachmentStore attachments,
) async {
  final file = preview._archive;
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const WorkspaceMediaBackupException(
      'The reviewed archive is unavailable. Open the backup again.',
    );
  }
  final reader = await MediaFrameReader.open(
    file.openRead(),
    preview._passphrase!,
  );
  try {
    final (manifest, identity) = await _readManifest(reader, preview._limits);
    if (identity != preview._identity) {
      throw const WorkspaceMediaBackupException(
        'The reviewed archive changed. Open the backup again.',
      );
    }
    await _copyVerified(
      reader.take(manifest.backupLength),
      length: manifest.backupLength,
      digest: manifest.backupDigest,
      write: (_) async {},
    );
    for (final reference in manifest.attachments) {
      final saved = await attachments.putStream(
        reader.take(reference.byteLength),
        kind: reference.format.kind,
        declaredMimeType: reference.mimeType,
        expectedLength: reference.byteLength,
        expectedContentId: reference.id,
      );
      if (!sameMediaReference(saved, reference)) {
        throw const WorkspaceMediaBackupException(
          'The attachment store did not retain the original file.',
        );
      }
    }
    await reader.expectEnd();
  } finally {
    await reader.close();
  }
}

Future<T> _job<T>(Future<T> Function() work) async {
  if (_jobs >= _maxJobs) {
    throw const WorkspaceMediaBackupException(
      'Wait for the current media backup to finish.',
    );
  }
  _jobs++;
  try {
    return await work();
  } on FileSystemException {
    throw const WorkspaceMediaBackupException(
      'The media backup files could not be saved or read.',
    );
  } finally {
    _jobs--;
  }
}

Future<MediaFileStage> _scratch(String? override) async {
  final folder = await _scratchRoot(override);
  await folder.create(recursive: true);
  return MediaFileStage.create(folder, MediaStageKind.backups);
}

Future<Directory> _scratchRoot(String? override) async =>
    override == null ? getTemporaryDirectory() : Directory(override);

Future<MediaStagingCleanupPreview> previewInterruptedBackupFiles({
  String? scratchDirectory,
}) async => previewMediaStages(
  await _scratchRoot(scratchDirectory),
  MediaStageKind.backups,
);

Future<MediaStagingCleanupResult> removeInterruptedBackupFiles(
  MediaStagingCleanupPreview preview, {
  String? scratchDirectory,
}) async => removeMediaStages(
  await _scratchRoot(scratchDirectory),
  MediaStageKind.backups,
  preview,
);

File _within(Directory stage, String filename) =>
    File.fromUri(stage.uri.resolve(filename));

Future<(Uint8List, MediaBackupManifest)> _encodeSnapshot(
  WorkspaceRevision revision,
  WorkspaceMediaBackupLimits limits,
) => Isolate.run(() {
  final backup = encodeBackup(revision);
  return (backup, MediaBackupManifest.fromSnapshot(revision, backup, limits));
}, debugName: 'easy-media-backup-manifest');

Future<(MediaBackupManifest, String)> _decodeManifest(
  Uint8List bytes,
  WorkspaceMediaBackupLimits limits,
) => Isolate.run(
  () => (
    MediaBackupManifest.decode(bytes, limits),
    sha256.convert(bytes).toString(),
  ),
  debugName: 'easy-media-backup-manifest',
);

Future<void> _verifyManifestRefs(
  String workspace,
  MediaBackupManifest manifest,
  WorkspaceMediaBackupLimits limits,
) => Isolate.run(() {
  final refs = snapshotMediaReferences(workspace, limits);
  if (refs.length != manifest.attachments.length) {
    throw const FormatException(
      'The media manifest does not match the workspace records.',
    );
  }
  for (var index = 0; index < refs.length; index++) {
    if (!sameMediaReference(refs[index], manifest.attachments[index])) {
      throw const FormatException(
        'The media manifest does not match the workspace records.',
      );
    }
  }
}, debugName: 'easy-media-backup-references');

Stream<List<int>> _attachmentBytes(
  AttachmentStore store,
  AttachmentRef expected,
) async* {
  if (store is StreamingAttachmentStore) {
    yield* store.readStream(expected);
  } else {
    final stored = await store.read(expected.id);
    if (!sameMediaReference(stored.ref, expected)) {
      throw const FormatException('The original attachment metadata changed.');
    }
    yield stored.bytes;
  }
}

Stream<List<int>> _retainEncryptedInput(
  Stream<List<int>> source,
  File file,
  int maximumBytes,
) async* {
  final destination = await file.open(mode: FileMode.writeOnly);
  var count = 0;
  try {
    await for (final block in source) {
      if (block.length > maximumBytes - count) {
        throw const FormatException(
          'The media backup exceeds the supported size.',
        );
      }
      count += block.length;
      for (var offset = 0; offset < block.length; offset += mediaFrameBytes) {
        final end = min(offset + mediaFrameBytes, block.length);
        await destination.writeFrom(block, offset, end);
        yield block is Uint8List
            ? Uint8List.sublistView(block, offset, end)
            : block.sublist(offset, end);
      }
    }
  } finally {
    await destination.close();
  }
}

Future<void> _validateAttachment(
  MediaFrameReader reader,
  Directory stage,
  AttachmentRef expected,
) async {
  final file = _within(stage, expected.id);
  try {
    final destination = await file.open(mode: FileMode.writeOnly);
    try {
      await _copyVerified(
        reader.take(expected.byteLength),
        length: expected.byteLength,
        digest: expected.id,
        write: (bytes) async {
          await destination.writeFrom(bytes);
        },
      );
    } finally {
      await destination.close();
    }
    final format = await _verifyMediaFile(file.path, expected.byteLength);
    if (format != expected.format) {
      throw const FormatException(
        'A media file uses a different format than its manifest.',
      );
    }
  } finally {
    if (await file.exists()) await file.delete();
  }
}

Future<AttachmentFormat> _verifyMediaFile(String path, int bytes) =>
    Isolate.run(
      () => inspectAttachment(File(path), bytes),
      debugName: 'easy-media-backup-inspect',
    );

Future<void> _copyVerified(
  Stream<List<int>> source, {
  required int length,
  required String digest,
  required Future<void> Function(List<int>) write,
}) async {
  final result = _DigestSink();
  final hasher = sha256.startChunkedConversion(result);
  var count = 0;
  try {
    await for (final bytes in source) {
      if (bytes.length > length - count) {
        throw const FormatException(
          'Media backup data exceeds its declared size.',
        );
      }
      count += bytes.length;
      hasher.add(bytes);
      await write(bytes);
    }
  } finally {
    hasher.close();
  }
  if (count != length || result.digest.toString() != digest) {
    throw const FormatException('A media backup checksum does not match.');
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}

final class _MediaBackupFile implements WorkspaceMediaBackupFile {
  _MediaBackupFile(
    this._stage,
    this._file,
    this.byteLength,
    this.suggestedName,
  );

  final MediaFileStage _stage;
  final File _file;
  Future<void>? _closed;

  @override
  String get nativePath => _file.path;

  @override
  final int byteLength;

  @override
  final String suggestedName;

  @override
  Stream<List<int>> openRead() {
    if (_closed != null) {
      throw const WorkspaceMediaBackupException(
        'The media backup has been closed.',
      );
    }
    return _file.openRead();
  }

  @override
  Future<void> close() => _closed ??= _stage.close();
}

final class _MediaBackupPreview implements WorkspaceMediaBackupPreview {
  _MediaBackupPreview(
    this._store,
    this._stage,
    this._archive,
    this.backup,
    this._manifest,
    this._identity,
    this._passphrase,
    this._limits,
    this.expectedRevision,
  );

  final WorkspaceStore _store;
  final MediaFileStage _stage;
  final File _archive;
  final MediaBackupManifest _manifest;
  final String _identity;
  String? _passphrase;
  final WorkspaceMediaBackupLimits _limits;
  Completer<void>? _active;
  Future<void>? _closed;

  @override
  final WorkspaceBackupPreview backup;

  @override
  final int expectedRevision;

  @override
  List<AttachmentRef> get attachments => _manifest.attachments;

  @override
  int get mediaBytes => _manifest.totalMediaBytes;

  Future<T> _use<T>(Future<T> Function() work) async {
    if (_closed != null || _active != null) {
      throw const WorkspaceMediaBackupException(
        'The media backup preview is unavailable.',
      );
    }
    final active = _active = Completer<void>();
    try {
      return await work();
    } finally {
      _active = null;
      active.complete();
    }
  }

  @override
  Future<void> close() => _closed ??= _close();

  Future<void> _close() async {
    await _active?.future;
    _passphrase = null;
    await _stage.close();
  }
}

String _mediaBackupFilename(DateTime now) {
  final stamp = now
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .split('.')
      .first;
  return 'workspace-media-$stamp.easymedia';
}
