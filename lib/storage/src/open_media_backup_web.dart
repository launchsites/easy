import 'attachment_contracts.dart';
import 'contracts.dart';
import 'media_backup_contracts.dart';
import 'media_staging_contracts.dart';

const _unavailable = WorkspaceMediaBackupException(
  'Backups with media need native file storage.',
);

Future<WorkspaceMediaBackupFile> createMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required String passphrase,
  required WorkspaceMediaBackupLimits limits,
  required String? scratchDirectory,
}) async => throw _unavailable;

Future<WorkspaceMediaBackupPreview> previewMediaBackup({
  required WorkspaceStore store,
  required Stream<List<int>> source,
  required String passphrase,
  required WorkspaceMediaBackupLimits limits,
  required String? scratchDirectory,
}) async => throw _unavailable;

Future<WorkspaceRevision> restoreMediaBackup({
  required WorkspaceStore store,
  required AttachmentStore attachments,
  required WorkspaceMediaBackupPreview preview,
}) async => throw _unavailable;

Future<MediaStagingCleanupPreview> previewInterruptedBackupFiles({
  String? scratchDirectory,
}) async => throw _unavailable;

Future<MediaStagingCleanupResult> removeInterruptedBackupFiles(
  MediaStagingCleanupPreview preview, {
  String? scratchDirectory,
}) async => throw _unavailable;
