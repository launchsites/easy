import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:easy/sync/workspace_sync.dart';
import 'package:flutter_test/flutter_test.dart';

const _note = (kind: SyncRecordKind.note, id: 'note-1');
const _task = (kind: SyncRecordKind.task, id: 'task-1');

void main() {
  late SyncWorkspaceId workspace;
  late SyncDeviceIdentity a;
  late SyncDeviceIdentity b;
  late SyncDeviceIdentity c;
  late SyncTrust trust;

  setUp(() async {
    workspace = SyncWorkspaceId.generate();
    final identities = await Future.wait([
      SyncDeviceIdentity.fromSeed(Uint8List.fromList(List.filled(32, 11))),
      SyncDeviceIdentity.fromSeed(Uint8List.fromList(List.filled(32, 22))),
      SyncDeviceIdentity.fromSeed(Uint8List.fromList(List.filled(32, 33))),
    ]);
    [a, b, c] = identities;
    trust = SyncTrust(
      workspace,
      approved: identities.map((id) => id.publicKey),
    );
  });

  tearDown(() {
    a.destroy();
    b.destroy();
    c.destroy();
  });

  Future<VerifiedSyncChange> sign(
    SyncReplica replica,
    SyncDeviceIdentity device, {
    SyncRecordKey record = _note,
    SyncChangeKind kind = SyncChangeKind.patch,
    Map<String, Object?> fields = const {},
  }) async => trust.verify(
    await device.sign(
      replica.nextChange(
        deviceId: device.deviceId,
        record: record,
        kind: kind,
        fields: fields,
      ),
    ),
  );

  test(
    'device key persistence preserves its fingerprint and detached signatures',
    () async {
      final seed = await a.copySeedForSecureStorage();
      final imported = await SyncDeviceIdentity.fromSeed(seed);
      addTearDown(imported.destroy);
      seed.fillRange(0, seed.length, 0);
      expect(a.deviceId, imported.deviceId);
      final public = SyncDevicePublicKey.fromBytes(
        imported.publicKey.key.bytes,
      );
      expect(public.fingerprint, a.deviceId);
      expect(public.key.bytes, hasLength(32));

      final original = await sign(
        SyncReplica(trust),
        a,
        fields: {'title': 'Original'},
      );
      final raw = original.signed.encode();
      final decoded = SignedSyncChange.decode(raw);
      expect(decoded.encode(), raw);
      expect((await trust.verify(decoded)).fingerprint, original.fingerprint);

      final changed = jsonDecode(raw) as List<dynamic>;
      changed[0] = (changed[0] as String).replaceFirst('Original', 'Altered');
      await expectLater(
        trust.verify(SignedSyncChange.decode(jsonEncode(changed))),
        throwsA(isA<SyncAuthenticationException>()),
      );
      await expectLater(
        b.sign(original.change),
        throwsA(isA<SyncTrustException>()),
      );
    },
  );

  test(
    'approval is workspace-scoped and revocation invalidates old grants',
    () async {
      final original = await sign(
        SyncReplica(trust),
        a,
        fields: {'title': 'Private'},
      );
      final detached = original.signed;
      final noGrant = SyncTrust(workspace, approved: [b.publicKey]);
      final otherWorkspace = SyncTrust(
        SyncWorkspaceId.generate(),
        approved: [a.publicKey],
      );
      await expectLater(
        noGrant.verify(detached),
        throwsA(isA<SyncTrustException>()),
      );
      await expectLater(
        otherWorkspace.verify(detached),
        throwsA(isA<SyncTrustException>()),
      );
      expect(
        () => SyncReplica(noGrant).apply(original),
        throwsA(isA<SyncTrustException>()),
      );

      final replica = SyncReplica(trust);
      expect(trust.revoke(a.deviceId), isTrue);
      expect(() => replica.apply(original), throwsA(isA<SyncTrustException>()));
      trust.approve(a.publicKey);
      expect(() => replica.apply(original), throwsA(isA<SyncTrustException>()));
      final approvedAgain = await trust.verify(detached);
      expect(replica.apply(approvedAgain).status, SyncApplyStatus.applied);
    },
  );

  test(
    'encrypted envelopes bind ordered peers and workspace before decoding',
    () async {
      final first = await sign(
        SyncReplica(trust),
        a,
        fields: {'body': 'Private note content'},
      );
      final second = await sign(
        SyncReplica(trust),
        c,
        record: _task,
        fields: {'title': 'Forwarded'},
      );
      final key = SyncPairKey.generate();
      final imported = SyncPairKey.fromBytes(key.copyBytesForSecureStorage());
      final wrongKey = SyncPairKey.generate();
      addTearDown(key.destroy);
      addTearDown(wrongKey.destroy);
      addTearDown(imported.destroy);
      const codec = SyncEnvelopeCodec();
      Future<Uint8List> frame() => codec.seal(
        trust: trust,
        senderId: a.deviceId,
        recipientId: b.deviceId,
        key: key,
        changes: [first, second],
      );

      final encrypted = await frame();
      expect(encrypted, isNot(equals(await frame())));
      expect(latin1.decode(encrypted), isNot(contains('Private note content')));
      final remote = SyncTrust(
        workspace,
        approved: [a.publicKey, b.publicKey, c.publicKey],
      );
      final results = await codec.open(
        envelope: encrypted,
        trust: remote,
        senderId: a.deviceId,
        recipientId: b.deviceId,
        key: imported,
      );
      expect(results.map((result) => result.change.dot.deviceId), [
        a.deviceId,
        c.deviceId,
      ]);
      final destination = SyncReplica(remote);
      expect(destination.applyBatch(results).applied, hasLength(2));
      expect(
        destination.read(_note)?.fields['body']?.single.value,
        'Private note content',
      );

      for (final invalid in [
        codec.open(
          envelope: encrypted,
          trust: remote,
          senderId: b.deviceId,
          recipientId: a.deviceId,
          key: imported,
        ),
        codec.open(
          envelope: encrypted,
          trust: remote,
          senderId: a.deviceId,
          recipientId: c.deviceId,
          key: imported,
        ),
        codec.open(
          envelope: encrypted,
          trust: remote,
          senderId: a.deviceId,
          recipientId: b.deviceId,
          key: wrongKey,
        ),
        codec.open(
          envelope: encrypted,
          trust: SyncTrust(
            SyncWorkspaceId.generate(),
            approved: [a.publicKey, b.publicKey],
          ),
          senderId: a.deviceId,
          recipientId: b.deviceId,
          key: imported,
        ),
      ]) {
        await expectLater(invalid, throwsA(isA<SyncAuthenticationException>()));
      }

      final altered = Uint8List.fromList(encrypted);
      altered[altered.length - 1] ^= 1;
      await expectLater(
        codec.open(
          envelope: altered,
          trust: remote,
          senderId: a.deviceId,
          recipientId: b.deviceId,
          key: imported,
        ),
        throwsA(isA<SyncAuthenticationException>()),
      );
      remote.revoke(c.deviceId);
      await expectLater(
        codec.open(
          envelope: encrypted,
          trust: remote,
          senderId: a.deviceId,
          recipientId: b.deviceId,
          key: imported,
        ),
        throwsA(isA<SyncTrustException>()),
      );
    },
  );

  test('format and resource limits run before applying remote data', () async {
    final replica = SyncReplica(trust);
    final original = await sign(replica, a, fields: {'body': 'Original'});
    expect(
      () => SyncChange.decode(' ${original.change.canonical}'),
      throwsFormatException,
    );
    expect(
      () => SyncChange.decode('${'[' * 50}0${']' * 50}'),
      throwsFormatException,
    );
    expect(
      () => SyncWorkspaceId('${workspace.value}\n'),
      throwsFormatException,
    );
    expect(
      () => replica.nextChange(
        deviceId: a.deviceId,
        record: _note,
        kind: SyncChangeKind.patch,
        fields: {'body': 'é' * (64 * 1024)},
      ),
      throwsFormatException,
    );
    final cycle = <Object?>[];
    cycle.add(cycle);
    expect(
      () => replica.nextChange(
        deviceId: a.deviceId,
        record: _note,
        kind: SyncChangeKind.patch,
        fields: {'body': cycle},
      ),
      throwsFormatException,
    );
    final key = SyncPairKey.generate();
    addTearDown(key.destroy);
    const codec = SyncEnvelopeCodec();
    for (final bytes in [
      Uint8List(0),
      Uint8List(SyncEnvelopeCodec.maximumBytes + 1),
    ]) {
      await expectLater(
        codec.open(
          envelope: bytes,
          trust: trust,
          senderId: a.deviceId,
          recipientId: b.deviceId,
          key: key,
        ),
        throwsFormatException,
      );
    }
    expect(replica.journalLength, 0);
  });

  test('wire numbers have the same JSON form across native and web', () async {
    final original = await sign(
      SyncReplica(trust),
      a,
      fields: {
        'measurements': [1.0, 0.0, -0.0, 0.0000001, 1.234567890123],
      },
    );
    expect(
      original.change.canonical,
      endsWith('"measurements":[1,0,0,1e-7,1.234567890123]}}'),
    );
    final decoded = SignedSyncChange.decode(original.signed.encode());
    expect(await trust.verify(decoded), isA<VerifiedSyncChange>());
  });

  test('opens an independent Ed25519 and AES-GCM framing fixture', () async {
    // Python cryptography 50.0.0 produced this fixture using fixed test keys.
    const frame =
        'RUFTWVNZTgABASNFZ4mrze8BI0VniavN7/33KgiPGPc5noxSvORIRBUB91mllahpgOXZpCKgHl1VF'
        'oxZpUoNW2xihnWPFXffZwN9xUvt/UAJapECzD0+PqoAAQIDBAUGBwgJCgscWfRgmce0fv8y/uTftV'
        'pXsvrbFocULRdLF4TmeDUiiF0yns2d8iatQpNH1OnlS1yLP1C8aOWX7wmgEiB5gZaKlVqaWP+NBA'
        'V5IsMNitMs0mSorwYQVGEJzcWmqknI37r4wWCDnCL9KPx/W4Z8TRVLi1JSmoXyEKMsym74495YN4'
        'NiZfPQ7qpnOtMpkQy/eaYDwb8XGU2xKeMqhgOfoLXMqaayScucoxDTBqWOg6K8wODilgD5zhDTF'
        '7uLrh+h69EpEKiUYqmzlRV6j8TIJLrrkxqxEmEigK1T//WzJGW+pmEPiI2NSW1BDmWCVJdhHSXL'
        '++VXsWyrw34OCxf4wGC7b43Q8vK+MWJV5S4l/kNeb6rRpKnl5fWPF0YVJX+G3xcjfqNqlueMffp'
        'tTCBD/tmx840hbxzGt1uoRVRw8FNzvpzfE0LaBQrb54Q0UTurUg6gI5rP8Cy0Zi3iSh793HrMYH'
        'W3vbNkFqB55fBpzYYkbfeELgqhtXmS1Kh3jeFqe2/4p7ZgWBDq3TRP87KJFnglJA==';
    trust = SyncTrust(
      SyncWorkspaceId('0123456789abcdef0123456789abcdef'),
      approved: [a.publicKey, b.publicKey],
    );
    final key = SyncPairKey.fromBytes(List.generate(32, (index) => index));
    addTearDown(key.destroy);
    final batch = await const SyncEnvelopeCodec().open(
      envelope: base64.decode(frame),
      trust: trust,
      senderId: a.deviceId,
      recipientId: b.deviceId,
      key: key,
    );
    expect(batch.single.change.fields, {'body': 'Independent fixture'});
  });

  test('reordered operations pause until their timestamp-independent causal dependencies arrive', () async {
    final origin = SyncReplica(trust);
    final one = await sign(origin, a, fields: {'body': 'Draft'});
    origin.apply(one);
    final two = await sign(origin, b, fields: {'body': 'Reviewed'});
    origin.apply(two);
    final three = await sign(origin, a, fields: {'title': 'Final'});

    final peer = SyncReplica(trust);
    final deferred = peer.apply(three);
    expect(deferred.status, SyncApplyStatus.deferred);
    expect(deferred.missing.counters, {a.deviceId: 1, b.deviceId: 1});
    expect(peer.journalLength, 0);
    final result = peer.applyBatch([three, two, three, one]);
    expect(result.applied.map((signed) => signed.change.dot), [
      one.change.dot,
      two.change.dot,
      three.change.dot,
    ]);
    expect(result.duplicates, 1);
    expect(result.deferred, isEmpty);
    expect(peer.apply(three).status, SyncApplyStatus.duplicate);
    expect(peer.read(_note)?.fields['body']?.single.value, 'Reviewed');
    expect(
      peer.changesAfter(one.change.context, limit: 1).single.change.dot,
      one.change.dot,
    );
    expect(peer.changesAfter(peer.watermark), isEmpty);
  });

  test('independent fields merge and competing text remains until explicitly selected', () async {
    final left = SyncReplica(trust);
    final right = SyncReplica(trust);
    final first = await sign(
      left,
      a,
      fields: {'title': 'Left title', 'body': 'Left body'},
    );
    final second = await sign(
      right,
      b,
      fields: {'title': 'Right title', 'category': 'Work'},
    );
    for (final (replica, changes) in [
      (left, [first, second]),
      (right, [second, first]),
    ]) {
      replica.applyBatch(changes);
      expect(replica.read(_note)?.hasFieldConflict('title'), isTrue);
      expect(replica.read(_note)?.fields['body']?.single.value, 'Left body');
      expect(replica.read(_note)?.fields['category']?.single.value, 'Work');
    }
    final resolve = await sign(left, a, fields: {'title': 'Our title'});
    for (final replica in [left, right]) {
      replica.apply(resolve);
      expect(replica.read(_note)?.hasConflicts, isFalse);
      expect(replica.read(_note)?.fields['title']?.single.value, 'Our title');
    }

    final matching = SyncReplica(trust);
    final sameA = await sign(
      matching,
      a,
      fields: {
        'body': {
          'zeta': 1,
          'alpha': [2],
        },
      },
    );
    final sameB = await sign(
      matching,
      b,
      fields: {
        'body': {
          'alpha': [2],
          'zeta': 1,
        },
      },
    );
    matching.applyBatch([sameA, sameB]);
    final variants = matching.read(_note)?.fields['body'];
    expect(variants, hasLength(2));
    expect(matching.read(_note)?.hasConflicts, isFalse);
  });

  test('delete-versus-edit keeps text recoverable until explicit restore or delete', () async {
    final origin = SyncReplica(trust);
    final seed = await sign(origin, a, fields: {'body': 'Draft'});
    origin.apply(seed);
    final delete = await sign(origin, a, kind: SyncChangeKind.delete);
    final edit = await sign(origin, b, fields: {'body': 'Offline edit'});

    final left = SyncReplica(trust)..applyBatch([delete, seed]);
    expect(left.read(_note)?.state, SyncRecordState.deleted);
    expect(left.read(_note)?.fields['body']?.single.value, 'Draft');
    left.apply(edit);
    final right = SyncReplica(trust)..applyBatch([edit, delete, seed]);
    for (final replica in [left, right]) {
      expect(replica.read(_note)?.state, SyncRecordState.deleteConflict);
      expect(replica.read(_note)?.fields['body']?.single.value, 'Offline edit');
    }

    final laterEdit = await sign(
      left,
      c,
      fields: {'body': 'Updated offline edit'},
    );
    left.apply(laterEdit);
    expect(left.read(_note)?.state, SyncRecordState.deleteConflict);
    final restore = await sign(left, a, kind: SyncChangeKind.restore);
    left.apply(restore);
    right.applyBatch([restore, laterEdit]);
    for (final replica in [left, right]) {
      expect(replica.read(_note)?.state, SyncRecordState.active);
      expect(
        replica.read(_note)?.fields['body']?.single.value,
        'Updated offline edit',
      );
    }
  });

  test('randomized interrupted delivery converges with duplicates and preserved conflicts', () async {
    final source = SyncReplica(trust);
    final first = await sign(
      source,
      a,
      fields: {'title': 'Draft', 'body': 'Shared body'},
    );
    source.apply(first);
    final edit = await sign(source, b, fields: {'title': 'Offline title'});
    final delete = await sign(source, c, kind: SyncChangeKind.delete);
    final own = await sign(source, a, fields: {'title': 'Local title'});
    source.applyBatch([edit, delete, own]);
    final extra = await sign(source, b, record: _task, fields: {'done': true});
    source.apply(extra);
    final expected = _state(source);
    final random = Random(81324);
    for (var iteration = 0; iteration < 120; iteration++) {
      final recipient = SyncReplica(trust);
      final arrival = [first, edit, delete, own, extra, first, own]
        ..shuffle(random);
      var deferred = <VerifiedSyncChange>[];
      for (final arrived in arrival) {
        deferred = recipient
            .applyBatch([arrived, ...deferred])
            .deferred
            .map((waiting) => waiting.change)
            .toList();
      }
      expect(deferred, isEmpty, reason: 'delivery iteration $iteration');
      expect(
        _state(recipient),
        expected,
        reason: 'delivery iteration $iteration',
      );
      expect(recipient.read(_note)?.hasConflicts, isTrue);
    }
  });

  test('equivocation, incomplete causal claims and resource exhaustion fail atomically', () async {
    final source = SyncReplica(trust);
    final first = await sign(source, a, fields: {'body': 'First'});
    final divergent = await sign(source, a, fields: {'body': 'Divergent'});
    final fresh = SyncReplica(trust);
    expect(
      () => fresh.applyBatch([first, divergent]),
      throwsA(isA<SyncHistoryException>()),
    );
    expect(fresh.journalLength, 0);

    source.apply(first);
    final two = await sign(source, b, fields: {'title': 'Second'});
    final incomplete = await trust.verify(
      await c.sign(
        SyncChange(
          workspaceId: workspace,
          dot: (deviceId: c.deviceId, counter: 1),
          context: SyncVersionVector({b.deviceId: 1}),
          record: _note,
          kind: SyncChangeKind.patch,
          fields: {'body': 'Missing historical dependency'},
        ),
      ),
    );
    expect(
      () => fresh.applyBatch([incomplete, two, first]),
      throwsA(isA<SyncHistoryException>()),
    );
    expect(fresh.watermark.counters, isEmpty);
    expect(fresh.read(_note), isNull);

    final bounded = SyncReplica(trust, maximumChanges: 1);
    expect(
      () => bounded.applyBatch([first, two]),
      throwsA(isA<SyncHistoryException>()),
    );
    expect(bounded.journalLength, 0);
    bounded.apply(first);
    expect(() => bounded.apply(two), throwsA(isA<SyncHistoryException>()));
    expect(bounded.apply(first).status, SyncApplyStatus.duplicate);
    expect(bounded.journalLength, 1);
  });
}

Object _state(SyncReplica replica) => {
  'watermark': replica.watermark.counters,
  for (final key in [_note, _task])
    if (replica.read(key) case final record?)
      key.id: {
        'state': record.state,
        'tombstones': record.tombstones,
        'fields': {
          for (final field in record.fields.entries)
            field.key: [
              for (final version in field.value) (version.dot, version.value),
            ],
        },
      },
};
