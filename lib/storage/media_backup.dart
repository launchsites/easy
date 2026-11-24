import 'attachment_store.dart';
import 'src/media_backup_contracts.dart';
import 'src/open_media_backup_web.dart'
    if (dart.library.io) 'src/open_media_backup_native.dart'
    as platform;
import 'workspace_store.dart';

export 'src/media_backup_contracts.dart'
    show
        WorkspaceMediaBackupAuthenticationException,
        WorkspaceMediaBackupException,
        WorkspaceMediaBackupFile,
        WorkspaceMediaBackupLimits,
        WorkspaceMediaBackupPreview;
export 'src/media_staging_contracts.dart'
    show MediaStagingCleanupPreview, MediaStagingCleanupResult;

/// The native format holds a logical workspace backup and original media.
bool isWorkspaceMediaBackup(List<int> leadingBytes) {
  if (leadingBytes.length < mediaArchiveMagic.length) return false;
  for (var index = 0; index < mediaArchiveMagic.length; index++) {
    if (leadingBytes[index] != mediaArchiveMagic[index]) return false;
  }
  return true;
}

Future<WorkspaceMediaBackupFile> createWorkspaceMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required String passphrase,
  WorkspaceMediaBackupLimits limits = const WorkspaceMediaBackupLimits(),
  String? scratchDirectory,
}) => platform.createMediaBackup(
  store: store,
  attachments: attachments,
  passphrase: passphrase,
  limits: limits,
  scratchDirectory: scratchDirectory,
);

Future<WorkspaceMediaBackupPreview> previewWorkspaceMediaBackup({
  required WorkspaceStore store,
  required Stream<List<int>> source,
  required String passphrase,
  WorkspaceMediaBackupLimits limits = const WorkspaceMediaBackupLimits(),
  String? scratchDirectory,
}) => platform.previewMediaBackup(
  store: store,
  source: source,
  passphrase: passphrase,
  limits: limits,
  scratchDirectory: scratchDirectory,
);

Future<WorkspaceRevision> restoreWorkspaceMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required WorkspaceMediaBackupPreview preview,
}) => platform.restoreMediaBackup(
  store: store,
  attachments: attachments,
  preview: preview,
);

Future<MediaStagingCleanupPreview> previewInterruptedBackupFiles({
  String? scratchDirectory,
}) =>
    platform.previewInterruptedBackupFiles(scratchDirectory: scratchDirectory);

Future<MediaStagingCleanupResult> removeInterruptedBackupFiles(
  MediaStagingCleanupPreview preview, {
  String? scratchDirectory,
}) => platform.removeInterruptedBackupFiles(
  preview,
  scratchDirectory: scratchDirectory,
);
