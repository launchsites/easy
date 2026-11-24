import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sync_change.dart';
import 'sync_replica.dart';
import 'sync_security.dart';
import 'sync_wire.dart';

abstract interface class SyncJournal {
  Future<SyncJournalStatus> status();
  Future<SyncRecord?> readRecord(SyncRecordKey key);

  Future<SyncJournalStatus> approveDevice(
    SyncDevicePublicKey device, {
    required int expectedRevision,
    String? pairKeyId,
  });

  Future<SyncJournalStatus> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  });

  Future<SyncJournalDraft> draftChange({
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
  });

  Future<SyncJournalStatus> commitLocal(
    SignedSyncChange change, {
    required int expectedRevision,
  });

  Future<SyncJournalStatus> commitLocalBatch(
    List<SignedSyncChange> changes, {
    required int expectedRevision,
  });

  /// Holds one reviewed journal revision during a short external workspace
  /// commit. The caller must release the lease even if that write fails.
  Future<String> holdRevision(int expectedRevision);
  Future<void> releaseRevision(String lease);

  Future<SyncJournalExport?> exportChanges({
    required String recipientId,
    required SyncPairKey pairKey,
    SyncVersionVector known = const SyncVersionVector.empty(),
  });

  Future<SyncImportPreview> previewImport({
    required Uint8List envelope,
    required String senderId,
    required SyncPairKey pairKey,
  });

  Future<SyncJournalStatus> commitImport(
    SyncImportPreview preview, {
    bool approveDestructiveChanges = false,
    bool approveConflicts = false,
  });

  Future<void> close();
}

/// A key for one local journal. Keep the exported bytes in the host key store.
final class SyncJournalKey {
  SyncJournalKey._(this._secret);

  factory SyncJournalKey.generate() =>
      SyncJournalKey._(SecretKeyData.random(length: 32));

  factory SyncJournalKey.fromBytes(List<int> bytes) => SyncJournalKey._(
    SecretKeyData(
      syncFixedBytes(bytes, 32, 'journal key'),
      overwriteWhenDestroyed: true,
    ),
  );

  final SecretKeyData _secret;

  Uint8List copyBytesForSecureStorage() => Uint8List.fromList(_secret.bytes);

  void destroy() => _secret.destroy();
}

final class SyncJournalStatus {
  const SyncJournalStatus({
    required this.workspaceId,
    required this.localDeviceId,
    required this.approvedDeviceIds,
    required this.revision,
    required this.watermark,
    required this.changes,
    this.approvedPairKeyIds = const {},
  });

  final SyncWorkspaceId workspaceId;
  final String localDeviceId;
  final Set<String> approvedDeviceIds;
  final int revision;
  final SyncVersionVector watermark;
  final int changes;
  final Map<String, String> approvedPairKeyIds;
}

final class SyncJournalDraft {
  const SyncJournalDraft(this.expectedRevision, this.change);

  final int expectedRevision;
  final SyncChange change;
}

final class SyncJournalExport {
  const SyncJournalExport({
    required this.bytes,
    required this.changeCount,
    required this.hasMore,
  });

  final Uint8List bytes;
  final int changeCount;
  final bool hasMore;
}

/// An immutable, session-scoped view of a specific prospective import.
abstract interface class SyncImportPreview {
  int get expectedRevision;
  String get senderId;
  int get changeCount;
  int get duplicateCount;
  bool get hasDestructiveChanges;
  bool get hasConflicts;
  SyncVersionVector get missing;
  List<SyncRecordChange> get records;
}

final class SyncJournalException implements Exception {
  const SyncJournalException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class SyncJournalRevisionConflict implements Exception {
  const SyncJournalRevisionConflict(this.expected, this.actual);

  final int expected;
  final int actual;

  @override
  String toString() => 'The sync journal changed after this review.';
}

enum SyncImportApproval { destructiveChanges, conflicts }

final class SyncImportApprovalRequired implements Exception {
  const SyncImportApprovalRequired(this.approval);

  final SyncImportApproval approval;

  @override
  String toString() =>
      'Review the import changes and approve them to continue.';
}
