import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'sync_credentials.dart';
import 'sync_journal.dart';
import 'sync_pairing.dart';
import 'src/sync_wire.dart' show maxLocalSyncBatchChanges;

export 'sync_credentials.dart';
export 'sync_journal.dart';
export 'sync_pairing.dart';
export 'sync_password_vault.dart';

typedef ManualSyncLocalRecord = ({
  SyncRecordKey key,
  Map<String, Object?> fields,
});

/// Explicit manual pairing and encrypted bundle exchange. This session does
/// not advertise, listen, upload or project changes into the live workspace.
final class ManualSyncWorkspace {
  ManualSyncWorkspace._(
    this.workspaceId,
    this._identity,
    this._credentials,
    this._journal,
  );

  /// Defines a new local journal for an explicitly chosen workspace. Joining
  /// an approved invitation can use its workspace ID without importing data.
  static Future<ManualSyncWorkspace> create({
    required SyncDeviceCredentials credentials,
    SyncWorkspaceId? workspaceId,
    String? databasePath,
  }) => _open(
    credentials: credentials,
    workspaceId: workspaceId ?? SyncWorkspaceId.generate(),
    databasePath: databasePath,
    initialize: true,
  );

  /// Loads the configured keys and local journal. Missing credentials do not
  /// create a new device or replace an inaccessible journal.
  static Future<ManualSyncWorkspace> open({
    required SyncDeviceCredentials credentials,
    required SyncWorkspaceId workspaceId,
    String? databasePath,
  }) => _open(
    credentials: credentials,
    workspaceId: workspaceId,
    databasePath: databasePath,
    initialize: false,
  );

  static Future<ManualSyncWorkspace> _open({
    required SyncDeviceCredentials credentials,
    required SyncWorkspaceId workspaceId,
    required String? databasePath,
    required bool initialize,
  }) async {
    final savedIdentity = await credentials.loadIdentity();
    if (savedIdentity == null && !initialize) {
      throw const SyncVaultException(
        'This workspace needs its existing device key.',
      );
    }
    final identity = savedIdentity ?? await credentials.createIdentity();
    try {
      final existingKey = await credentials.loadJournalKey(workspaceId);
      if (existingKey == null && !initialize) {
        throw const SyncVaultException(
          'This workspace needs its existing journal key.',
        );
      }
      final key =
          existingKey ?? await credentials.createJournalKey(workspaceId);
      try {
        final journal = await openSyncJournal(
          workspaceId: workspaceId,
          localDevicePublicKey: identity.publicKey,
          journalKey: key,
          databasePath: databasePath,
          createIfMissing: initialize,
        );
        if (journal == null) {
          throw const SyncJournalException(
            'Manual sync needs a native workspace.',
          );
        }
        return ManualSyncWorkspace._(
          workspaceId,
          identity,
          credentials,
          journal,
        );
      } finally {
        key.destroy();
      }
    } catch (_) {
      identity.destroy();
      rethrow;
    }
  }

  final SyncWorkspaceId workspaceId;
  final SyncDeviceIdentity _identity;
  final SyncDeviceCredentials _credentials;
  final SyncJournal _journal;
  final _session = Object();
  final _committedImports = Expando<SyncJournalStatus>();
  Future<void>? _workspaceWrite;
  var _closed = false;

  SyncDevicePublicKey get device => _identity.publicKey;

  Future<SyncJournalStatus> status() => _journal.status();

  Future<SyncRecord?> readRecord(SyncRecordKey record) =>
      _journal.readRecord(record);

  Future<SyncPairingInvitation> createInvitation() async {
    _ensureOpen();
    return SyncPairingInvitation.create(
      workspaceId: workspaceId,
      identity: _identity,
    );
  }

  Future<SyncPairingResponse> respond(String invitation) async {
    _ensureOpen();
    final offer = await inspectSyncPairingInvitation(invitation);
    if (offer.workspaceId != workspaceId) {
      throw const SyncPairedWorkspaceException(
        'This invitation belongs to another workspace.',
      );
    }
    _ensureOpen();
    return respondToSyncPairingInvitation(
      invitation: invitation,
      identity: _identity,
    );
  }

  Future<SyncJournalStatus> approvePair(
    PairedSyncDevice paired, {
    required int expectedRevision,
  }) async {
    _ensureOpen();
    if (paired.workspaceId != workspaceId ||
        paired.localDeviceId != device.fingerprint) {
      throw const SyncPairedWorkspaceException(
        'This approval belongs to another device or workspace.',
      );
    }
    final peer = paired.publicKey;
    return paired.persistWith((key) async {
      final state = await _journal.status();
      if (state.approvedPairKeyIds[peer.fingerprint] == key.keyId) return state;
      if (state.revision != expectedRevision) {
        throw SyncJournalRevisionConflict(expectedRevision, state.revision);
      }
      if (state.approvedDeviceIds.contains(peer.fingerprint)) {
        throw const SyncTrustException(
          'Revoke the earlier pairing before connecting this device again.',
        );
      }
      final keyId = await _credentials.rememberPairKey(
        workspace: workspaceId,
        deviceId: peer.fingerprint,
        key: key,
      );
      return _journal.approveDevice(
        peer,
        expectedRevision: expectedRevision,
        pairKeyId: keyId,
      );
    });
  }

  Future<SyncJournalStatus> writeLocalChange({
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
    int? expectedRevision,
  }) async {
    _ensureOpen();
    final draft = await _journal.draftChange(
      record: record,
      kind: kind,
      fields: fields,
    );
    if (expectedRevision != null &&
        expectedRevision != draft.expectedRevision) {
      throw SyncJournalRevisionConflict(
        expectedRevision,
        draft.expectedRevision,
      );
    }
    final signed = await _identity.sign(draft.change);
    return _journal.commitLocal(
      signed,
      expectedRevision: draft.expectedRevision,
    );
  }

  /// Commits the explicitly selected local patches as one journal entry.
  Future<SyncJournalStatus> writeLocalRecords({
    required List<ManualSyncLocalRecord> records,
    required int expectedRevision,
    Future<void> Function()? verifyWorkspace,
  }) async {
    _ensureOpen();
    if (records.isEmpty ||
        records.length > maxLocalSyncBatchChanges ||
        records.map((record) => record.key).toSet().length != records.length) {
      throw const SyncJournalException(
        'Choose a smaller set of distinct sync records.',
      );
    }
    final saved = await status();
    if (saved.revision != expectedRevision) {
      throw SyncJournalRevisionConflict(expectedRevision, saved.revision);
    }
    final author = device.fingerprint;
    var watermark = saved.watermark;
    final signed = <SignedSyncChange>[];
    var byteCount = 1;
    for (final record in records) {
      final counter = watermark[author] + 1;
      final change = SyncChange(
        workspaceId: workspaceId,
        dot: (deviceId: author, counter: counter),
        context: watermark,
        record: record.key,
        kind: SyncChangeKind.patch,
        fields: record.fields,
      );
      final entry = await _identity.sign(change);
      byteCount += utf8.encode(entry.encode()).length + 1;
      if (byteCount > SyncEnvelopeCodec.maximumPayloadBytes) {
        throw const SyncJournalException(
          'Select fewer records to stage at once.',
        );
      }
      signed.add(entry);
      watermark = SyncVersionVector({...watermark.counters, author: counter});
    }
    await verifyWorkspace?.call();
    _ensureOpen();
    return _journal.commitLocalBatch(
      signed,
      expectedRevision: expectedRevision,
    );
  }

  Future<SyncJournalExport?> exportFor(
    String recipientId, {
    SyncVersionVector known = const SyncVersionVector.empty(),
    String? peerProgress,
  }) async {
    final (keyId, key) = await _openPair(recipientId);
    try {
      final delivered = peerProgress == null
          ? known
          : await const SyncProgressCodec().open(
              token: peerProgress,
              workspace: workspaceId,
              senderId: recipientId,
              recipientId: device.fingerprint,
              key: key,
            );
      final encrypted = await _journal.exportChanges(
        recipientId: recipientId,
        pairKey: key,
        known: delivered,
      );
      await _verifyPair(recipientId, keyId);
      return encrypted;
    } finally {
      key.destroy();
    }
  }

  Future<String> progressFor(String recipientId) async {
    final (keyId, key) = await _openPair(recipientId);
    try {
      final state = await _journal.status();
      final token = await const SyncProgressCodec().seal(
        workspace: workspaceId,
        senderId: device.fingerprint,
        recipientId: recipientId,
        key: key,
        watermark: state.watermark,
      );
      await _verifyPair(recipientId, keyId);
      return token;
    } finally {
      key.destroy();
    }
  }

  Future<SyncImportPreview> previewIncoming({
    required Uint8List bytes,
    required String senderId,
  }) async {
    if (bytes.length > SyncEnvelopeCodec.maximumBytes) {
      throw const FormatException('Invalid sync bundle length.');
    }
    final (keyId, key) = await _openPair(senderId);
    try {
      final preview = await _journal.previewImport(
        envelope: bytes,
        senderId: senderId,
        pairKey: key,
      );
      await _verifyPair(senderId, keyId);
      return preview;
    } finally {
      key.destroy();
    }
  }

  Future<SyncJournalStatus> commitIncoming(
    SyncImportPreview preview, {
    bool approveDestructiveChanges = false,
    bool approveConflicts = false,
  }) async {
    _ensureOpen();
    final committed = await _journal.commitImport(
      preview,
      approveDestructiveChanges: approveDestructiveChanges,
      approveConflicts: approveConflicts,
    );
    _committedImports[preview] = committed;
    return committed;
  }

  void verifyCommittedImport(
    SyncImportPreview preview,
    SyncJournalStatus committed,
  ) {
    _ensureOpen();
    if (!identical(_committedImports[preview], committed)) {
      throw const SyncJournalException(
        'Save the reviewed bundle to this journal first.',
      );
    }
  }

  /// Pins the authenticated journal head while a WorkspaceStore revision CAS
  /// publishes the reviewed projection. A terminated process releases SQLite's
  /// write lock without leaving a durable lease behind.
  Future<T> applyAtRevision<T>(int revision, Future<T> Function() write) async {
    _ensureOpen();
    if (_workspaceWrite != null) {
      throw const SyncJournalException(
        'Another workspace review is being applied.',
      );
    }
    final completion = Completer<void>();
    _workspaceWrite = completion.future;
    try {
      final lease = await _journal.holdRevision(revision);
      try {
        return await write();
      } finally {
        await _journal.releaseRevision(lease);
      }
    } finally {
      _workspaceWrite = null;
      completion.complete();
    }
  }

  Future<SyncRevocationPreview> reviewRevocation(String deviceId) async {
    final current = await _journal.status();
    final keyId = current.approvedPairKeyIds[deviceId];
    if (keyId == null) {
      throw const SyncTrustException('This device has no active pairing.');
    }
    return SyncRevocationPreview._(_session, deviceId, keyId, current.revision);
  }

  /// Revocation removes journal authorization first. A locked vault can delay
  /// deleting the old secret without granting any further bundle access.
  Future<SyncRevocationResult> confirmRevocation(
    SyncRevocationPreview reviewed,
  ) async {
    _verifyReview(reviewed);
    final state = await _journal.revokeDevice(
      reviewed.deviceId,
      expectedRevision: reviewed.expectedRevision,
    );
    final removed = await _removePairKey(reviewed);
    return SyncRevocationResult(state, credentialRemoved: removed);
  }

  Future<bool> retryRevocationCleanup(SyncRevocationPreview reviewed) async {
    _verifyReview(reviewed);
    final state = await _journal.status();
    if (state.approvedPairKeyIds[reviewed.deviceId] == reviewed._keyId) {
      throw const SyncTrustException(
        'Revoke this pairing before removing its key.',
      );
    }
    return _removePairKey(reviewed);
  }

  void _verifyReview(SyncRevocationPreview reviewed) {
    _ensureOpen();
    if (!identical(_session, reviewed._session)) {
      throw const SyncPairedWorkspaceException(
        'Review this device in the current workspace first.',
      );
    }
  }

  Future<bool> _removePairKey(SyncRevocationPreview reviewed) async {
    try {
      await _credentials.forgetPairKey(
        workspace: workspaceId,
        deviceId: reviewed.deviceId,
        keyId: reviewed._keyId,
      );
      return true;
    } on SyncVaultException {
      return false;
    }
  }

  Future<(String, SyncPairKey)> _openPair(String id) async {
    _ensureOpen();
    final state = await _journal.status();
    final keyId = state.approvedPairKeyIds[id];
    if (keyId == null) {
      throw const SyncTrustException('This device has no active pairing.');
    }
    final key = await _credentials.loadPairKey(
      workspace: workspaceId,
      deviceId: id,
      keyId: keyId,
    );
    return (keyId, key);
  }

  Future<void> _verifyPair(String id, String keyId) async {
    if ((await _journal.status()).approvedPairKeyIds[id] != keyId) {
      throw const SyncTrustException('The device pairing changed.');
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const SyncPairedWorkspaceException(
        'The manual sync workspace is closed.',
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _workspaceWrite;
    _identity.destroy();
    await _journal.close();
  }
}

final class SyncRevocationPreview {
  const SyncRevocationPreview._(
    this._session,
    this.deviceId,
    this._keyId,
    this.expectedRevision,
  );

  final Object _session;
  final String deviceId;
  final String _keyId;
  final int expectedRevision;
}

final class SyncRevocationResult {
  const SyncRevocationResult(this.status, {required this.credentialRemoved});

  final SyncJournalStatus status;
  final bool credentialRemoved;
}

final class SyncPairedWorkspaceException implements Exception {
  const SyncPairedWorkspaceException(this.message);

  final String message;
  @override
  String toString() => message;
}
