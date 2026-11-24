import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'sync_change.dart';
import 'sync_journal_core.dart';
import 'sync_journal_sqlite.dart';
import 'sync_journal_types.dart';
import 'sync_replica.dart';
import 'sync_security.dart';

Future<SyncJournal?> openPlatformSyncJournal({
  required SyncWorkspaceId workspaceId,
  required SyncDevicePublicKey localDevicePublicKey,
  required SyncJournalKey journalKey,
  String? databasePath,
  required bool createIfMissing,
}) async {
  final path =
      databasePath ??
      (await getApplicationSupportDirectory()).uri
          .resolve('easy/sync/${workspaceId.value}.sqlite3')
          .toFilePath();
  final client = _JournalClient();
  await client.start(
    path,
    workspaceId,
    localDevicePublicKey,
    journalKey,
    createIfMissing,
  );
  return _NativeSyncJournal(client);
}

enum _Command {
  status,
  record,
  approve,
  revoke,
  draft,
  local,
  localBatch,
  holdRevision,
  releaseRevision,
  export,
  preview,
  import,
  close,
}

typedef _DraftRequest = (SyncRecordKey, SyncChangeKind, Map<String, Object?>);
typedef _ExportRequest = (String, TransferableTypedData, SyncVersionVector);
typedef _PreviewRequest = (
  String,
  TransferableTypedData,
  TransferableTypedData,
);

final class _NativeSyncJournal implements SyncJournal {
  const _NativeSyncJournal(this._client);

  final _JournalClient _client;

  @override
  Future<SyncJournalStatus> status() => _client.request(_Command.status);

  @override
  Future<SyncRecord?> readRecord(SyncRecordKey key) =>
      _client.request(_Command.record, key);

  @override
  Future<SyncJournalStatus> approveDevice(
    SyncDevicePublicKey device, {
    required int expectedRevision,
    String? pairKeyId,
  }) =>
      _client.request(_Command.approve, (device, expectedRevision, pairKeyId));

  @override
  Future<SyncJournalStatus> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  }) => _client.request(_Command.revoke, (deviceId, expectedRevision));

  @override
  Future<SyncJournalDraft> draftChange({
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
  }) => _client.request(_Command.draft, (record, kind, fields));

  @override
  Future<SyncJournalStatus> commitLocal(
    SignedSyncChange change, {
    required int expectedRevision,
  }) => _client.request(_Command.local, (change, expectedRevision));

  @override
  Future<SyncJournalStatus> commitLocalBatch(
    List<SignedSyncChange> changes, {
    required int expectedRevision,
  }) => _client.request(_Command.localBatch, (changes, expectedRevision));

  @override
  Future<String> holdRevision(int expectedRevision) =>
      _client.request(_Command.holdRevision, expectedRevision);

  @override
  Future<void> releaseRevision(String lease) =>
      _client.request(_Command.releaseRevision, lease);

  @override
  Future<SyncJournalExport?> exportChanges({
    required String recipientId,
    required SyncPairKey pairKey,
    SyncVersionVector known = const SyncVersionVector.empty(),
  }) => _client.request(_Command.export, (
    recipientId,
    _transferSecret(pairKey.copyBytesForSecureStorage()),
    known,
  ));

  @override
  Future<SyncImportPreview> previewImport({
    required Uint8List envelope,
    required String senderId,
    required SyncPairKey pairKey,
  }) async {
    if (envelope.length > SyncEnvelopeCodec.maximumBytes) {
      throw const FormatException('Invalid sync envelope length.');
    }
    return _client.request(_Command.preview, (
      senderId,
      _transferSecret(pairKey.copyBytesForSecureStorage()),
      TransferableTypedData.fromList([envelope]),
    ));
  }

  @override
  Future<SyncJournalStatus> commitImport(
    SyncImportPreview preview, {
    bool approveDestructiveChanges = false,
    bool approveConflicts = false,
  }) => _client.request(_Command.import, (
    preview,
    approveDestructiveChanges,
    approveConflicts,
  ));

  @override
  Future<void> close() => _client.close();
}

TransferableTypedData _transferSecret(Uint8List bytes) {
  final transfer = TransferableTypedData.fromList([bytes]);
  bytes.fillRange(0, bytes.length, 0);
  return transfer;
}

typedef _Configuration = (
  String,
  SyncWorkspaceId,
  SyncDevicePublicKey,
  TransferableTypedData,
  bool,
  SendPort,
);

final class _JournalClient {
  final _responses = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  SendPort? _commands;
  Future<void>? _closeFuture;
  var _sequence = 0;
  var _ended = false;

  Future<void> start(
    String path,
    SyncWorkspaceId workspace,
    SyncDevicePublicKey local,
    SyncJournalKey key,
    bool createIfMissing,
  ) async {
    _responses.listen(_receive);
    try {
      final results = await Future.wait<Object>([
        _ready.future,
        Isolate.spawn(
          _startWorker,
          (
            path,
            workspace,
            local,
            _transferSecret(key.copyBytesForSecureStorage()),
            createIfMissing,
            _responses.sendPort,
          ),
          debugName: 'easy-sync-journal',
          onError: _responses.sendPort,
          onExit: _responses.sendPort,
        ),
      ], eagerError: true);
      _commands = results.first as SendPort;
    } catch (_) {
      _responses.close();
      rethrow;
    }
  }

  Future<T> request<T>(_Command command, [Object? data]) async {
    if (_ended || _closeFuture != null || _commands == null) {
      throw const SyncJournalException('The sync journal is closed.');
    }
    return await _send(command, data) as T;
  }

  Future<Object?> _send(_Command command, Object? data) async {
    final id = _sequence++;
    final reply = Completer<Object?>();
    _pending[id] = reply;
    try {
      _commands!.send((id, command, data));
    } catch (_) {
      _pending.remove(id);
      throw const SyncJournalException('Invalid sync journal request.');
    }
    return reply.future;
  }

  void _receive(Object? message) {
    switch (message) {
      case SendPort port:
        _ready.complete(port);
      case (final int id, final bool success, final Object? data):
        final reply = _pending.remove(id);
        if (success) {
          reply?.complete(data);
        } else {
          reply?.completeError(data!);
        }
      case SyncJournalException error:
        _fail(error);
      case null || List<dynamic> _:
        _fail(const SyncJournalException('The sync journal stopped.'));
    }
  }

  void _fail(SyncJournalException error) {
    _ended = true;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _responses.close();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    try {
      if (!_ended && _commands != null) await _send(_Command.close, null);
    } finally {
      _responses.close();
      _ended = true;
    }
  }
}

Future<void> _startWorker(_Configuration configuration) async {
  final (path, workspace, local, secret, createIfMissing, responses) =
      configuration;
  final SyncJournalCore journal;
  try {
    journal = await SyncJournalCore.open(
      ledger: SqliteSyncLedger.open(path, createIfMissing: createIfMissing),
      workspaceId: workspace,
      local: local,
      keyBytes: secret.materialize().asUint8List(),
      createIfMissing: createIfMissing,
    );
  } catch (error) {
    responses.send(
      error is SyncJournalException
          ? error
          : const SyncJournalException('The sync journal could not be opened.'),
    );
    return;
  }
  final commands = ReceivePort();
  responses.send(commands.sendPort);
  await for (final message in commands) {
    final (id, command, data) = message as (int, _Command, Object?);
    try {
      final result = await _execute(journal, command, data);
      responses.send((id, true, result));
    } catch (error) {
      final safe = switch (error) {
        SyncJournalException() ||
        SyncJournalRevisionConflict() ||
        SyncHistoryException() ||
        SyncTrustException() ||
        SyncAuthenticationException() ||
        SyncImportApprovalRequired() => error,
        FormatException() => const FormatException(
          'Invalid sync journal data.',
        ),
        _ => const SyncJournalException(
          'The sync journal could not complete this operation.',
        ),
      };
      responses.send((id, false, safe));
    } finally {
      if (command == _Command.close) commands.close();
    }
  }
}

Future<Object?> _execute(
  SyncJournal journal,
  _Command command,
  Object? data,
) async {
  switch (command) {
    case _Command.status:
      return journal.status();
    case _Command.record:
      return journal.readRecord(data as SyncRecordKey);
    case _Command.approve:
      final (key, revision, pairKeyId) =
          data as (SyncDevicePublicKey, int, String?);
      return journal.approveDevice(
        key,
        expectedRevision: revision,
        pairKeyId: pairKeyId,
      );
    case _Command.revoke:
      final (device, revision) = data as (String, int);
      return journal.revokeDevice(device, expectedRevision: revision);
    case _Command.draft:
      final (record, kind, fields) = data as _DraftRequest;
      return journal.draftChange(record: record, kind: kind, fields: fields);
    case _Command.local:
      final (change, revision) = data as (SignedSyncChange, int);
      return journal.commitLocal(change, expectedRevision: revision);
    case _Command.localBatch:
      final (changes, revision) = data as (List<SignedSyncChange>, int);
      return journal.commitLocalBatch(changes, expectedRevision: revision);
    case _Command.holdRevision:
      return journal.holdRevision(data as int);
    case _Command.releaseRevision:
      await journal.releaseRevision(data as String);
      return null;
    case _Command.export:
      final (recipient, key, known) = data as _ExportRequest;
      return _usePair(
        key,
        (pair) => journal.exportChanges(
          recipientId: recipient,
          pairKey: pair,
          known: known,
        ),
      );
    case _Command.preview:
      final (sender, key, bytes) = data as _PreviewRequest;
      return _usePair(
        key,
        (pair) => journal.previewImport(
          envelope: bytes.materialize().asUint8List(),
          senderId: sender,
          pairKey: pair,
        ),
      );
    case _Command.import:
      final (preview, destructive, conflicts) =
          data as (SyncImportPreview, bool, bool);
      return journal.commitImport(
        preview,
        approveDestructiveChanges: destructive,
        approveConflicts: conflicts,
      );
    case _Command.close:
      await journal.close();
      return null;
  }
}

Future<T> _usePair<T>(
  TransferableTypedData transfer,
  Future<T> Function(SyncPairKey) action,
) async {
  final bytes = transfer.materialize().asUint8List();
  final pair = SyncPairKey.fromBytes(bytes);
  bytes.fillRange(0, bytes.length, 0);
  try {
    return await action(pair);
  } finally {
    pair.destroy();
  }
}
