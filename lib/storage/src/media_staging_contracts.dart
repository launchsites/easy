/// A bounded review of files left by interrupted local media operations.
abstract interface class MediaStagingCleanupPreview {
  int get fileCount;
  int get stageCount;
  int get bytes;
  bool get hasMore;
}

final class MediaStagingCleanupResult {
  const MediaStagingCleanupResult({
    required this.removedStages,
    required this.removedBytes,
    required this.skippedStages,
  });

  final int removedStages;
  final int removedBytes;
  final int skippedStages;
}

/// Native attachment stores can review app-owned staging without altering
/// any published content directory.
abstract interface class InterruptedAttachmentImports {
  Future<MediaStagingCleanupPreview> previewInterruptedImports();
  Future<MediaStagingCleanupResult> removeInterruptedImports(
    MediaStagingCleanupPreview preview,
  );
}
