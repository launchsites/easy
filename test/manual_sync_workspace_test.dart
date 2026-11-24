import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy/storage/workspace_store.dart';
import 'package:easy/sync/manual_sync_contracts.dart';
import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:easy/sync/workspace_manual_sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _note = (kind: SyncRecordKind.note, id: 'shared-note');
const _task = (kind: SyncRecordKind.task, id: 'focus-task');
const _event = (kind: SyncRecordKind.calendarEvent, id: 'calendar-event');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late _TrialVault firstVault;
  late _TrialVault secondVault;
  late SyncDeviceCredentials firstCredentials;
  late SyncDeviceCredentials secondCredentials;
  final workspaces = <ManualSyncWorkspace>[];

  setUp(() async {
    final previousPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(
      () => SharedPreferencesAsyncPlatform.instance = previousPreferences,
    );
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
  Future<(ManualSyncWorkspace, ManualSyncWorkspace)> pair() async {
    final first = await create();
    final second = await create(isSecond: true, id: first.workspaceId);
    final (left, right) = await review(first, second);
    addTearDown(left.discard);
    addTearDown(right.discard);
    await first.approvePair(left, expectedRevision: 0);
    await second.approvePair(right, expectedRevision: 0);
    return (first, second);
  }

  Future<WorkspaceStore> localStore(
    String name,
    WorkspaceSnapshot seed, {
    bool preferences = false,
  }) async {
    final store = await openWorkspaceStore(
      preferences: SharedPreferencesAsync(),
      databasePath: preferences
          ? null
          : temporary.uri.resolve('$name.sqlite').toFilePath(),
      readLegacy: () async => seed,
      usePreferences: preferences,
    );
    addTearDown(store.close);
    return store;
  }

  Future<ManualSyncProjectionPreview> receive(
    ManualSyncWorkspace sender,
    ManualSyncWorkspace receiver,
    WorkspaceManualSyncProjector target, {
    bool approveRemovals = false,
  }) async {
    final bytes = (await sender.exportFor(receiver.device.fingerprint))!.bytes;
    final imported = await receiver.previewIncoming(
      bytes: bytes,
      senderId: sender.device.fingerprint,
    );
    final committed = await receiver.commitIncoming(
      imported,
      approveDestructiveChanges: approveRemovals,
    );
    return target.previewIncoming(
      sync: receiver,
      imported: imported,
      committed: committed,
    );
  }

  for (final preferences in [false, true]) {
    test(
      'selected records move through a verified bundle and durable recovery ($preferences preferences)',
      () async {
        final (sender, receiver) = await pair();
        final source = await localStore('source', _sourceSnapshot());
        final initial = _snapshot(
          notes: [
            _noteRow(title: 'Recipient title', body: 'Recipient private edit'),
          ],
          sections: {
            'unrecognizedSection': {
              'roundTrip': [1, true, 'keep'],
            },
          },
        );
        final destination = await localStore(
          'destination',
          initial,
          preferences: preferences,
        );
        var flushCount = 0;
        final loaded = <WorkspaceRevision>[];
        final exporter = WorkspaceManualSyncProjector(
          store: source,
          flushWorkspaceWrites: () async => flushCount++,
        );
        final importer = WorkspaceManualSyncProjector(
          store: destination,
          onRestored: (saved) async {
            loaded.add(saved);
          },
        );

        final search = await exporter.previewOutgoing(
          sync: sender,
          query: 'café',
        );
        expect(search.records.map((row) => row.key), [_note]);
        final outgoing = await exporter.previewOutgoing(sync: sender);
        expect(outgoing.records.map((row) => row.key).toSet(), {
          _task,
          _event,
          _note,
          (kind: SyncRecordKind.note, id: 'keep-local'),
        });
        expect(await sender.exportFor(receiver.device.fingerprint), isNull);
        await expectLater(
          exporter.stageOutgoing(
            outgoing,
            selected: {
              _note,
              (kind: SyncRecordKind.calendarEvent, id: 'apple:external'),
            },
          ),
          throwsA(isA<SyncJournalException>()),
        );
        final expectedJournalRevision = outgoing.syncRevision + 1;
        expect(
          await exporter.stageOutgoing(
            outgoing,
            selected: {_task, _event, _note},
          ),
          3,
        );
        expect((await sender.status()).revision, expectedJournalRevision);
        expect((await sender.status()).changes, 3);
        expect(
          await exporter.stageOutgoing(
            await exporter.previewOutgoing(sync: sender),
            selected: {_note},
          ),
          0,
        );
        expect((await sender.status()).revision, expectedJournalRevision);
        expect(flushCount, greaterThanOrEqualTo(4));

        final bundle = (await sender.exportFor(receiver.device.fingerprint))!;
        final imported = await receiver.previewIncoming(
          bytes: bundle.bytes,
          senderId: sender.device.fingerprint,
        );
        final beforeCommit = await receiver.status();
        await expectLater(
          importer.previewIncoming(
            sync: receiver,
            imported: imported,
            committed: beforeCommit,
          ),
          throwsA(isA<SyncJournalException>()),
        );
        final committed = await receiver.commitIncoming(imported);
        final preview = await importer.previewIncoming(
          sync: receiver,
          imported: imported,
          committed: committed,
        );
        expect(preview.records.map((row) => row.key).toSet(), {
          _task,
          _event,
          _note,
        });
        final note = preview.records.firstWhere((row) => row.key == _note);
        expect(note.action, ManualSyncProjectionAction.update);
        expect(note.localDetails, contains('Recipient private edit'));
        expect(note.incomingDetails, contains('café'));
        expect(
          (await destination.read()).snapshot.workspaceJson,
          initial.workspaceJson,
        );
        await expectLater(
          importer.applyIncoming(preview, selected: {_note}),
          throwsA(
            isA<SyncJournalException>().having(
              (e) => e.message,
              'message',
              contains('linked'),
            ),
          ),
        );
        expect(await destination.readRecoveryBackup(), isNull);
        final applied = await importer.applyIncoming(
          preview,
          selected: {_task, _event, _note},
        );
        expect(loaded.single, same(applied));
        final projected = jsonDecode(applied.snapshot.workspaceJson) as Map;
        expect(projected['unrecognizedSection'], {
          'roundTrip': [1, true, 'keep'],
        });
        expect(projected['notes'], [
          _noteRow(
            title: 'Source planning',
            body: 'café prep',
            links: [
              {'id': _task.id, 'kind': 'task'},
              {'id': _event.id, 'kind': 'event', 'title': 'Focus day'},
            ],
          ),
        ]);
        expect(
          (projected['tasks'] as List).single['date'],
          '2026-11-24T00:00:00.000',
        );
        expect((projected['tasks'] as List).single['estimatedMinutes'], 45);
        expect(
          (projected['events'] as List).single['start'],
          '2026-11-24T00:00:00.000',
        );
        expect(
          (projected['events'] as List).single['end'],
          '2026-11-25T00:00:00.000',
        );
        expect(applied.snapshot.gymSessionJson, initial.gymSessionJson);
        final recovery = (await destination.readRecoveryBackup())!;
        expect(
          (await destination.previewBackup(recovery)).snapshot.workspaceJson,
          initial.workspaceJson,
        );

        projected['unrecognizedSection'] = {'laterEdit': true};
        final later = await destination.save(
          WorkspaceMutation.workspace(jsonEncode(projected)),
        );
        final repeated = await importer.applyIncoming(
          preview,
          selected: {_note, _event, _task},
        );
        expect(repeated.revision, later.revision);
        expect(repeated.snapshot.workspaceJson, later.snapshot.workspaceJson);
        expect(loaded.last.revision, later.revision);
        expect(await destination.readRecoveryBackup(), recovery);
      },
    );
  }

  test(
    'stale reviews fail before changing the journal or live workplace',
    () async {
      final (sender, receiver) = await pair();
      final source = await localStore('source', _sourceSnapshot());
      final destination = await localStore('destination', _snapshot());
      final exporter = WorkspaceManualSyncProjector(store: source);
      final importer = WorkspaceManualSyncProjector(store: destination);
      final outgoing = await exporter.previewOutgoing(sync: sender);
      await source.save(
        WorkspaceMutation.workspace(
          _sourceSnapshot({'edited': 1}).workspaceJson,
        ),
      );
      await expectLater(
        exporter.stageOutgoing(outgoing, selected: {_task}),
        throwsA(isA<WorkspaceRevisionConflict>()),
      );
      expect((await sender.status()).changes, 0);

      final fresh = await exporter.previewOutgoing(sync: sender);
      await sender.writeLocalChange(
        record: (kind: SyncRecordKind.note, id: 'opaque'),
        kind: SyncChangeKind.patch,
        fields: {'title': 'Unsupported journal data'},
      );
      await expectLater(
        exporter.stageOutgoing(fresh, selected: {_task}),
        throwsA(isA<SyncJournalRevisionConflict>()),
      );
      final stage = await exporter.previewOutgoing(sync: sender);
      await exporter.stageOutgoing(stage, selected: {_task});

      final preview = await receive(sender, receiver, importer);
      expect(
        preview.records.singleWhere((row) => row.key == _task).selectable,
        isTrue,
      );
      expect(
        preview.records.singleWhere((row) => row.key.id == 'opaque').selectable,
        isFalse,
      );
      final staleCopy = ManualSyncProjectionPreview(
        syncWorkspaceId: preview.syncWorkspaceId,
        syncRevision: preview.syncRevision,
        expectedWorkspaceRevision: preview.expectedWorkspaceRevision,
        records: preview.records,
      );
      await expectLater(
        importer.applyIncoming(staleCopy, selected: {_task}),
        throwsA(isA<SyncJournalException>()),
      );
      final other = await open(receiver.workspaceId, isSecond: true);
      await other.writeLocalChange(
        record: (kind: SyncRecordKind.note, id: 'other-edit'),
        kind: SyncChangeKind.patch,
        fields: {'title': 'New journal head'},
      );
      await expectLater(
        importer.applyIncoming(preview, selected: {_task}),
        throwsA(isA<SyncJournalRevisionConflict>()),
      );
      final again = await receive(sender, receiver, importer);
      expect(
        again.records.singleWhere((row) => row.key == _task).selectable,
        isTrue,
      );
      final later = await destination.save(
        WorkspaceMutation.workspace(
          _snapshot(sections: {'lateEdit': true}).workspaceJson,
        ),
      );
      await expectLater(
        importer.applyIncoming(again, selected: {_task}),
        throwsA(isA<WorkspaceRevisionConflict>()),
      );
      expect(
        (await destination.read()).snapshot.workspaceJson,
        later.snapshot.workspaceJson,
      );
      expect(await destination.readRecoveryBackup(), isNull);
    },
  );

  test('typed removal protects local edits and references until separately reviewed', () async {
    final (sender, receiver) = await pair();
    final source = await localStore('source', _sourceSnapshot());
    final destination = await localStore(
      'destination',
      _snapshot(
        tasks: [
          _taskRow(),
          _taskRow(id: 'dependent', parent: _task.id),
        ],
        notes: [_noteRow(title: 'Distinct local version')],
      ),
    );
    final exporter = WorkspaceManualSyncProjector(store: source);
    final importer = WorkspaceManualSyncProjector(store: destination);
    final stage = await exporter.previewOutgoing(sync: sender);
    await exporter.stageOutgoing(stage, selected: {_task, _note});
    await sender.writeLocalChange(record: _task, kind: SyncChangeKind.delete);
    await sender.writeLocalChange(record: _note, kind: SyncChangeKind.delete);

    final preview = await receive(
      sender,
      receiver,
      importer,
      approveRemovals: true,
    );
    expect(
      preview.records.singleWhere((row) => row.key == _task).action,
      ManualSyncProjectionAction.remove,
    );
    final edited = preview.records.singleWhere((row) => row.key == _note);
    expect(edited.selectable, isFalse);
    expect(edited.localDetails, contains('Note'));
    await expectLater(
      importer.applyIncoming(preview, selected: {_task}),
      throwsA(
        isA<SyncJournalException>().having(
          (e) => e.message,
          'message',
          contains('links'),
        ),
      ),
    );
    final independent = _snapshot(
      tasks: [_taskRow()],
      notes: [_noteRow(title: 'Distinct local version')],
    );
    await destination.save(
      WorkspaceMutation.workspace(independent.workspaceJson),
    );
    final second = await receive(
      sender,
      receiver,
      importer,
      approveRemovals: true,
    );
    final removed = await importer.applyIncoming(second, selected: {_task});
    expect(
      (jsonDecode(removed.snapshot.workspaceJson) as Map)['tasks'],
      isEmpty,
    );
    expect(await destination.readRecoveryBackup(), isNotNull);
    expect(
      (await destination.previewBackup(
        (await destination.readRecoveryBackup())!,
      )).snapshot.workspaceJson,
      independent.workspaceJson,
    );
  });

  test('journal revision lease excludes competing connections and releases after workspace failure', () async {
    final first = await create();
    final other = await open(first.workspaceId);
    final entered = Completer<void>();
    final release = Completer<void>();
    final revision = (await first.status()).revision;
    final projection = first.applyAtRevision<void>(revision, () async {
      entered.complete();
      await release.future;
      throw const WorkspaceStoreException('Deliberate workspace failure.');
    });
    final failed = expectLater(
      projection,
      throwsA(isA<WorkspaceStoreException>()),
    );
    await entered.future;
    var committed = false;
    final writer = other
        .writeLocalChange(
          record: _note,
          kind: SyncChangeKind.patch,
          fields: {'title': 'Other connection'},
          expectedRevision: revision,
        )
        .then((status) {
          committed = true;
          return status;
        });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(committed, isFalse);
    expect((await first.status()).revision, revision);
    release.complete();
    await failed;
    expect((await writer).revision, revision + 1);
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

Map<String, Object?> _taskRow({String id = 'focus-task', String? parent}) => {
  'id': id,
  'title': 'Plan focus window',
  'category': 'work',
  'done': false,
  'date': '2026-11-24T00:00:00.000',
  'estimatedMinutes': 45,
  'parentId': ?parent,
};

Map<String, Object?> _eventRow({String id = 'calendar-event', String? task}) =>
    {
      'id': id,
      'title': 'Focus day',
      'category': 'work',
      'allDay': true,
      'start': '2026-11-24T00:00:00.000',
      'end': '2026-11-25T00:00:00.000',
      'plannedTaskId': ?task,
    };

Map<String, Object?> _noteRow({
  String id = 'shared-note',
  String title = 'A local note',
  String body = '',
  List<Map<String, String>>? links,
}) => {
  'id': id,
  'title': title,
  'body': body,
  'updated': '2026-11-24T10:00:00.000Z',
  'links': ?links,
};

WorkspaceSnapshot _snapshot({
  List<Map<String, Object?>> tasks = const [],
  List<Map<String, Object?>> events = const [],
  List<Map<String, Object?>> notes = const [],
  Map<String, Object?> sections = const {},
}) => WorkspaceSnapshot(
  workspaceJson: jsonEncode({
    ...sections,
    'tasks': tasks,
    'events': events,
    'notes': notes,
  }),
  gymSessionJson: const [
    '{"planned":false,"startedAt":"2026-11-24T10:00:00","finishedAt":null,"entries":[]}',
  ],
  workoutPlanJson: const [],
);

WorkspaceSnapshot _sourceSnapshot([Map<String, Object?> sections = const {}]) =>
    _snapshot(
      tasks: [
        _taskRow(),
        _taskRow(id: 'recurring-template'),
      ],
      events: [
        _eventRow(),
        _eventRow(id: 'apple:external'),
        _eventRow(id: 'ics:external'),
        _eventRow(id: 'recurring-event'),
        _eventRow(id: 'mirrored-event'),
        _eventRow(id: 'planner-block', task: _task.id),
      ],
      notes: [
        _noteRow(
          title: 'Source planning',
          body: 'café prep',
          links: [
            {'id': _task.id, 'kind': 'task'},
            {'id': _event.id, 'kind': 'event', 'title': 'Focus day'},
          ],
        ),
        _noteRow(id: 'keep-local'),
        {..._noteRow(id: 'future-note'), 'futureFlag': true},
      ],
      sections: {
        'recurringTasks': [
          {'id': 'recurring-template'},
        ],
        'recurringEvents': [
          {'id': 'recurring-event'},
        ],
        'appleCalendarCopies': {'mirrored-event': {}},
        ...sections,
      },
    );
