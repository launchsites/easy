import 'dart:typed_data';

enum AttachmentKind { photo, audio }

enum AttachmentFormat {
  jpeg(AttachmentKind.photo, 'image/jpeg', 'jpg'),
  png(AttachmentKind.photo, 'image/png', 'png'),
  heic(AttachmentKind.photo, 'image/heic', 'heic'),
  wav(AttachmentKind.audio, 'audio/wav', 'wav'),
  m4a(AttachmentKind.audio, 'audio/mp4', 'm4a');

  const AttachmentFormat(this.kind, this.mimeType, this.extension);

  final AttachmentKind kind;
  final String mimeType;
  final String extension;
}

final class AttachmentLimits {
  const AttachmentLimits({
    this.maxPhotoBytes = photoByteLimit,
    this.maxAudioBytes = audioByteLimit,
  });

  static const photoByteLimit = 25 * 1024 * 1024;
  static const audioByteLimit = 64 * 1024 * 1024;

  final int maxPhotoBytes;
  final int maxAudioBytes;

  int forKind(AttachmentKind kind) => switch (kind) {
    AttachmentKind.photo => maxPhotoBytes,
    AttachmentKind.audio => maxAudioBytes,
  };

  void validate() {
    if (maxPhotoBytes <= 0 ||
        maxPhotoBytes > photoByteLimit ||
        maxAudioBytes <= 0 ||
        maxAudioBytes > audioByteLimit) {
      throw ArgumentError('Attachment limits exceed the supported byte range.');
    }
  }
}

/// References app-managed content by its lowercase SHA-256 digest.
final class AttachmentRef {
  AttachmentRef({
    required this.id,
    required this.format,
    required this.byteLength,
  }) {
    validateAttachmentId(id);
    if (byteLength <= 0 ||
        byteLength > const AttachmentLimits().forKind(format.kind)) {
      throw const FormatException('Invalid attachment byte length.');
    }
  }

  factory AttachmentRef.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final encodedFormat = json['format'];
    final bytes = json['byteLength'];
    final claimedMime = json['mimeType'];
    if (id is! String || encodedFormat is! String || bytes is! int) {
      throw const FormatException('Invalid attachment reference.');
    }
    final format = AttachmentFormat.values
        .where((format) => format.name == encodedFormat)
        .firstOrNull;
    if (format == null ||
        (claimedMime != null && claimedMime != format.mimeType)) {
      throw const FormatException('Invalid attachment format.');
    }
    return AttachmentRef(id: id, format: format, byteLength: bytes);
  }

  final String id;
  final AttachmentFormat format;
  final int byteLength;

  String get mimeType => format.mimeType;

  Map<String, Object> toJson() => {
    'id': id,
    'format': format.name,
    'mimeType': mimeType,
    'byteLength': byteLength,
  };
}

final class StoredAttachment {
  const StoredAttachment({required this.ref, required this.bytes});

  final AttachmentRef ref;
  final Uint8List bytes;
}

final class AttachmentStoreException implements Exception {
  const AttachmentStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class AttachmentStore {
  Future<AttachmentRef> putBytes(
    Uint8List bytes, {
    required AttachmentKind kind,
    String? declaredMimeType,
  });

  /// Consumes a selected or captured file stream with bounded staging.
  Future<AttachmentRef> putStream(
    Stream<List<int>> source, {
    required AttachmentKind kind,
    String? declaredMimeType,
    int? expectedLength,
    String? expectedContentId,
  });

  /// Reads by content ID and verifies the full payload digest before returning.
  Future<StoredAttachment> read(String id);

  Future<void> close();
}

abstract interface class StreamingAttachmentStore implements AttachmentStore {
  /// The supplied metadata and digest are checked before successful stream
  /// completion. A consumer that cancels must discard its partial copy.
  Stream<Uint8List> readStream(AttachmentRef expected);
}

final _validId = RegExp(r'^[a-f0-9]{64}$');

void validateAttachmentId(String id) {
  if (id.length != 64 || !_validId.hasMatch(id)) {
    throw const FormatException('Invalid attachment ID.');
  }
}
