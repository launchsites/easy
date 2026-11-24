import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy/sync/workspace_sync.dart';

const graphCount = 64;
const schedulesPerGraph = 16;
const peersPerGraph = 5;
const roundsPerGraph = 32;

final records = [
  for (var i = 0; i < 8; i++) (kind: SyncRecordKind.note, id: 'note-$i'),
];

Future<void> main() async {
  final identities = <SyncDeviceIdentity>[];
  try {
    for (var device = 1; device <= peersPerGraph; device++) {
      final seed = Uint8List.fromList(List.filled(32, device));
      identities.add(await SyncDeviceIdentity.fromSeed(seed));
      seed.fillRange(0, seed.length, 0);
    }
    final watch = Stopwatch()..start();
    var deliveries = 0;
    var applied = 0;
    var duplicates = 0;
    var deferred = 0;
    var conflictRecords = 0;
    var deleteRecords = 0;
    final fingerprints = <String>[];
    for (var seed = 0; seed < graphCount; seed++) {
      final workspace = SyncWorkspaceId(
        seed.toRadixString(16).padLeft(32, '0'),
      );
      final trust = SyncTrust(
        workspace,
        approved: identities.map((key) => key.publicKey),
      );
      final original = await _history(trust, identities, seed);
      final authoritative = SyncReplica(trust)..applyBatch(original);
      if (authoritative.journalLength != original.length) {
        throw StateError('The fixture did not converge for graph $seed.');
      }
      final expected = _fingerprint(authoritative);
      fingerprints.add(expected);
      for (final key in records) {
        final record = authoritative.read(key)!;
        if (record.hasConflicts) conflictRecords++;
        if (record.state != SyncRecordState.active) deleteRecords++;
      }
      for (var schedule = 0; schedule < schedulesPerGraph; schedule++) {
        final recipient = SyncReplica(trust);
        final random = Random(seed * schedulesPerGraph + schedule);
        final arrival = [
          ...original,
          for (var i = 0; i < 10; i++)
            original[random.nextInt(original.length)],
        ]..shuffle(random);
        var pending = <SyncDot, VerifiedSyncChange>{};
        for (final verified in arrival) {
          final result = recipient.applyBatch([...pending.values, verified]);
          deliveries++;
          duplicates += result.duplicates;
          applied += result.applied.length;
          deferred += result.deferred.length;
          pending = {
            for (final held in result.deferred)
              held.change.change.dot: held.change,
          };
        }
        if (pending.isNotEmpty || _fingerprint(recipient) != expected) {
          throw StateError(
            'Divergent sync state for graph $seed, schedule $schedule.',
          );
        }
      }
    }
    if (duplicates == 0 ||
        deferred == 0 ||
        conflictRecords == 0 ||
        deleteRecords == 0) {
      throw StateError(
        'The fixture failed to exercise concurrent or delayed changes.',
      );
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'graphs': graphCount,
        'devices_per_graph': peersPerGraph,
        'delivery_schedules': graphCount * schedulesPerGraph,
        'delivered_packets': deliveries,
        'applied_changes': applied,
        'duplicate_deliveries': duplicates,
        'deferred_observations': deferred,
        'final_conflicting_records': conflictRecords,
        'final_records_with_deletion': deleteRecords,
        'canonical_fingerprints_sha256': sha256
            .convert(utf8.encode(fingerprints.join()))
            .toString(),
        'elapsed_seconds': watch.elapsedMilliseconds / 1000,
      }),
    );
  } finally {
    for (final identity in identities) {
      identity.destroy();
    }
  }
}

Future<List<VerifiedSyncChange>> _history(
  SyncTrust trust,
  List<SyncDeviceIdentity> identities,
  int seed,
) async {
  final participants = [for (final _ in identities) SyncReplica(trust)];
  final history = <VerifiedSyncChange>[];
  Future<void> write(
    int index,
    SyncRecordKey record,
    SyncChangeKind kind,
    Map<String, Object?> fields,
  ) async {
    final identity = identities[index];
    final signed = await identity.sign(
      participants[index].nextChange(
        deviceId: identity.deviceId,
        record: record,
        kind: kind,
        fields: fields,
      ),
    );
    final verified = await trust.verify(signed);
    participants[index].apply(verified);
    history.add(verified);
  }

  for (final record in records) {
    await write(0, record, SyncChangeKind.patch, {
      'body': 'Original ${record.id}',
    });
  }
  for (final peer in participants.skip(1)) {
    peer.applyBatch(history);
  }
  final random = Random(seed);
  for (var round = 0; round < roundsPerGraph; round++) {
    final author = random.nextInt(participants.length);
    final record = records[random.nextInt(records.length)];
    final state = participants[author].read(record)!.state;
    final pick = random.nextInt(5);
    final kind = pick == 0
        ? (state == SyncRecordState.active
              ? SyncChangeKind.delete
              : SyncChangeKind.restore)
        : SyncChangeKind.patch;
    final fields = kind == SyncChangeKind.delete
        ? const <String, Object?>{}
        : {random.nextBool() ? 'title' : 'body': 'graph-$seed-$author-$round'};
    await write(author, record, kind, fields);
    if ((round + 1) % 4 == 0) {
      // One author reconnects briefly while the other partition stays behind.
      final connected = random.nextInt(participants.length);
      participants[connected].applyBatch(history);
    }
  }
  return history;
}

String _fingerprint(SyncReplica replica) {
  final devices = replica.watermark.counters.keys.toList()..sort();
  final material = {
    'watermarks': {
      for (final device in devices) device: replica.watermark[device],
    },
    'records': [for (final key in records) _recordDigest(replica.read(key)!)],
  };
  return sha256.convert(utf8.encode(jsonEncode(material))).toString();
}

Map<String, Object> _recordDigest(SyncRecord record) {
  final keys = record.fields.keys.toList()..sort();
  return {
    'id': record.key.id,
    'state': record.state.name,
    'tombstones': [
      for (final dot in record.tombstones) [dot.deviceId, dot.counter],
    ],
    'fields': {
      for (final key in keys)
        key: [
          for (final item in record.fields[key]!)
            [item.dot.deviceId, item.dot.counter, item.value],
        ],
    },
  };
}
