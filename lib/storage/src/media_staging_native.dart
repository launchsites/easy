import 'dart:convert';
import 'dart:io';

import 'attachment_contracts.dart';
import 'media_staging_contracts.dart';

enum MediaStageKind { imports, backups }

const _stagePrefix = '.easy-stage-';
const _discardPrefix = '.easy-discarded-stage-';
const _leaseName = 'lease';
const _markerName = 'ready';
const _contentName = 'content';
const _maxReviewedStages = 32;
const _maxDirectoryEntries = 50000;
const _maxMarkerBytes = 192;
const _maxBackupStageBytes = 17 * 1024 * 1024 * 1024;
final _name = RegExp(
  r'^\.easy-(discarded-)?stage-(imports|backups)-([1-9][0-9]{0,9})-([A-Za-z0-9_-]{1,72})$',
);
final _backupName = RegExp(r'^workspace-media-[0-9T-]{8,32}\.easymedia$');
final _digestName = RegExp(r'^[a-f0-9]{64}$');

/// A leased parent survives publishing its content directory. A cleaner never
/// needs to open a canonical attachment directory or its payload.
final class MediaFileStage {
  MediaFileStage._(this.directory, this.content, this._lease);

  static Future<MediaFileStage> create(
    Directory root,
    MediaStageKind kind,
  ) async {
    final directory = await root.createTemp('$_stagePrefix${kind.name}-$pid-');
    RandomAccessFile? lease;
    try {
      lease = await _file(directory, _leaseName).open(mode: FileMode.append);
      await lease.lock();
      final content = await _directory(directory, _contentName).create();
      await _file(
        directory,
        _markerName,
      ).writeAsString(_marker(_basename(directory.uri)), flush: true);
      return MediaFileStage._(directory, content, lease);
    } catch (_) {
      await lease?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  final Directory directory;
  final Directory content;
  final RandomAccessFile _lease;
  Future<void>? _closed;

  Future<void> close() => _closed ??= _close();

  Future<void> _close() async {
    try {
      await _lease.close();
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

Future<MediaStagingCleanupPreview> previewMediaStages(
  Directory root,
  MediaStageKind kind,
) async {
  final resolved = await _resolveRoot(root);
  final candidates = <_StageCandidate>[];
  var scanned = 0;
  var hasMore = false;
  if (resolved != null) {
    await for (final entry in resolved.list(followLinks: false)) {
      if (++scanned > _maxDirectoryEntries) {
        hasMore = true;
        break;
      }
      if (entry is! Directory) continue;
      final basename = _basename(entry.uri);
      final parts = _parts(basename, kind);
      if (parts == null) continue;
      final candidate = await _inspect(entry, parts);
      if (candidate == null) continue;
      if (candidates.length >= _maxReviewedStages) {
        hasMore = true;
        break;
      }
      candidates.add(candidate);
    }
  }
  return _CleanupPreview(resolved?.path, kind, candidates, hasMore);
}

Future<MediaStagingCleanupResult> removeMediaStages(
  Directory root,
  MediaStageKind kind,
  MediaStagingCleanupPreview preview,
) async {
  final resolved = await _resolveRoot(root);
  if (preview is! _CleanupPreview ||
      preview.kind != kind ||
      preview.root != resolved?.path) {
    throw const AttachmentStoreException(
      'Review the temporary files in this workspace first.',
    );
  }
  var removed = 0;
  var bytes = 0;
  var skipped = 0;
  if (resolved != null) {
    for (final expected in preview.candidates) {
      final named = _directory(resolved, expected.name);
      try {
        final type = await _type(named.path);
        if (type == FileSystemEntityType.notFound) continue;
        if (!_isDirectory(type)) {
          skipped++;
          continue;
        }
        final parts = _parts(expected.name, kind);
        final current = parts == null ? null : await _inspect(named, parts);
        if (current == null || current.fingerprint != expected.fingerprint) {
          skipped++;
          continue;
        }
        final tomb = parts!.discarded
            ? named
            : await named.rename(
                _directory(resolved, '$_discardPrefix${parts.suffix}').path,
              );
        await tomb.delete(recursive: true);
        removed++;
        bytes += current.bytes;
      } on FileSystemException {
        skipped++;
      }
    }
  }
  return MediaStagingCleanupResult(
    removedStages: removed,
    removedBytes: bytes,
    skippedStages: skipped,
  );
}

typedef _StageParts = ({MediaStageKind kind, String suffix, bool discarded});

_StageParts? _parts(String name, MediaStageKind kind) {
  final match = _name.firstMatch(name);
  if (match == null || match.group(2) != kind.name) return null;
  final discarded = match.group(1) != null;
  // File locks on POSIX belong to the process. A second descriptor in this
  // process cannot test its own leases and can release an existing lock.
  if (!discarded && match.group(3) == '$pid') return null;
  return (
    kind: kind,
    suffix: '${match.group(2)}-${match.group(3)}-${match.group(4)}',
    discarded: discarded,
  );
}

Future<_StageCandidate?> _inspect(
  Directory directory,
  _StageParts parts,
) async {
  RandomAccessFile? lease;
  try {
    if (!_isDirectory(await _type(directory.path))) return null;
    if (!parts.discarded) {
      if (await _type(_file(directory, _markerName).path) !=
              FileSystemEntityType.file ||
          await _type(_file(directory, _leaseName).path) !=
              FileSystemEntityType.file) {
        return null;
      }
      lease = await _file(directory, _leaseName).open(mode: FileMode.append);
      await lease.lock();
      if (!await _validMarker(directory, '$_stagePrefix${parts.suffix}')) {
        return null;
      }
    }
    return await _profile(directory, parts.kind);
  } on FileSystemException {
    // Active leases and paths that move during the review are left alone.
    return null;
  } finally {
    await lease?.close();
  }
}

Future<bool> _validMarker(Directory directory, String sourceName) async {
  final marker = _file(directory, _markerName);
  if (await _type(marker.path) != FileSystemEntityType.file) return false;
  final file = await marker.open();
  try {
    final bytes = await file.read(_maxMarkerBytes + 1);
    return bytes.length <= _maxMarkerBytes &&
        utf8.decode(bytes, allowMalformed: true) == _marker(sourceName);
  } finally {
    await file.close();
  }
}

Future<_StageCandidate?> _profile(
  Directory directory,
  MediaStageKind kind,
) async {
  final fingerprint = <String>[];
  var files = 0;
  var total = 0;
  var entries = 0;
  await for (final entry in directory.list(followLinks: false)) {
    if (++entries > 3) return null;
    switch (_basename(entry.uri)) {
      case _markerName || _leaseName:
        if (entry is! File) return null;
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size > _maxMarkerBytes) {
          return null;
        }
        fingerprint.add(_stamp(entry, stat));
      case _contentName:
        if (entry is! Directory) return null;
        await for (final content in entry.list(followLinks: false)) {
          if (++files > 3 || content is! File) return null;
          if (!_validContentName(_basename(content.uri), kind)) return null;
          final stat = await content.stat();
          if (stat.type != FileSystemEntityType.file) return null;
          total += stat.size;
          if (total > _maxBackupStageBytes) return null;
          fingerprint.add('content/${_stamp(content, stat)}');
        }
      default:
        return null;
    }
  }
  return _StageCandidate(
    name: _basename(directory.uri),
    fingerprint: (fingerprint..sort()).join('\n'),
    bytes: total,
    files: files,
  );
}

bool _validContentName(String name, MediaStageKind kind) => switch (kind) {
  MediaStageKind.imports => name == 'payload',
  MediaStageKind.backups =>
    name == 'source' ||
        _digestName.hasMatch(name) ||
        _backupName.hasMatch(name),
};

String _stamp(FileSystemEntity entry, FileStat stat) =>
    '${_basename(entry.uri)}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';

String _marker(String basename) => 'Easy media stage 1\n$basename\n';

String _basename(Uri path) {
  final segments = path.pathSegments;
  return segments.last.isEmpty ? segments[segments.length - 2] : segments.last;
}

Future<Directory?> _resolveRoot(Directory root) async =>
    await root.exists() ? Directory(await root.resolveSymbolicLinks()) : null;

Future<FileSystemEntityType> _type(String path) =>
    FileSystemEntity.type(path, followLinks: false);

bool _isDirectory(FileSystemEntityType type) =>
    type == FileSystemEntityType.directory;

Directory _directory(Directory root, String name) =>
    Directory.fromUri(root.uri.resolve(name));

File _file(Directory root, String name) => File.fromUri(root.uri.resolve(name));

final class _StageCandidate {
  const _StageCandidate({
    required this.name,
    required this.fingerprint,
    required this.bytes,
    required this.files,
  });

  final String name;
  final String fingerprint;
  final int bytes;
  final int files;
}

final class _CleanupPreview implements MediaStagingCleanupPreview {
  _CleanupPreview(
    this.root,
    this.kind,
    List<_StageCandidate> candidates,
    this.hasMore,
  ) : candidates = List.unmodifiable(candidates);

  final String? root;
  final MediaStageKind kind;
  final List<_StageCandidate> candidates;

  @override
  final bool hasMore;

  @override
  int get bytes => candidates.fold(0, (total, value) => total + value.bytes);

  @override
  int get fileCount =>
      candidates.fold(0, (total, value) => total + value.files);

  @override
  int get stageCount => candidates.length;
}
