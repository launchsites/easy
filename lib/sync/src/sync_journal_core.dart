import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'sync_change.dart';
import 'sync_journal_storage.dart';
import 'sync_journal_types.dart';
import 'sync_replica.dart';
import 'sync_security.dart';
import 'sync_wire.dart';

final _aes = AesGcm.with256bits();
const _nonceBytes = 12;
const _tagBytes = 16;
const _corrupt = SyncJournalException(
  'The sync journal failed integrity checks.',
);

final class SyncJournalCore implements SyncJournal {
  SyncJournalCore._(this._ledger, this._key, this._local, this._trust)
    : _replica = SyncReplica(_trust);

  static Future<SyncJournalCore> open({
    required SyncLedger ledger,
    required SyncWorkspaceId workspaceId,
    required SyncDevicePublicKey local,
    required Uint8List keyBytes,
    required bool createIfMissing,
  }) async {
    final core = SyncJournalCore._(
      ledger,
      SecretKeyData(keyBytes, overwriteWhenDestroyed: true),
      local,
      SyncTrust(workspaceId, approved: [local]),
    );
    try {
      if (ledger.readHead() == null) {
        if (!createIfMissing) throw _corrupt;
        ledger.initialize(await core._sealHead(0, 0, Uint8List(32)));
      }
      await core._refresh();
      return core;
    } catch (_) {
      await core.close();
      rethrow;
    }
  }

  final SyncLedger _ledger;
  final SecretKeyData _key;
  final SyncDevicePublicKey _local;
  final SyncTrust _trust;
  final SyncReplica _replica;
  final _approvedPairKeys = <String, String>{};
  final _sessionId = syncHex(syncRandomBytes(16));
  var _revision = 0;
  var _bytes = 0;
  var _hash = Uint8List(32);
  var _healthy = true;
  var _closed = false;

  SyncJournalStatus _status() => SyncJournalStatus(
    workspaceId: _trust.workspaceId,
    localDeviceId: _local.fingerprint,
    approvedDeviceIds: _trust.approvedDeviceIds,
    revision: _revision,
    watermark: _replica.watermark,
    changes: _replica.journalLength,
    approvedPairKeyIds: Map.unmodifiable(_approvedPairKeys),
  );

  @override
  Future<SyncJournalStatus> status() async {
    await _refresh();
    return _status();
  }

  @override
  Future<SyncRecord?> readRecord(SyncRecordKey key) async {
    await _refresh();
    return _replica.read(key);
  }

  @override
  Future<SyncJournalStatus> approveDevice(
    SyncDevicePublicKey device, {
    required int expectedRevision,
    String? pairKeyId,
  }) async {
    await _refresh();
    _expect(expectedRevision);
    final safeKey = _validatePairKeyId(pairKeyId);
    if (_trust.isApproved(device.fingerprint)) {
      if (_approvedPairKeys[device.fingerprint] != safeKey) {
        throw const SyncTrustException(
          'Revoke the existing pairing before replacing its key.',
        );
      }
      return _status();
    }
    if (_trust.approvedDeviceIds.length >= maxSyncDevices) {
      throw const SyncTrustException('The approved device limit was reached.');
    }
    return _append({
      'kind': 'approve',
      'publicKey': base64Url.encode(device.key.bytes),
      'pairKeyId': ?safeKey,
    }, () => _applyApproval(device, safeKey));
  }

  @override
  Future<SyncJournalStatus> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  }) async {
    await _refresh();
    _expect(expectedRevision);
    if (deviceId == _local.fingerprint) {
      throw const SyncTrustException('The local device owns this journal.');
    }
    if (!_trust.isApproved(deviceId)) return _status();
    return _append({
      'kind': 'revoke',
      'device': deviceId,
    }, () => _removeApproval(deviceId));
  }

  @override
  Future<SyncJournalDraft> draftChange({
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
  }) async {
    await _refresh();
    return SyncJournalDraft(
      _revision,
      _replica.nextChange(
        deviceId: _local.fingerprint,
        record: record,
        kind: kind,
        fields: fields,
      ),
    );
  }

  @override
  Future<SyncJournalStatus> commitLocal(
    SignedSyncChange change, {
    required int expectedRevision,
  }) async {
    await _refresh();
    if (change.change.dot.deviceId != _local.fingerprint) {
      throw const SyncTrustException(
        'Local edits require the local device signature.',
      );
    }
    final verified = [await _trust.verify(change)];
    final SyncBatchResult result;
    try {
      result = _replica.previewBatch(verified).result;
    } on SyncHistoryException {
      _expect(expectedRevision);
      rethrow;
    }
    // An exact repeat can follow a successful commit whose response was lost.
    if (result.duplicates == 1) return _status();
    _expect(expectedRevision);
    return _commitVerified(verified, result);
  }

  @override
  Future<SyncJournalExport?> exportChanges({
    required String recipientId,
    required SyncPairKey pairKey,
    SyncVersionVector known = const SyncVersionVector.empty(),
  }) async {
    await _refresh();
    _checkPeer(recipientId);
    final verified = <VerifiedSyncChange>[];
    var size = 1;
    final delivered = Map.of(known.counters);
    for (final signed in _replica.changesAfter(known)) {
      final encodedSize = utf8.encode(signed.encode()).length + 1;
      if (encodedSize > SyncEnvelopeCodec.maximumPayloadBytes - size) break;
      if (!_trust.isApproved(signed.change.dot.deviceId)) {
        // A peer already holding that author's history can fetch later changes.
        // Bootstrapping the missing history requires a supported trusted path.
        throw const SyncTrustException(
          'The recipient is missing history from a revoked device.',
        );
      }
      size += encodedSize;
      verified.add(await _trust.verify(signed));
      final dot = signed.change.dot;
      delivered[dot.deviceId] = dot.counter;
    }
    if (verified.isEmpty) return null;
    final sealed = await const SyncEnvelopeCodec().seal(
      trust: _trust,
      senderId: _local.fingerprint,
      recipientId: recipientId,
      key: pairKey,
      changes: verified,
    );
    return SyncJournalExport(
      bytes: sealed,
      changeCount: verified.length,
      hasMore: _replica
          .changesAfter(SyncVersionVector(delivered), limit: 1)
          .isNotEmpty,
    );
  }

  @override
  Future<SyncImportPreview> previewImport({
    required Uint8List envelope,
    required String senderId,
    required SyncPairKey pairKey,
  }) async {
    await _refresh();
    _checkPeer(senderId);
    final verified = await const SyncEnvelopeCodec().open(
      envelope: envelope,
      trust: _trust,
      senderId: senderId,
      recipientId: _local.fingerprint,
      key: pairKey,
    );
    final preview = _replica.previewBatch(verified);
    final records = {for (final change in preview.records) change.key: change};
    if (preview.result.duplicates > 0) {
      for (final signed in verified) {
        final change = signed.change;
        if (_replica.watermark.contains(change.dot) &&
            !records.containsKey(change.record)) {
          final recorded = _replica.read(change.record);
          if (recorded != null) {
            records[change.record] = SyncRecordChange.replay(recorded);
          }
        }
      }
    }
    final missing = <String, int>{};
    for (final deferred in preview.result.deferred) {
      for (final counter in deferred.missing.counters.entries) {
        if (counter.value > (missing[counter.key] ?? 0)) {
          missing[counter.key] = counter.value;
        }
      }
    }
    return _ImportPreview(
      sessionId: _sessionId,
      expectedRevision: _revision,
      senderId: senderId,
      signed: List.unmodifiable(verified.map((change) => change.signed)),
      changeCount: preview.result.applied.length,
      duplicateCount: preview.result.duplicates,
      hasDestructiveChanges: _destructive(preview),
      hasConflicts: _conflicts(preview),
      missing: SyncVersionVector(missing),
      records: List.unmodifiable(records.values),
    );
  }

  @override
  Future<SyncJournalStatus> commitImport(
    SyncImportPreview preview, {
    bool approveDestructiveChanges = false,
    bool approveConflicts = false,
  }) async {
    await _refresh();
    if (preview is! _ImportPreview || preview.sessionId != _sessionId) {
      throw const SyncJournalException(
        'Open the sync batch again to review it.',
      );
    }
    _expect(preview.expectedRevision);
    _checkPeer(preview.senderId);
    final verified = await _verifyAll(preview.signed);
    final review = _replica.previewBatch(verified);
    if (_destructive(review) && !approveDestructiveChanges) {
      throw const SyncImportApprovalRequired(
        SyncImportApproval.destructiveChanges,
      );
    }
    if (_conflicts(review) && !approveConflicts) {
      throw const SyncImportApprovalRequired(SyncImportApproval.conflicts);
    }
    return _commitVerified(verified, review.result);
  }

  bool _destructive(SyncBatchPreview preview) => preview.result.applied.any(
    (signed) => signed.change.kind != SyncChangeKind.patch,
  );

  bool _conflicts(SyncBatchPreview preview) =>
      preview.records.any((change) => change.after?.hasConflicts ?? false);

  Future<SyncJournalStatus> _commitVerified(
    List<VerifiedSyncChange> verified,
    SyncBatchResult result,
  ) async {
    if (result.deferred.isNotEmpty) {
      throw const SyncJournalException(
        'Import the missing earlier changes first.',
      );
    }
    if (result.applied.isEmpty) return _status();
    return _append({
      'kind': 'changes',
      'changes': [
        for (final signed in result.applied) jsonDecode(signed.encode()),
      ],
    }, () => _replica.applyBatch(verified));
  }

  Future<List<VerifiedSyncChange>> _verifyAll(
    List<SignedSyncChange> signed,
  ) async => [for (final change in signed) await _trust.verify(change)];

  void _expect(int expected) {
    if (expected != _revision) {
      throw SyncJournalRevisionConflict(expected, _revision);
    }
  }

  void _checkPeer(String id) {
    if (id == _local.fingerprint || !_trust.isApproved(id)) {
      throw const SyncTrustException(
        'The peer is not approved for this workspace.',
      );
    }
  }

  Future<void> _refresh() async {
    if (_closed) {
      throw const SyncJournalException('The sync journal is closed.');
    }
    if (!_healthy) throw _corrupt;
    try {
      final head = _ledger.readHead();
      if (head == null ||
          head.revision < _revision ||
          head.revision > syncLedgerMaximumRows ||
          head.bytes < _bytes ||
          head.bytes > syncLedgerMaximumBytes ||
          head.auth.length != syncLedgerHeadBytes) {
        throw _corrupt;
      }
      final expectedHash = await _open(
        head.auth,
        _headContext(head.revision, head.bytes),
      );
      while (_revision < head.revision) {
        final rows = _ledger.readPage(after: _revision, through: head.revision);
        if (rows.isEmpty) throw _corrupt;
        for (final row in rows) {
          if (row.revision != _revision + 1 ||
              row.encrypted.length > syncLedgerMaximumEntryBytes ||
              row.encrypted.length > head.bytes - _bytes) {
            throw _corrupt;
          }
          final body = await _open(row.encrypted, _entryContext(row.revision));
          await _applyEntry(
            syncDecodeJson(
              utf8.decode(body),
              maxChars: syncLedgerMaximumEntryBytes,
            ),
          );
          _advance(row.revision, row.encrypted);
        }
      }
      if (_bytes != head.bytes || !_equal(expectedHash, _hash)) throw _corrupt;
    } catch (_) {
      _healthy = false;
      throw _corrupt;
    }
  }

  Future<void> _applyEntry(Object? body) async {
    if (body is! Map<String, dynamic>) throw _corrupt;
    switch (body['kind']) {
      case 'approve':
        final key = body['publicKey'];
        if (key is! String || key.length != 44) throw _corrupt;
        _applyApproval(
          SyncDevicePublicKey.fromBytes(base64Url.decode(key)),
          _validatePairKeyId(body['pairKeyId']),
        );
      case 'revoke':
        final id = body['device'];
        if (id is! String || id == _local.fingerprint || !_trust.revoke(id)) {
          throw _corrupt;
        }
        _approvedPairKeys.remove(id);
      case 'changes':
        final changes = body['changes'];
        if (changes is! List ||
            changes.isEmpty ||
            changes.length > SyncEnvelopeCodec.maximumChanges) {
          throw _corrupt;
        }
        final verified = await _verifyAll([
          for (final change in changes)
            SignedSyncChange.decode(jsonEncode(change)),
        ]);
        final result = _replica.applyBatch(verified);
        if (result.deferred.isNotEmpty || result.duplicates != 0) {
          throw _corrupt;
        }
      default:
        throw _corrupt;
    }
  }

  void _applyApproval(SyncDevicePublicKey device, String? keyId) {
    _trust.approve(device);
    if (keyId != null) _approvedPairKeys[device.fingerprint] = keyId;
  }

  void _removeApproval(String deviceId) {
    _trust.revoke(deviceId);
    _approvedPairKeys.remove(deviceId);
  }

  String? _validatePairKeyId(Object? keyId) {
    if (keyId == null) return null;
    if (keyId is! String || !syncMatches(syncDeviceIdPattern, keyId)) {
      throw const FormatException('Invalid pairing key ID.');
    }
    return keyId;
  }

  Future<SyncJournalStatus> _append(
    Map<String, Object?> action,
    void Function() apply,
  ) async {
    final revision = _revision + 1;
    final body = utf8.encode(jsonEncode(action));
    if (revision > syncLedgerMaximumRows ||
        body.length + _nonceBytes + _tagBytes > syncLedgerMaximumEntryBytes ||
        body.length + _nonceBytes + _tagBytes >
            syncLedgerMaximumBytes - _bytes) {
      throw const SyncJournalException(
        'The sync journal reached its storage limit.',
      );
    }
    final encrypted = await _seal(body, _entryContext(revision));
    final head = await _sealHead(
      revision,
      _bytes + encrypted.length,
      _digest(encrypted),
    );
    _ledger.append(
      expectedRevision: _revision,
      head: head,
      encrypted: encrypted,
    );
    apply();
    _advance(revision, encrypted);
    return _status();
  }

  void _advance(int revision, Uint8List encrypted) {
    _revision = revision;
    _bytes += encrypted.length;
    _hash = _digest(encrypted);
  }

  Uint8List _digest(Uint8List bytes) =>
      Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

  Future<SyncLedgerHead> _sealHead(
    int revision,
    int bytes,
    Uint8List hash,
  ) async => (
    revision: revision,
    bytes: bytes,
    auth: await _seal(hash, _headContext(revision, bytes)),
  );

  String get _domain =>
      'Easy Sync Journal v1\u0000${_trust.workspaceId.value}\t${_local.fingerprint}';
  List<int> _headContext(int revision, int bytes) =>
      utf8.encode('$_domain\thead\t$revision\t$bytes');
  List<int> _entryContext(int revision) =>
      utf8.encode('$_domain\tentry\t$revision\t${syncHex(_hash)}');

  Future<Uint8List> _seal(List<int> data, List<int> aad) async =>
      Uint8List.fromList(
        (await _aes.encrypt(data, secretKey: _key, aad: aad)).concatenation(),
      );

  Future<List<int>> _open(Uint8List data, List<int> aad) => _aes.decrypt(
    SecretBox.fromConcatenation(
      data,
      nonceLength: _nonceBytes,
      macLength: _tagBytes,
    ),
    secretKey: _key,
    aad: aad,
  );

  bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _key.destroy();
    _ledger.close();
  }
}

final class _ImportPreview implements SyncImportPreview {
  const _ImportPreview({
    required this.sessionId,
    required this.expectedRevision,
    required this.senderId,
    required this.signed,
    required this.changeCount,
    required this.duplicateCount,
    required this.hasDestructiveChanges,
    required this.hasConflicts,
    required this.missing,
    required this.records,
  });

  final String sessionId;
  final List<SignedSyncChange> signed;
  @override
  final int expectedRevision;
  @override
  final String senderId;
  @override
  final int changeCount;
  @override
  final int duplicateCount;
  @override
  final bool hasDestructiveChanges;
  @override
  final bool hasConflicts;
  @override
  final SyncVersionVector missing;
  @override
  final List<SyncRecordChange> records;
}
