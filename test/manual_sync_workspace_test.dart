import 'dart:io';

import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _note = (kind: SyncRecordKind.note, id: 'shared-note');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late _TrialVault firstVault;
  late _TrialVault secondVault;
  late SyncDeviceCredentials firstCredentials;
  late SyncDeviceCredentials secondCredentials;
  final workspaces = <ManualSyncWorkspace>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('easy-manual-sync-');
    firstVault = _TrialVault();
    secondVault = _TrialVault();
    firstCredentials = SyncDeviceCredentials(firstVault);
    secondCredentials = SyncDeviceCredentials(secondVault);
  });

  tearDown(() async {
    await Future.wait(workspaces.map((workspace) => workspace.close()));
    workspaces.clear();
    await temporary.delete(recursive: true);
  });

  String path(bool isSecond) =>
      temporary.uri.resolve(isSecond ? 'second.db' : 'first.db').toFilePath();

  Future<ManualSyncWorkspace> create({
    bool isSecond = false,
    SyncWorkspaceId? id,
  }) async {
    final workspace = await ManualSyncWorkspace.create(
      credentials: isSecond ? secondCredentials : firstCredentials,
      workspaceId: id,
      databasePath: path(isSecond),
    );
    workspaces.add(workspace);
    return workspace;
  }

  Future<ManualSyncWorkspace> open(
    SyncWorkspaceId id, {
    bool isSecond = false,
  }) async {
    final workspace = await ManualSyncWorkspace.open(
      credentials: isSecond ? secondCredentials : firstCredentials,
      workspaceId: id,
      databasePath: path(isSecond),
    );
    workspaces.add(workspace);
    return workspace;
  }

  Future<(PairedSyncDevice, PairedSyncDevice)> review(
    ManualSyncWorkspace first,
    ManualSyncWorkspace second,
  ) async {
    final invitation = await first.createInvitation();
    final reply = await second.respond(invitation.code);
    final firstReview = await invitation.receiveResponse(reply.code);
    final firstApproval = await firstReview.confirmComparison(
      reply.review.comparisonCode,
    );
    final secondApproval = await reply.review.confirmComparison(
      firstReview.comparisonCode,
    );
    return (
      await firstReview.finish(secondApproval),
      await reply.review.finish(firstApproval),
    );
  }

  test('system vault adapter keeps a stable installation identity and distinct journal keys', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const credentials = SyncDeviceCredentials(SyncSystemSecretVault());
    expect(await credentials.loadIdentity(), isNull);
    final created = await credentials.createIdentity();
    final reopened = (await credentials.loadIdentity())!;
    addTearDown(created.destroy);
    addTearDown(reopened.destroy);
    expect(created.deviceId, reopened.deviceId);
    await expectLater(
      credentials.createIdentity(),
      throwsA(isA<SyncVaultException>()),
    );
    final space = SyncWorkspaceId.generate();
    final key = await credentials.createJournalKey(space);
    final saved = (await credentials.loadJournalKey(space))!;
    final other = await credentials.createJournalKey(
      SyncWorkspaceId.generate(),
    );
    addTearDown(key.destroy);
    addTearDown(saved.destroy);
    addTearDown(other.destroy);
    expect(key.copyBytesForSecureStorage(), saved.copyBytesForSecureStorage());
    expect(
      key.copyBytesForSecureStorage(),
      isNot(equals(other.copyBytesForSecureStorage())),
    );
  });

  test('manual pairing survives reopen and transfers only through reviewed bundles', () async {
    final first = await create();
    final second = await create(isSecond: true, id: first.workspaceId);
    await expectLater(
      first.exportFor(second.device.fingerprint),
      throwsA(isA<SyncTrustException>()),
    );
    final (firstReview, secondReview) = await review(first, second);
    addTearDown(firstReview.discard);
    addTearDown(secondReview.discard);
    await expectLater(
      second.approvePair(firstReview, expectedRevision: 0),
      throwsA(isA<SyncPairedWorkspaceException>()),
    );
    firstVault.rejectPairWrite = true;
    await expectLater(
      first.approvePair(firstReview, expectedRevision: 0),
      throwsA(isA<SyncVaultException>()),
    );
    expect((await first.status()).approvedDeviceIds, {
      first.device.fingerprint,
    });
    firstVault.rejectPairWrite = false;
    await first.approvePair(firstReview, expectedRevision: 0);
    await second.approvePair(secondReview, expectedRevision: 0);
    final firstStatus = await first.status();
    final secondStatus = await second.status();
    expect(
      firstStatus.approvedPairKeyIds[second.device.fingerprint],
      secondStatus.approvedPairKeyIds[first.device.fingerprint],
    );

    await first.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'title': 'Synthetic planning'},
      expectedRevision: 1,
    );
    final exported = (await first.exportFor(second.device.fingerprint))!;
    expect(exported.changeCount, 1);
    final preview = await second.previewIncoming(
      bytes: exported.bytes,
      senderId: first.device.fingerprint,
    );
    expect(
      preview.records.single.after?.fields['title']?.single.value,
      'Synthetic planning',
    );
    expect(await second.readRecord(_note), isNull);
    await second.commitIncoming(preview);
    await first.close();
    await second.close();

    final reopenedFirst = await open(first.workspaceId);
    final reopenedSecond = await open(first.workspaceId, isSecond: true);
    expect(reopenedFirst.device.fingerprint, first.device.fingerprint);
    final replay = await reopenedSecond.previewIncoming(
      bytes: exported.bytes,
      senderId: reopenedFirst.device.fingerprint,
    );
    expect(replay.changeCount, 0);
    expect(replay.duplicateCount, 1);
    expect(replay.records.single.isReplay, isTrue);
    final reopenedRevision = (await reopenedSecond.status()).revision;
    expect(
      (await reopenedSecond.commitIncoming(replay)).revision,
      reopenedRevision,
    );
    expect(
      (await reopenedSecond.readRecord(_note))?.fields['title']?.single.value,
      'Synthetic planning',
    );
    expect(
      await reopenedFirst.exportFor(
        reopenedSecond.device.fingerprint,
        known: (await reopenedSecond.status()).watermark,
      ),
      isNull,
    );
  });

  test('explicit revocation invalidates stale previews and blocks access even with a locked vault', () async {
    final first = await create();
    final second = await create(isSecond: true, id: first.workspaceId);
    final (firstReview, secondReview) = await review(first, second);
    await first.approvePair(firstReview, expectedRevision: 0);
    await second.approvePair(secondReview, expectedRevision: 0);
    await first.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'title': 'Pending'},
    );
    final bundle = (await first.exportFor(second.device.fingerprint))!;
    final imported = await second.previewIncoming(
      bytes: bundle.bytes,
      senderId: first.device.fingerprint,
    );

    final stale = await second.reviewRevocation(first.device.fingerprint);
    final anotherOwner = await open(second.workspaceId, isSecond: true);
    await expectLater(
      anotherOwner.confirmRevocation(stale),
      throwsA(isA<SyncPairedWorkspaceException>()),
    );
    await anotherOwner.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'body': 'Offline'},
    );
    await expectLater(
      second.confirmRevocation(stale),
      throwsA(isA<SyncJournalRevisionConflict>()),
    );
    final confirm = await second.reviewRevocation(first.device.fingerprint);
    expect(secondVault.pairEntries, 1);
    secondVault.rejectDeletes = true;
    final result = await second.confirmRevocation(confirm);
    expect(result.status.approvedDeviceIds, {second.device.fingerprint});
    expect(result.credentialRemoved, isFalse);
    expect(secondVault.pairEntries, 1);
    await expectLater(
      second.previewIncoming(
        bytes: bundle.bytes,
        senderId: first.device.fingerprint,
      ),
      throwsA(isA<SyncTrustException>()),
    );
    await expectLater(
      second.commitIncoming(imported),
      throwsA(isA<SyncJournalRevisionConflict>()),
    );
    expect(
      (await second.readRecord(_note))?.fields['body']?.single.value,
      'Offline',
    );
    secondVault.rejectDeletes = false;
    expect(await second.retryRevocationCleanup(confirm), isTrue);
    expect(secondVault.pairEntries, 0);
    expect((await anotherOwner.status()).approvedDeviceIds, {
      second.device.fingerprint,
    });
  });

  test('competing pair confirmations bind the active grant to its own immutable vault key', () async {
    final first = await create();
    final second = await create(isSecond: true, id: first.workspaceId);
    final anotherOwner = await open(first.workspaceId);
    final signed1 = await review(first, second);
    final signed2 = await review(anotherOwner, second);
    addTearDown(signed1.$1.discard);
    addTearDown(signed1.$2.discard);
    addTearDown(signed2.$1.discard);
    addTearDown(signed2.$2.discard);

    final approvals = await Future.wait([
      for (final (session, pair) in [
        (first, signed1.$1),
        (anotherOwner, signed2.$1),
      ])
        session
            .approvePair(pair, expectedRevision: 0)
            .then<Object>((result) => result, onError: (Object error) => error),
    ]);
    expect(approvals.whereType<SyncJournalStatus>(), hasLength(1));
    expect(approvals.whereType<SyncJournalRevisionConflict>(), hasLength(1));
    final peerPair = approvals.first is SyncJournalStatus
        ? signed1.$2
        : signed2.$2;
    await second.approvePair(peerPair, expectedRevision: 0);
    await first.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'title': 'Selected pairing'},
    );
    final bundle = (await first.exportFor(second.device.fingerprint))!;
    final preview = await second.previewIncoming(
      bytes: bundle.bytes,
      senderId: first.device.fingerprint,
    );
    expect(preview.changeCount, 1);
  });

  test('opening existing configuration fails closed when the identity or journal key is gone', () async {
    final first = await create();
    await first.close();
    final before = Map.of(firstVault.contents);
    firstVault.contents.removeWhere((key, _) => key.contains('.journal.'));
    final afterDeletion = Map.of(firstVault.contents);
    await expectLater(
      open(first.workspaceId),
      throwsA(isA<SyncVaultException>()),
    );
    expect(firstVault.contents, afterDeletion);
    firstVault.contents
      ..clear()
      ..addAll(before);
    final recovered = await open(first.workspaceId);
    expect(recovered.device.fingerprint, first.device.fingerprint);
  });

  test('opening a missing journal preserves the existing vault and requires explicit recovery', () async {
    final session = await create();
    await session.close();
    final original = File(path(false));
    final saved = await original.rename('${original.path}.saved');
    final secrets = Map.of(firstVault.contents);
    await expectLater(
      open(session.workspaceId),
      throwsA(isA<SyncJournalException>()),
    );
    expect(firstVault.contents, secrets);
    expect(await original.exists(), isFalse);
    await saved.rename(original.path);
    expect(
      (await open(session.workspaceId)).device.fingerprint,
      session.device.fingerprint,
    );
  });

  test('authenticated progress continues from the peer and rejects a reflected receipt', () async {
    final first = await create();
    final second = await create(isSecond: true, id: first.workspaceId);
    final (firstReview, secondReview) = await review(first, second);
    await first.approvePair(firstReview, expectedRevision: 0);
    await second.approvePair(secondReview, expectedRevision: 0);
    await first.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'title': 'First file'},
    );
    final bundle = (await first.exportFor(second.device.fingerprint))!;
    final incoming = await second.previewIncoming(
      bytes: bundle.bytes,
      senderId: first.device.fingerprint,
    );
    await second.commitIncoming(incoming);
    final peerProgress = await second.progressFor(first.device.fingerprint);
    final ownProgress = await first.progressFor(second.device.fingerprint);
    expect(
      await first.exportFor(
        second.device.fingerprint,
        peerProgress: peerProgress,
      ),
      isNull,
    );
    await expectLater(
      first.exportFor(second.device.fingerprint, peerProgress: ownProgress),
      throwsA(isA<SyncAuthenticationException>()),
    );
    await first.writeLocalChange(
      record: _note,
      kind: SyncChangeKind.patch,
      fields: {'body': 'Next file'},
    );
    final next = (await first.exportFor(
      second.device.fingerprint,
      peerProgress: peerProgress,
    ))!;
    expect(next.changeCount, 1);
    final preview = await second.previewIncoming(
      bytes: next.bytes,
      senderId: first.device.fingerprint,
    );
    expect(
      preview.records.single.after?.fields['body']?.single.value,
      'Next file',
    );
  });
}

final class _TrialVault implements SyncSecretVault {
  final contents = <String, String>{};
  var rejectPairWrite = false;
  var rejectDeletes = false;

  int get pairEntries =>
      contents.keys.where((key) => key.contains('.pair.')).length;

  @override
  Future<String?> read(String reference) async => contents[reference];

  @override
  Future<void> write(String reference, String secret) async {
    if (rejectPairWrite && reference.contains('.pair.')) {
      throw StateError('Synthetic vault failure');
    }
    contents[reference] = secret;
  }

  @override
  Future<void> delete(String reference) async {
    if (rejectDeletes) throw StateError('Synthetic vault failure');
    contents.remove(reference);
  }
}
