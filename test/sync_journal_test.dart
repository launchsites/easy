import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy/sync/sync_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _note = (kind: SyncRecordKind.note, id: 'journal-note');
const _task = (kind: SyncRecordKind.task, id: 'journal-task');

void main() {
  late Directory temporary;
  late SyncWorkspaceId workspace;
  late SyncDeviceIdentity first;
  late SyncDeviceIdentity second;
  late SyncJournalKey firstKey;
  late SyncJournalKey secondKey;
  late SyncPairKey pair;
  final journals = <SyncJournal>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('easy-sync-journal-');
    workspace = SyncWorkspaceId.generate();
    first = await SyncDeviceIdentity.generate();
    second = await SyncDeviceIdentity.generate();
    firstKey = SyncJournalKey.generate();
    secondKey = SyncJournalKey.generate();
    pair = SyncPairKey.generate();
  });

  tearDown(() async {
    await Future.wait(journals.map((journal) => journal.close()));
    journals.clear();
    first.destroy();
    second.destroy();
    firstKey.destroy();
    secondKey.destroy();
    pair.destroy();
    await temporary.delete(recursive: true);
  });

  String path(String name) =>
      temporary.uri.resolve('$name.sqlite3').toFilePath();

  Future<SyncJournal> open({
    bool peer = false,
    String? at,
    SyncJournalKey? key,
    SyncWorkspaceId? id,
  }) async {
    final store = (await openSyncJournal(
      workspaceId: id ?? workspace,
      localDevicePublicKey: (peer ? second : first).publicKey,
      journalKey: key ?? (peer ? secondKey : firstKey),
      databasePath: path(at ?? (peer ? 'second' : 'first')),
    ))!;
    journals.add(store);
    return store;
  }

  Future<(SyncJournal, SyncJournal)> paired() async {
    final left = await open();
    final right = await open(peer: true);
    await left.approveDevice(second.publicKey, expectedRevision: 0);
    await right.approveDevice(first.publicKey, expectedRevision: 0);
    return (left, right);
  }

  Future<SyncJournalStatus> edit(
    SyncJournal journal,
    SyncDeviceIdentity identity,
    Map<String, Object?> fields, {
    SyncRecordKey record = _note,
    SyncChangeKind kind = SyncChangeKind.patch,
  }) async {
    final draft = await journal.draftChange(
      record: record,
      kind: kind,
      fields: fields,
    );
    return journal.commitLocal(
      await identity.sign(draft.change),
      expectedRevision: draft.expectedRevision,
    );
  }

  Future<SyncImportPreview> previewFrom(
    SyncJournal left,
    SyncJournal right, {
    SyncVersionVector? known,
  }) async {
    final bundle = (await left.exportChanges(
      recipientId: second.deviceId,
      pairKey: pair,
      known: known ?? (await right.status()).watermark,
    ))!;
    return right.previewImport(
      envelope: bundle.bytes,
      senderId: first.deviceId,
      pairKey: pair,
    );
  }

  test('local commit persists ciphertext, rejects a mismatched key and retries idempotently', () async {
    final journal = await open();
    expect((await journal.status()).approvedDeviceIds, {first.deviceId});
    final change = await journal.draftChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'body': 'Private synthetic journal body'},
    );
    final signed = await first.sign(change.change);
    final stored = await journal.commitLocal(
      signed,
      expectedRevision: change.expectedRevision,
    );
    expect(stored.revision, 1);
    await journal.close();
    final persisted = await File(path('first')).readAsBytes();
    expect(
      latin1.decode(persisted),
      isNot(contains('Private synthetic journal body')),
    );
    expect(latin1.decode(persisted), isNot(contains(_note.id)));

    await expectLater(
      open(key: secondKey),
      throwsA(isA<SyncJournalException>()),
    );
    await expectLater(
      open(id: SyncWorkspaceId.generate()),
      throwsA(isA<SyncJournalException>()),
    );
    final reopened = await open();
    expect(
      (await reopened.readRecord(_note))?.fields['body']?.single.value,
      'Private synthetic journal body',
    );
    final repeated = await reopened.commitLocal(signed, expectedRevision: 0);
    expect(repeated.revision, 1);
    expect(repeated.changes, 1);
  });

  test(
    'separate SQLite owners reject stale drafts and preserve winning changes',
    () async {
      final left = await open();
      final right = await open();
      final a = await left.draftChange(
        record: _note,
        kind: SyncChangeKind.patch,
        fields: {'title': 'Left'},
      );
      final b = await right.draftChange(
        record: _note,
        kind: SyncChangeKind.patch,
        fields: {'title': 'Right'},
      );
      final signed = await Future.wait([
        first.sign(a.change),
        first.sign(b.change),
      ]);
      final results = await Future.wait([
        for (final (store, change) in [(left, signed[0]), (right, signed[1])])
          store
              .commitLocal(change, expectedRevision: 0)
              .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(results.whereType<SyncJournalStatus>(), hasLength(1));
      expect(results.whereType<SyncJournalRevisionConflict>(), hasLength(1));
      expect((await left.status()).revision, 1);
      expect((await right.status()).revision, 1);
      expect(
        (await left.readRecord(_note))?.fields['title']?.single.value,
        (await right.readRecord(_note))?.fields['title']?.single.value,
      );
    },
  );

  test(
    'a write interruption rolls back the encrypted row and head together',
    () async {
      final journal = await open();
      final draft = await journal.draftChange(
        record: _note,
        kind: SyncChangeKind.patch,
        fields: {'title': 'Retry'},
      );
      final signed = await first.sign(draft.change);
      final db = sqlite3.open(path('first'));
      addTearDown(db.close);
      db.execute('''
      CREATE TRIGGER fail_head BEFORE UPDATE ON sync_head
      BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END;
    ''');
      await expectLater(
        journal.commitLocal(signed, expectedRevision: 0),
        throwsA(isA<SyncJournalException>()),
      );
      expect((await journal.status()).revision, 0);
      expect(await journal.readRecord(_note), isNull);
      expect(
        db.select('SELECT COUNT(*) AS count FROM sync_entry').single['count'],
        0,
      );
      db.execute('DROP TRIGGER fail_head');
      await journal.close();
      final reopened = await open();
      expect(
        (await reopened.commitLocal(signed, expectedRevision: 0)).revision,
        1,
      );
    },
  );

  test('a missing or altered encrypted history row fails closed', () async {
    final journal = await open();
    await edit(journal, first, {'title': 'First'});
    await edit(journal, first, {'title': 'Second'});
    await journal.close();
    final db = sqlite3.open(path('first'));
    addTearDown(db.close);
    final ciphertext =
        db
                .select('SELECT encrypted FROM sync_entry WHERE revision = 1')
                .single['encrypted']
            as Uint8List;
    final altered = Uint8List.fromList(ciphertext)..[32] ^= 1;
    db.execute('UPDATE sync_entry SET encrypted = ? WHERE revision = 1', [
      altered,
    ]);
    await expectLater(open(), throwsA(isA<SyncJournalException>()));
    db.execute('DELETE FROM sync_entry WHERE revision = 1');
    await expectLater(open(), throwsA(isA<SyncJournalException>()));
    expect(db.select('SELECT revision FROM sync_head').single['revision'], 2);
  });

  test('deletion and concurrent edits require separate approvals and survive reopen', () async {
    final (left, right) = await paired();
    await edit(left, first, {'body': 'Shared original'});
    await right.commitImport(await previewFrom(left, right));
    await edit(right, second, {'body': 'Offline work'});
    await edit(left, first, {}, kind: SyncChangeKind.delete);

    final preview = await previewFrom(left, right);
    expect(preview.changeCount, 1);
    expect(preview.hasDestructiveChanges, isTrue);
    expect(preview.hasConflicts, isTrue);
    expect(preview.records.single.before?.state, SyncRecordState.active);
    expect(preview.records.single.after?.state, SyncRecordState.deleteConflict);
    expect((await right.readRecord(_note))?.state, SyncRecordState.active);

    Matcher approval(SyncImportApproval type) => throwsA(
      isA<SyncImportApprovalRequired>().having(
        (error) => error.approval,
        'approval',
        type,
      ),
    );
    await expectLater(
      right.commitImport(preview),
      approval(SyncImportApproval.destructiveChanges),
    );
    await expectLater(
      right.commitImport(preview, approveDestructiveChanges: true),
      approval(SyncImportApproval.conflicts),
    );
    final committed = await right.commitImport(
      preview,
      approveDestructiveChanges: true,
      approveConflicts: true,
    );
    expect(committed.changes, 3);
    await right.close();
    final reopened = await open(peer: true);
    final conflict = await reopened.readRecord(_note);
    expect(conflict?.state, SyncRecordState.deleteConflict);
    expect(conflict?.fields['body']?.single.value, 'Offline work');
    await edit(reopened, second, {}, kind: SyncChangeKind.restore);
    expect((await reopened.readRecord(_note))?.state, SyncRecordState.active);
  });

  test(
    'stale and cross-session previews never import changes or skip consent',
    () async {
      final (left, right) = await paired();
      await edit(left, first, {'body': 'Incoming'});
      final preview = await previewFrom(left, right);
      final sameDatabase = await open(peer: true);
      await expectLater(
        sameDatabase.commitImport(preview),
        throwsA(isA<SyncJournalException>()),
      );
      await edit(sameDatabase, second, {'done': true}, record: _task);
      await expectLater(
        right.commitImport(preview),
        throwsA(isA<SyncJournalRevisionConflict>()),
      );
      expect(await right.readRecord(_note), isNull);
      await right.commitImport(await previewFrom(left, right));
      expect(
        (await right.readRecord(_task))?.fields['done']?.single.value,
        true,
      );
      final repeated = await previewFrom(
        left,
        right,
        known: const SyncVersionVector.empty(),
      );
      expect(repeated.changeCount, 0);
      expect(repeated.duplicateCount, 1);
      final revision = (await right.status()).revision;
      expect((await right.commitImport(repeated)).revision, revision);
    },
  );

  test(
    'unapproved, revoked and causally incomplete batches cannot change records',
    () async {
      final left = await open();
      final right = await open(peer: true);
      await expectLater(
        left.exportChanges(recipientId: second.deviceId, pairKey: pair),
        throwsA(isA<SyncTrustException>()),
      );
      await left.approveDevice(second.publicKey, expectedRevision: 0);
      await right.approveDevice(first.publicKey, expectedRevision: 0);
      await edit(left, first, {'title': 'Earlier'});
      await edit(left, first, {'body': 'Later'});

      final later = await previewFrom(
        left,
        right,
        known: SyncVersionVector({first.deviceId: 1}),
      );
      expect(later.missing.counters, {first.deviceId: 1});
      await expectLater(
        right.commitImport(later),
        throwsA(isA<SyncJournalException>()),
      );
      expect(await right.readRecord(_note), isNull);
      await right.commitImport(await previewFrom(left, right));
      final prior = await right.status();
      await right.revokeDevice(
        first.deviceId,
        expectedRevision: prior.revision,
      );
      await right.close();
      final reopened = await open(peer: true);
      expect((await reopened.status()).approvedDeviceIds, {second.deviceId});
      expect(
        (await reopened.readRecord(_note))?.fields['body']?.single.value,
        'Later',
      );
      final sent = (await left.exportChanges(
        recipientId: second.deviceId,
        pairKey: pair,
      ))!;
      await expectLater(
        reopened.previewImport(
          envelope: sent.bytes,
          senderId: first.deviceId,
          pairKey: pair,
        ),
        throwsA(isA<SyncTrustException>()),
      );
    },
  );

  test('large changes paginate within the encrypted frame budget', () async {
    final (left, right) = await paired();
    for (var index = 0; index < 20; index++) {
      await edit(
        left,
        first,
        {'body': 'x' * 60000},
        record: (kind: SyncRecordKind.note, id: 'bulk-$index'),
      );
    }
    final firstPage = (await left.exportChanges(
      recipientId: second.deviceId,
      pairKey: pair,
    ))!;
    expect(firstPage.hasMore, isTrue);
    expect(
      firstPage.bytes.length,
      lessThanOrEqualTo(SyncEnvelopeCodec.maximumBytes),
    );
    expect(firstPage.changeCount, inInclusiveRange(1, 19));
    await right.commitImport(
      await right.previewImport(
        envelope: firstPage.bytes,
        senderId: first.deviceId,
        pairKey: pair,
      ),
    );
    final secondPage = (await left.exportChanges(
      recipientId: second.deviceId,
      pairKey: pair,
      known: (await right.status()).watermark,
    ))!;
    expect(secondPage.hasMore, isFalse);
    await right.commitImport(
      await right.previewImport(
        envelope: secondPage.bytes,
        senderId: first.deviceId,
        pairKey: pair,
      ),
    );
    expect((await right.status()).changes, 20);
  });
}
