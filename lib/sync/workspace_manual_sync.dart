import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/src/snapshot_codec.dart';
import '../storage/workspace_store.dart';
import '../task_model.dart';
import 'manual_sync_contracts.dart';
import 'manual_sync_workspace.dart';
import 'src/sync_wire.dart' show maxLocalSyncBatchChanges;
import 'src/workspace_sync_record.dart';

part 'src/workspace_manual_sync_projection.dart';

/// Explicit Task, Calendar event and Note selection for native manual sync.
/// Transfer review and the live workspace commit are deliberately separate.
final class WorkspaceManualSyncProjector
    implements ManualSyncProjector, ManualSyncOutgoing {
  WorkspaceManualSyncProjector({
    required this._store,
    Future<void> Function()? flushWorkspaceWrites,
    this._onRestored,
  }) : _flush = flushWorkspaceWrites;

  final WorkspaceStore _store;
  final Future<void> Function()? _flush;
  final Future<void> Function(WorkspaceRevision)? _onRestored;
  final _incoming = Expando<_IncomingPlan>();
  final _outgoing = Expando<_OutgoingPlan>();

  Future<WorkspaceRevision> _read() async {
    await _flush?.call();
    return _store.read();
  }

  @override
  Future<ManualSyncProjectionPreview> previewIncoming({
    required ManualSyncWorkspace sync,
    required SyncImportPreview imported,
    required SyncJournalStatus committed,
  }) async {
    sync.verifyCommittedImport(imported, committed);
    await _verifyJournal(sync, committed.revision);
    final saved = await _read();
    final rows = await compute(_reviewIncoming, (
      saved.snapshot,
      imported.records,
    ));
    await _verifyJournal(sync, committed.revision);
    final preview = ManualSyncProjectionPreview(
      syncWorkspaceId: committed.workspaceId,
      syncRevision: committed.revision,
      expectedWorkspaceRevision: saved.revision,
      records: rows.map((row) => row.review),
    );
    _incoming[preview] = (
      session: sync,
      base: saved,
      operations: {
        for (final row in rows)
          if (row.review.selectable) row.review.key: row,
      },
    );
    return preview;
  }

  @override
  Future<WorkspaceRevision> applyIncoming(
    ManualSyncProjectionPreview preview, {
    required Set<SyncRecordKey> selected,
  }) async {
    final plan = _incoming[preview];
    if (plan == null ||
        selected.isEmpty ||
        !selected.every(plan.operations.containsKey)) {
      throw const SyncJournalException('Review the records to apply first.');
    }
    final keys = selected.toList()..sort(_recordOrder);
    final expected = plan.base.revision;
    final current = await _read();
    final operationId =
        'sync-projection-${digestText(jsonEncode([
          preview.syncWorkspaceId.value,
          preview.syncRevision,
          expected,
          for (final key in keys) [key.kind.name, key.id],
        ]))}';
    final backup = await compute(_projectRecords, (
      plan.base,
      [for (final key in keys) plan.operations[key]!],
    ));
    Future<WorkspaceRevision> publish() => _store.restoreBackup(
      backup,
      expectedRevision: expected,
      operationId: operationId,
    );
    // The store recognizes an already published operation before its CAS.
    // That allows a retry after interruption to load the latest workspace.
    final result = current.revision > expected
        ? await publish()
        : await plan.session.applyAtRevision(preview.syncRevision, publish);
    await _onRestored?.call(result);
    return result;
  }

  @override
  Future<ManualSyncOutgoingPreview> previewOutgoing({
    required ManualSyncWorkspace sync,
    String query = '',
  }) async {
    final saved = await _read();
    final journal = await sync.status();
    final result = await compute(_reviewOutgoing, (saved.snapshot, query));
    await _verifyJournal(sync, journal.revision);
    final preview = ManualSyncOutgoingPreview(
      syncRevision: journal.revision,
      expectedWorkspaceRevision: saved.revision,
      records: [
        for (final record in result.records)
          ManualSyncOutgoingRecord(
            key: record.key,
            title: record.title,
            details: record.details,
          ),
      ],
      hasMore: result.hasMore,
    );
    _outgoing[preview] = (
      session: sync,
      records: {for (final record in result.records) record.key: record},
    );
    return preview;
  }

  @override
  Future<int> stageOutgoing(
    ManualSyncOutgoingPreview preview, {
    required Set<SyncRecordKey> selected,
  }) async {
    final plan = _outgoing[preview];
    if (plan == null ||
        selected.isEmpty ||
        selected.length > maxLocalSyncBatchChanges ||
        !selected.every(plan.records.containsKey)) {
      throw const SyncJournalException('Review the records to stage first.');
    }
    Future<void> verifyWorkspace() async {
      verifyRevision(
        preview.expectedWorkspaceRevision,
        (await _read()).revision,
      );
    }

    await verifyWorkspace();
    await _verifyJournal(plan.session, preview.syncRevision);
    final updates = <ManualSyncLocalRecord>[];
    final keys = selected.toList()..sort(_recordOrder);
    for (final key in keys) {
      final current = await plan.session.readRecord(key);
      final record = plan.records[key]!;
      if (current != null) {
        final previous = _readJournalRecord(current);
        if (current.state != SyncRecordState.active ||
            current.hasConflicts ||
            previous == null) {
          throw const SyncJournalException(
            'One of these records has unresolved changes in the sync journal.',
          );
        }
        if (previous.canonical == record.canonical) continue;
      }
      updates.add((key: key, fields: record.journalFields));
    }
    if (updates.isEmpty) {
      await verifyWorkspace();
      await _verifyJournal(plan.session, preview.syncRevision);
      return 0;
    }
    await plan.session.writeLocalRecords(
      records: updates,
      expectedRevision: preview.syncRevision,
      verifyWorkspace: verifyWorkspace,
    );
    return updates.length;
  }
}

typedef _IncomingPlan = ({
  ManualSyncWorkspace session,
  WorkspaceRevision base,
  Map<SyncRecordKey, _ProjectionRow> operations,
});
typedef _OutgoingPlan = ({
  ManualSyncWorkspace session,
  Map<SyncRecordKey, WorkspaceSyncRecord> records,
});

Future<void> _verifyJournal(ManualSyncWorkspace sync, int expected) async {
  final actual = (await sync.status()).revision;
  if (actual != expected) throw SyncJournalRevisionConflict(expected, actual);
}

int _recordOrder(SyncRecordKey a, SyncRecordKey b) {
  final byKind = a.kind.index.compareTo(b.kind.index);
  return byKind == 0 ? a.id.compareTo(b.id) : byKind;
}
