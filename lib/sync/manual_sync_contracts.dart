import 'dart:typed_data';

import '../storage/workspace_store.dart';
import 'manual_sync_workspace.dart';

/// The host owns the configured workspace session and any file or clipboard
/// access. Each transfer callback is invoked from an explicit user action.
final class ManualSyncPageHost {
  const ManualSyncPageHost({
    required this.openConfigured,
    required this.enable,
    required this.copyToken,
    required this.pasteToken,
    required this.pickBundle,
    required this.saveBundle,
  });

  final Future<ManualSyncWorkspace?> Function() openConfigured;
  final Future<ManualSyncWorkspace> Function(SyncWorkspaceId? joinWorkspace)
  enable;
  final Future<void> Function(String token) copyToken;
  final Future<String?> Function() pasteToken;
  final Future<Uint8List?> Function() pickBundle;
  final Future<void> Function(Uint8List bytes, String filename) saveBundle;
}

final class ManualSyncTransferCancelled implements Exception {
  const ManualSyncTransferCancelled();
}

/// Verified journal changes can be projected into the separate Easy workspace
/// only after this review. The host applies the selected records with the
/// saved workspace revision, a retry-stable operation ID and recovery point.
abstract interface class ManualSyncProjector {
  Future<ManualSyncProjectionPreview> previewIncoming({
    required ManualSyncWorkspace sync,
    required SyncImportPreview imported,
    required SyncJournalStatus committed,
  });

  Future<WorkspaceRevision> applyIncoming(
    ManualSyncProjectionPreview preview, {
    required Set<SyncRecordKey> selected,
  });
}

final class ManualSyncProjectionPreview {
  ManualSyncProjectionPreview({
    required this.syncWorkspaceId,
    required this.syncRevision,
    required this.expectedWorkspaceRevision,
    required Iterable<ManualSyncProjectionRecord> records,
  }) : records = List.unmodifiable(records);

  final SyncWorkspaceId syncWorkspaceId;
  final int syncRevision;
  final int expectedWorkspaceRevision;
  final List<ManualSyncProjectionRecord> records;
}

enum ManualSyncProjectionAction { add, update, remove, resolveConflict }

final class ManualSyncProjectionRecord {
  const ManualSyncProjectionRecord({
    required this.key,
    required this.title,
    required this.action,
    this.details,
    this.localDetails,
    this.incomingDetails,
  });

  final SyncRecordKey key;
  final String title;
  final ManualSyncProjectionAction action;
  final String? details;
  final String? localDetails;
  final String? incomingDetails;

  bool get selectable => action != ManualSyncProjectionAction.resolveConflict;
}

abstract interface class ManualSyncOutgoing {
  Future<ManualSyncOutgoingPreview> previewOutgoing({
    required ManualSyncWorkspace sync,
    String query = '',
  });

  Future<int> stageOutgoing(
    ManualSyncOutgoingPreview preview, {
    required Set<SyncRecordKey> selected,
  });
}

final class ManualSyncOutgoingPreview {
  ManualSyncOutgoingPreview({
    required this.syncRevision,
    required this.expectedWorkspaceRevision,
    required Iterable<ManualSyncOutgoingRecord> records,
    required this.hasMore,
  }) : records = List.unmodifiable(records);

  final int syncRevision;
  final int expectedWorkspaceRevision;
  final List<ManualSyncOutgoingRecord> records;
  final bool hasMore;
}

final class ManualSyncOutgoingRecord {
  const ManualSyncOutgoingRecord({
    required this.key,
    required this.title,
    required this.details,
  });

  final SyncRecordKey key;
  final String title;
  final String details;
}
