import 'attachment_contracts.dart';
import 'contracts.dart';

const mediaArchiveMagic = [
  0x45,
  0x41,
  0x53,
  0x59,
  0x4d,
  0x45,
  0x44,
  0,
]; // EASYMED

final class WorkspaceMediaBackupLimits {
  const WorkspaceMediaBackupLimits({
    this.mediaBytes = maximumMediaBytes,
    this.attachments = maximumAttachments,
  });

  static const maximumMediaBytes = 16 * 1024 * 1024 * 1024;
  static const maximumAttachments = 16384;

  final int mediaBytes;
  final int attachments;

  void validate() {
    if (mediaBytes < 1 ||
        mediaBytes > maximumMediaBytes ||
        attachments < 1 ||
        attachments > maximumAttachments) {
      throw ArgumentError('The media backup limits are out of range.');
    }
  }
}

abstract interface class WorkspaceMediaBackupFile {
  /// Local encrypted file path, available until this handle is closed.
  String get nativePath;
  int get byteLength;
  String get suggestedName;
  Stream<List<int>> openRead();
  Future<void> close();
}

abstract interface class WorkspaceMediaBackupPreview {
  WorkspaceBackupPreview get backup;
  int get expectedRevision;
  List<AttachmentRef> get attachments;
  int get mediaBytes;
  Future<void> close();
}

final class WorkspaceMediaBackupException implements Exception {
  const WorkspaceMediaBackupException(this.message);

  final String message;
  @override
  String toString() => message;
}

final class WorkspaceMediaBackupAuthenticationException implements Exception {
  const WorkspaceMediaBackupAuthenticationException();

  @override
  String toString() => 'The media backup could not be authenticated.';
}
