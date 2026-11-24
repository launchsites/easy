import 'dart:convert';

import 'sync_change.dart';
import 'sync_security.dart';
import 'sync_wire.dart';

enum SyncApplyStatus { applied, duplicate, deferred }

final class SyncApplyResult {
  const SyncApplyResult._(this.status, this.missing);

  final SyncApplyStatus status;
  final SyncVersionVector missing;
}

final class SyncDeferredChange {
  const SyncDeferredChange(this.change, this.missing);

  final VerifiedSyncChange change;
  final SyncVersionVector missing;
}

final class SyncBatchResult {
  const SyncBatchResult._({
    required this.applied,
    required this.duplicates,
    required this.deferred,
  });

  final List<SignedSyncChange> applied;
  final int duplicates;
  final List<SyncDeferredChange> deferred;
}

final class SyncRecordChange {
  const SyncRecordChange._(this.key, this.before, this.after);

  final SyncRecordKey key;
  final SyncRecord? before;
  final SyncRecord? after;
}

final class SyncBatchPreview {
  const SyncBatchPreview._(this.result, this.records);

  final SyncBatchResult result;
  final List<SyncRecordChange> records;
}

final class SyncHistoryException implements Exception {
  const SyncHistoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum SyncRecordState { active, deleted, deleteConflict }

final class SyncFieldVersion {
  const SyncFieldVersion._(this.dot, this.value);

  final SyncDot dot;
  final Object? value;
}

final class SyncRecord {
  const SyncRecord._({
    required this.key,
    required this.state,
    required this.fields,
    required this.tombstones,
  });

  final SyncRecordKey key;
  final SyncRecordState state;
  final Map<String, List<SyncFieldVersion>> fields;
  final List<SyncDot> tombstones;

  bool hasFieldConflict(String field) {
    final versions = fields[field];
    if (versions == null || versions.length < 2) return false;
    final first = jsonEncode(versions.first.value);
    return versions
        .skip(1)
        .any((version) => jsonEncode(version.value) != first);
  }

  bool get hasConflicts =>
      state == SyncRecordState.deleteConflict ||
      (state == SyncRecordState.active && fields.keys.any(hasFieldConflict));
}

/// In-memory causal materialization for one explicitly trusted workspace.
/// The host owns transactional journal persistence, retry queues and any
/// projection into application models. Journal bounds require a checkpoint
/// before accepting more history.
final class SyncReplica {
  SyncReplica(
    this.trust, {
    this.maximumChanges = 100000,
    this.maximumJournalBytes = 32 * 1024 * 1024,
  }) {
    if (maximumChanges < 1 || maximumJournalBytes < 1) {
      throw ArgumentError('Sync history limits must be positive.');
    }
  }

  final SyncTrust trust;
  final int maximumChanges;
  final int maximumJournalBytes;
  final _journal = <SyncDot, VerifiedSyncChange>{};
  final _records = <SyncRecordKey, _RecordRegister>{};
  var _watermark = const SyncVersionVector.empty();
  var _journalBytes = 0;

  SyncVersionVector get watermark => _watermark;
  int get journalLength => _journal.length;
  int get journalBytes => _journalBytes;

  /// Captures the current causal context for a new local change. Serialize
  /// the host's local authoring to avoid signing two changes at one counter.
  SyncChange nextChange({
    required String deviceId,
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
  }) {
    if (!trust.isApproved(deviceId)) {
      throw const SyncTrustException(
        'The device is not approved for this workspace.',
      );
    }
    return SyncChange(
      workspaceId: trust.workspaceId,
      dot: (deviceId: deviceId, counter: _watermark[deviceId] + 1),
      context: _watermark,
      record: record,
      kind: kind,
      fields: fields,
    );
  }

  SyncApplyResult apply(VerifiedSyncChange change) {
    final result = applyBatch([change]);
    if (result.deferred.isNotEmpty) {
      return SyncApplyResult._(
        SyncApplyStatus.deferred,
        result.deferred.single.missing,
      );
    }
    return SyncApplyResult._(
      result.duplicates == 0
          ? SyncApplyStatus.applied
          : SyncApplyStatus.duplicate,
      const SyncVersionVector.empty(),
    );
  }

  /// Applies ready changes in causal order. A validation or capacity failure
  /// leaves the replica untouched. The host can retain deferred changes and
  /// request missing counters using the returned watermarks.
  SyncBatchResult applyBatch(List<VerifiedSyncChange> incoming) {
    final plan = _plan(incoming);
    for (final verified in plan.staged.values) {
      final change = verified.change;
      final record = _records.putIfAbsent(change.record, _RecordRegister.new);
      record.apply(change);
      if (record.isEmpty) _records.remove(change.record);
    }
    _journal.addAll(plan.staged);
    _journalBytes = plan.size;
    _watermark = plan.watermark;
    return plan.result;
  }

  /// Projects a validated batch without writing the register or journal.
  SyncBatchPreview previewBatch(List<VerifiedSyncChange> incoming) {
    final plan = _plan(incoming);
    final projected = <SyncRecordKey, _RecordRegister>{};
    for (final verified in plan.staged.values) {
      final change = verified.change;
      projected
          .putIfAbsent(
            change.record,
            () => _records[change.record]?.copy() ?? _RecordRegister(),
          )
          .apply(change);
    }
    return SyncBatchPreview._(
      plan.result,
      List.unmodifiable([
        for (final entry in projected.entries)
          SyncRecordChange._(
            entry.key,
            read(entry.key),
            entry.value.isEmpty ? null : entry.value.project(entry.key),
          ),
      ]),
    );
  }

  _ApplyPlan _plan(List<VerifiedSyncChange> incoming) {
    if (incoming.length > SyncEnvelopeCodec.maximumChanges) {
      throw const SyncHistoryException('Too many changes in one sync batch.');
    }
    final pending = <SyncDot, VerifiedSyncChange>{};
    var duplicates = 0;
    for (final verified in incoming) {
      if (!trust.accepts(verified)) {
        throw const SyncTrustException(
          'A change is outside the approved workspace.',
        );
      }
      final dot = verified.change.dot;
      final existing = _journal[dot] ?? pending[dot];
      if (existing == null) {
        pending[dot] = verified;
      } else if (existing.fingerprint == verified.fingerprint) {
        duplicates++;
      } else {
        throw const SyncHistoryException(
          'Conflicting changes share a sync counter.',
        );
      }
    }

    final staged = <SyncDot, VerifiedSyncChange>{};
    final counters = Map.of(_watermark.counters);
    var size = _journalBytes;
    while (pending.isNotEmpty) {
      final ready = [
        for (final verified in pending.values)
          if (verified.change.context.counters.entries.every(
            (entry) => (counters[entry.key] ?? 0) >= entry.value,
          ))
            verified,
      ];
      if (ready.isEmpty) break;

      for (final verified in ready) {
        final change = verified.change;
        for (final entry in change.context.counters.entries) {
          final dot = (deviceId: entry.key, counter: entry.value);
          final ancestor = (staged[dot] ?? _journal[dot])!;
          if (!change.context.covers(ancestor.change.context)) {
            throw const SyncHistoryException(
              'A change omits known causal history.',
            );
          }
        }
        if (_journal.length + staged.length >= maximumChanges ||
            change.byteLength + verified.signed.signature.length >
                maximumJournalBytes - size) {
          throw const SyncHistoryException(
            'The sync history limit was reached.',
          );
        }
        size += change.byteLength + verified.signed.signature.length;
        counters[change.dot.deviceId] = change.dot.counter;
        if (counters.length > maxSyncDevices) {
          throw const SyncHistoryException('Too many devices in sync history.');
        }
        staged[change.dot] = verified;
        pending.remove(change.dot);
      }
    }

    final nextWatermark = SyncVersionVector(counters);
    final result = SyncBatchResult._(
      duplicates: duplicates,
      applied: List.unmodifiable(staged.values.map((change) => change.signed)),
      deferred: List.unmodifiable([
        for (final verified in pending.values)
          SyncDeferredChange(
            verified,
            verified.change.context.missingFrom(nextWatermark),
          ),
      ]),
    );
    return (
      staged: staged,
      size: size,
      watermark: nextWatermark,
      result: result,
    );
  }

  /// An ordered page of signed operations the remote watermark does not cover.
  /// The host can retain these in a protected journal for retry and recovery.
  List<SignedSyncChange> changesAfter(
    SyncVersionVector remote, {
    int limit = SyncEnvelopeCodec.maximumChanges,
  }) {
    if (limit < 1 || limit > SyncEnvelopeCodec.maximumChanges) {
      throw RangeError.range(limit, 1, SyncEnvelopeCodec.maximumChanges);
    }
    return List.unmodifiable(
      _journal.entries
          .where((entry) => !remote.contains(entry.key))
          .take(limit)
          .map((entry) => entry.value.signed),
    );
  }

  SyncRecord? read(SyncRecordKey key) => _records[key]?.project(key);
}

typedef _ApplyPlan = ({
  Map<SyncDot, VerifiedSyncChange> staged,
  int size,
  SyncVersionVector watermark,
  SyncBatchResult result,
});

final class _RecordRegister {
  final fields = <String, Map<SyncDot, SyncFieldVersion>>{};
  final tombstones = <SyncDot, SyncVersionVector>{};

  bool get isEmpty => fields.isEmpty && tombstones.isEmpty;

  _RecordRegister copy() => _RecordRegister()
    ..fields.addAll({
      for (final entry in fields.entries) entry.key: Map.of(entry.value),
    })
    ..tombstones.addAll(tombstones);

  void apply(SyncChange change) {
    if (change.kind != SyncChangeKind.patch) {
      tombstones.removeWhere((dot, _) => change.context.contains(dot));
      if (change.kind == SyncChangeKind.delete) {
        tombstones[change.dot] = change.context;
      }
    }
    for (final entry in change.fields.entries) {
      final versions = fields.putIfAbsent(entry.key, () => {});
      versions.removeWhere((dot, _) => change.context.contains(dot));
      versions[change.dot] = SyncFieldVersion._(change.dot, entry.value);
    }
  }

  SyncRecord project(SyncRecordKey key) {
    final fieldsOrdered = fields.keys.toList()..sort();
    final deleted = tombstones.isNotEmpty;
    final hasDeleteConflict =
        deleted &&
        tombstones.values.any(
          (context) => fields.values.any(
            (versions) => versions.keys.any((dot) => !context.contains(dot)),
          ),
        );
    return SyncRecord._(
      key: key,
      state: hasDeleteConflict
          ? SyncRecordState.deleteConflict
          : deleted
          ? SyncRecordState.deleted
          : SyncRecordState.active,
      fields: Map.unmodifiable({
        for (final name in fieldsOrdered)
          name: List<SyncFieldVersion>.unmodifiable(
            fields[name]!.values.toList()
              ..sort((a, b) => _compareDots(a.dot, b.dot)),
          ),
      }),
      tombstones: List.unmodifiable(
        tombstones.keys.toList()..sort(_compareDots),
      ),
    );
  }
}

int _compareDots(SyncDot a, SyncDot b) {
  final deviceOrder = a.deviceId.compareTo(b.deviceId);
  return deviceOrder == 0 ? a.counter.compareTo(b.counter) : deviceOrder;
}
