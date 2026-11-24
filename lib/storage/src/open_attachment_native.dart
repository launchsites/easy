import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_contracts.dart';
import 'attachment_media.dart';

const _payloadName = 'payload';
const _blockBytes = 64 * 1024;

Future<AttachmentStore> openDefaultAttachmentStore({
  String? directoryPath,
  required AttachmentLimits limits,
}) async {
  final root = Directory(
    directoryPath ??
        (await getApplicationSupportDirectory()).uri
            .resolve('easy/attachments')
            .toFilePath(),
  );
  try {
    await root.create(recursive: true);
    return _FileAttachmentStore(await root.resolveSymbolicLinks(), limits);
  } on FileSystemException {
    throw const AttachmentStoreException(
      'The attachment folder could not be opened.',
    );
  }
}

class _FileAttachmentStore implements AttachmentStore {
  _FileAttachmentStore(this._root, this._limits);

  final String _root;
  final AttachmentLimits _limits;
  final _pending = <Future<void>>{};
  bool _closed = false;

  Future<T> _submit<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future.error(
        const AttachmentStoreException('The attachment store is closed.'),
      );
    }
    final result = Future<T>.sync(operation);
    late final Future<void> completion;
    void release() => _pending.remove(completion);

    completion = result.then<void>(
      (_) => release(),
      onError: (Object _) => release(),
    );
    _pending.add(completion);
    return result;
  }

  @override
  Future<AttachmentRef> putBytes(
    Uint8List bytes, {
    required AttachmentKind kind,
    String? declaredMimeType,
  }) => _submit(() async {
    final root = _root;
    final limits = _limits;
    final size = bytes.length;
    _checkLength(size, limits.forKind(kind));
    _checkMimeLength(declaredMimeType);
    final data = TransferableTypedData.fromList([bytes]);
    return _importInWorker(root, limits, data, kind, declaredMimeType, size);
  });

  @override
  Future<AttachmentRef> putStream(
    Stream<List<int>> source, {
    required AttachmentKind kind,
    String? declaredMimeType,
    int? expectedLength,
  }) => _submit(
    () => _ingest(
      _root,
      _limits,
      source,
      kind,
      declaredMimeType,
      expectedLength,
      runInWorker: true,
    ),
  );

  @override
  Future<StoredAttachment> read(String id) => _submit(() async {
    validateAttachmentId(id);
    return _readInWorker(_root, id, _limits);
  });

  @override
  Future<void> close() async {
    _closed = true;
    await Future.wait(_pending.toList());
  }
}

// Keep these closures outside the store and stream scopes so an isolate
// transfers only immutable limits, metadata and the requested file bytes.
Future<AttachmentRef> _importInWorker(
  String root,
  AttachmentLimits limits,
  TransferableTypedData data,
  AttachmentKind kind,
  String? declaredMimeType,
  int size,
) => Isolate.run(
  () => _ingest(
    root,
    limits,
    Stream.value(data.materialize().asUint8List()),
    kind,
    declaredMimeType,
    size,
    runInWorker: false,
  ),
  debugName: 'easy-attachment-import',
);

Future<StoredAttachment> _readInWorker(
  String root,
  String id,
  AttachmentLimits limits,
) => Isolate.run(() {
  final stored = _readStored(root, id, limits, includeBytes: true);
  return StoredAttachment(ref: stored.ref, bytes: stored.bytes!);
}, debugName: 'easy-attachment-read');

Future<AttachmentRef> _publishInWorker(
  String root,
  AttachmentLimits limits,
  String stagedPath,
  String id,
  int size,
  AttachmentKind kind,
  String? declaredMimeType,
) => Isolate.run(
  () => _publish(root, limits, stagedPath, id, size, kind, declaredMimeType),
  debugName: 'easy-attachment-publish',
);

Future<AttachmentRef> _ingest(
  String root,
  AttachmentLimits limits,
  Stream<List<int>> source,
  AttachmentKind kind,
  String? declaredMimeType,
  int? expectedLength, {
  required bool runInWorker,
}) async {
  final limit = limits.forKind(kind);
  _checkMimeLength(declaredMimeType);
  if (expectedLength != null) _checkLength(expectedLength, limit);
  final Directory stage;
  try {
    // The staging directory is private and on the destination filesystem.
    stage = await Directory(root).createTemp('.incoming-');
  } on FileSystemException {
    throw const AttachmentStoreException('The attachment could not be staged.');
  }
  final payload = File.fromUri(stage.uri.resolve(_payloadName));
  final digest = _DigestSink();
  final inputDigest = sha256.startChunkedConversion(digest);
  var size = 0;
  try {
    final handle = await payload.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in source) {
        if (chunk.length > limit - size ||
            expectedLength != null && chunk.length > expectedLength - size) {
          throw const FormatException(
            'The attachment exceeds its declared or supported size.',
          );
        }
        for (var start = 0; start < chunk.length; start += _blockBytes) {
          final end = min(start + _blockBytes, chunk.length);
          final data = _copyBytes(chunk, start, end);
          inputDigest.add(data);
          await handle.writeFrom(data);
        }
        size += chunk.length;
      }
      _checkLength(size, limit);
      if (expectedLength != null && expectedLength != size) {
        throw const FormatException(
          'The attachment size changed while importing.',
        );
      }
      await handle.flush();
    } finally {
      await handle.close();
      inputDigest.close();
    }
    final id = digest.result.toString();
    final stagedPath = stage.path;
    return runInWorker
        ? await _publishInWorker(
            root,
            limits,
            stagedPath,
            id,
            size,
            kind,
            declaredMimeType,
          )
        : _publish(root, limits, stagedPath, id, size, kind, declaredMimeType);
  } on FileSystemException {
    throw const AttachmentStoreException('The attachment could not be saved.');
  } finally {
    // A successful rename removes this unique staging path. Existing content
    // is never deleted when importing a duplicate or rejecting a file.
    if (await stage.exists()) await stage.delete(recursive: true);
  }
}

Uint8List _copyBytes(List<int> chunk, int start, int end) {
  final copy = Uint8List(end - start);
  if (chunk is Uint8List) {
    return copy..setRange(0, end - start, chunk, start);
  }
  for (var index = start; index < end; index++) {
    final value = chunk[index];
    if (value < 0 || value > 255) {
      throw const FormatException('Invalid attachment stream bytes.');
    }
    copy[index - start] = value;
  }
  return copy;
}

AttachmentRef _publish(
  String root,
  AttachmentLimits limits,
  String stagePath,
  String id,
  int size,
  AttachmentKind kind,
  String? declaredMimeType,
) {
  final stage = Directory(stagePath);
  final format = inspectAttachment(
    File.fromUri(stage.uri.resolve(_payloadName)),
    size,
  );
  checkAttachmentType(format, kind, declaredMimeType);
  final target = _digestDirectory(root, id);
  try {
    // Directory rename is atomic, and a populated digest directory cannot
    // be replaced. Waiters racing for the same digest can verify and reuse it.
    stage.renameSync(target.path);
  } on FileSystemException {
    if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      rethrow;
    }
    final existing = _readStored(root, id, limits, includeBytes: false).ref;
    if (existing.format != format || existing.byteLength != size) {
      throw const AttachmentStoreException(
        'Stored attachment metadata changed.',
      );
    }
  }
  return AttachmentRef(id: id, format: format, byteLength: size);
}

({AttachmentRef ref, Uint8List? bytes}) _readStored(
  String root,
  String id,
  AttachmentLimits limits, {
  required bool includeBytes,
}) {
  final directory = _digestDirectory(root, id);
  final file = File.fromUri(directory.uri.resolve(_payloadName));
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const AttachmentStoreException(
      'The attachment is missing or invalid.',
    );
  }
  try {
    final handle = file.openSync();
    try {
      final length = handle.lengthSync();
      _checkLength(length, max(limits.maxPhotoBytes, limits.maxAudioBytes));
      final format = inspectAttachmentHandle(handle, length);
      _checkLength(length, limits.forKind(format.kind));
      handle.setPositionSync(0);
      final capture = includeBytes ? Uint8List(length) : null;
      final digest = _DigestSink();
      final input = sha256.startChunkedConversion(digest);
      var offset = 0;
      while (offset < length) {
        final chunk = handle.readSync(min(length - offset, _blockBytes));
        if (chunk.isEmpty) break;
        capture?.setRange(offset, offset + chunk.length, chunk);
        input.add(chunk);
        offset += chunk.length;
      }
      input.close();
      if (offset != length ||
          handle.readByteSync() != -1 ||
          digest.result.toString() != id) {
        throw const AttachmentStoreException(
          'The attachment failed its integrity check.',
        );
      }
      return (
        ref: AttachmentRef(id: id, format: format, byteLength: length),
        bytes: capture,
      );
    } finally {
      handle.closeSync();
    }
  } on FormatException {
    throw const AttachmentStoreException(
      'The stored attachment has invalid media data.',
    );
  } on FileSystemException {
    throw const AttachmentStoreException('The attachment could not be read.');
  }
}

Directory _digestDirectory(String root, String id) {
  validateAttachmentId(id);
  // Check the directory itself on reads. A trailing slash would force the
  // OS to resolve a symlink before the link check.
  return Directory.fromUri(Directory(root).uri.resolve(id));
}

void _checkLength(int length, int limit) {
  if (length <= 0 || length > limit) {
    throw const FormatException('The attachment is empty or too large.');
  }
}

void _checkMimeLength(String? mime) {
  if (mime != null && mime.length > 512) {
    throw const FormatException('Invalid media type.');
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest result;

  @override
  void add(Digest data) => result = data;

  @override
  void close() {}
}
