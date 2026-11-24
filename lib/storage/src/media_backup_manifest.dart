import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_contracts.dart';
import 'contracts.dart';
import 'media_backup_contracts.dart';
import 'snapshot_codec.dart';

const _version = 1;
final _shaPattern = RegExp(r'^[a-f0-9]{64}$');

final class MediaBackupManifest {
  MediaBackupManifest({
    required this.backupLength,
    required this.backupDigest,
    required List<AttachmentRef> attachments,
  }) : attachments = List.unmodifiable(attachments);

  factory MediaBackupManifest.fromSnapshot(
    WorkspaceRevision revision,
    Uint8List backup,
    WorkspaceMediaBackupLimits limits,
  ) => MediaBackupManifest(
    backupLength: backup.length,
    backupDigest: sha256.convert(backup).toString(),
    attachments: snapshotMediaReferences(
      revision.snapshot.workspaceJson,
      limits,
    ),
  );

  factory MediaBackupManifest.decode(
    Uint8List bytes,
    WorkspaceMediaBackupLimits limits,
  ) {
    final text = utf8.decode(bytes);
    final json = jsonObject(
      decodeJson(text, 'media backup manifest'),
      'media backup manifest',
    );
    final backupLength = json['backupBytes'];
    final digest = json['backupSha256'];
    final media = json['attachments'];
    if (json['version'] != _version ||
        backupLength is! int ||
        backupLength < 1 ||
        backupLength > workspaceBackupByteLimit ||
        digest is! String ||
        digest.length != 64 ||
        !_shaPattern.hasMatch(digest) ||
        media is! List ||
        media.length > limits.attachments) {
      throw const FormatException('Invalid media backup manifest.');
    }
    final ordered = _ReferenceSet(limits);
    String? prior;
    for (final raw in media) {
      final ref = AttachmentRef.fromJson(
        jsonObject(raw, 'media backup attachment'),
      );
      if (prior != null && prior.compareTo(ref.id) >= 0) {
        throw const FormatException(
          'Media backup attachments are duplicated or out of order.',
        );
      }
      ordered.add(ref);
      prior = ref.id;
    }
    final manifest = MediaBackupManifest(
      backupLength: backupLength,
      backupDigest: digest,
      attachments: ordered.sorted(),
    );
    if (manifest.encode() != text) {
      throw const FormatException(
        'Unsupported media backup manifest encoding.',
      );
    }
    return manifest;
  }

  final int backupLength;
  final String backupDigest;
  final List<AttachmentRef> attachments;

  int get totalMediaBytes =>
      attachments.fold(0, (count, ref) => count + ref.byteLength);

  String encode() => jsonEncode({
    'version': _version,
    'backupBytes': backupLength,
    'backupSha256': backupDigest,
    'attachments': [for (final attachment in attachments) attachment.toJson()],
  });
}

List<AttachmentRef> snapshotMediaReferences(
  String workspaceJson,
  WorkspaceMediaBackupLimits limits,
) {
  final workspace = jsonObject(
    decodeJson(workspaceJson, 'workspace'),
    'workspace',
  );
  final references = _ReferenceSet(limits);
  void addAll(Object? list, String field, AttachmentKind kind) {
    if (list == null) return;
    if (list is! List) {
      throw const FormatException('Invalid workspace attachment list.');
    }
    for (final entry in list) {
      final metadata = jsonObject(entry, 'workspace record')[field];
      if (metadata == null) continue;
      final reference = AttachmentRef.fromJson(
        jsonObject(metadata, 'workspace attachment'),
      );
      if (reference.format.kind != kind) {
        throw const FormatException('An attachment uses the wrong media type.');
      }
      references.add(reference);
    }
  }

  addAll(workspace['captures'], 'audio', AttachmentKind.audio);
  if (workspace['nutrition'] case final nutrition?) {
    addAll(
      jsonObject(nutrition, 'nutrition')['meals'],
      'photo',
      AttachmentKind.photo,
    );
  }
  return references.sorted();
}

bool sameMediaReference(AttachmentRef a, AttachmentRef b) =>
    a.id == b.id && a.format == b.format && a.byteLength == b.byteLength;

final class _ReferenceSet {
  _ReferenceSet(this._limits);

  final WorkspaceMediaBackupLimits _limits;
  final _byId = <String, AttachmentRef>{};
  var _bytes = 0;

  void add(AttachmentRef reference) {
    final previous = _byId[reference.id];
    if (previous != null) {
      if (!sameMediaReference(previous, reference)) {
        throw const FormatException(
          'Workspace records disagree about a shared attachment.',
        );
      }
      return;
    }
    if (_byId.length >= _limits.attachments ||
        reference.byteLength > _limits.mediaBytes - _bytes) {
      throw const FormatException('Referenced media exceeds the backup limit.');
    }
    _byId[reference.id] = reference;
    _bytes += reference.byteLength;
  }

  List<AttachmentRef> sorted() =>
      _byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}
