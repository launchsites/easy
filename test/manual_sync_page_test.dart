import 'dart:io';

import 'package:easy/storage/workspace_store.dart';
import 'package:easy/sync/manual_sync_page.dart';
import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _conflictNote = (kind: SyncRecordKind.note, id: 'conflict');
const _newNote = (kind: SyncRecordKind.note, id: 'added');

void main() {
  late Directory temporary;
  final sessions = <ManualSyncWorkspace>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('easy-manual-sync-page-');
  });

  tearDown(() async {
    await Future.wait(sessions.map((session) => session.close()));
    sessions.clear();
    await temporary.delete(recursive: true);
  });

  Future<ManualSyncWorkspace> workspace(
    String name, {
    SyncWorkspaceId? workspaceId,
  }) async {
    final session = await ManualSyncWorkspace.create(
      credentials: SyncDeviceCredentials(_MemoryVault()),
      workspaceId: workspaceId,
      databasePath: temporary.uri.resolve('$name.db').toFilePath(),
    );
    sessions.add(session);
    return session;
  }

  Future<void> makePair(
    ManualSyncWorkspace inviter,
    ManualSyncWorkspace responder,
  ) async {
    final offer = await inviter.createInvitation();
    final response = await responder.respond(offer.code);
    final inviteReview = await offer.receiveResponse(response.code);
    final yes1 = await inviteReview.confirmComparison(
      response.review.comparisonCode,
    );
    final yes2 = await response.review.confirmComparison(
      inviteReview.comparisonCode,
    );
    await inviter.approvePair(
      await inviteReview.finish(yes2),
      expectedRevision: 0,
    );
    await responder.approvePair(
      await response.review.finish(yes1),
      expectedRevision: 0,
    );
  }

  Future<void> screen(
    WidgetTester tester,
    ManualSyncPageHost host, {
    ManualSyncProjector? projector,
    double width = 320,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.35)),
          child: child!,
        ),
        home: ManualSyncPage(host: host, projector: projector),
      ),
    );
  }

  testWidgets(
    'enable and compare codes deliberately establish a device pairing on a narrow screen',
    (tester) async {
      final pair = (await tester.runAsync(() async {
        final local = await workspace('local');
        return (
          local,
          await workspace('other', workspaceId: local.workspaceId),
        );
      }))!;
      final (local, other) = pair;
      ManualSyncWorkspace? configured;
      var enables = 0;
      final copied = <String>[];
      String? paste;
      await screen(
        tester,
        ManualSyncPageHost(
          openConfigured: () async => configured,
          enable: (requested) async {
            expect(requested, isNull);
            enables++;
            return configured = local;
          },
          copyToken: (code) async => copied.add(code),
          pasteToken: () async => paste,
          pickBundle: () async =>
              throw StateError('Pairing does not import a workspace bundle.'),
          saveBundle: (_, _) async =>
              throw StateError('Pairing does not save a workspace bundle.'),
        ),
      );
      await _waitFor(tester, find.text('Enable manual sync'));
      expect(enables, 0);
      expect(copied, isEmpty);
      await _tap(tester, 'Enable manual sync');
      await _waitFor(tester, find.text('Pair a device'));
      expect(enables, 1);
      await _tap(tester, 'Pair a device');
      await _tap(tester, 'Create invitation');
      await _tap(tester, 'Copy invitation');
      expect(copied, hasLength(1));
      final reply = (await tester.runAsync(
        () => other.respond(copied.single),
      ))!;
      paste = reply.code;
      await _tap(tester, 'Enter response');
      await _tap(tester, 'Paste from clipboard');
      await _tap(tester, 'Continue');
      await _waitFor(tester, find.text('Compare both screens'));
      final comparison = reply.review.comparisonCode;
      expect(find.text(comparison), findsOneWidget);
      await _tap(tester, 'Compare codes');
      await tester.enterText(find.byType(TextField), comparison);
      await _tap(tester, 'Confirm code');
      await _tap(tester, 'Copy approval');
      expect(copied, hasLength(2));
      paste = (await tester.runAsync(() async {
        final acceptance = await reply.review.confirmComparison(comparison);
        await other.approvePair(
          await reply.review.finish(copied.last),
          expectedRevision: 0,
        );
        return acceptance;
      }))!;
      await _tap(tester, 'Enter peer approval');
      await _tap(tester, 'Paste from clipboard');
      await _tap(tester, 'Continue');
      await _waitFor(tester, find.text('Paired device'));
      final status = (await tester.runAsync(local.status))!;
      expect(status.approvedPairKeyIds.keys, [other.device.fingerprint]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bundle and workspace projection require separate explicit approvals, followed by reviewed revoke',
    (tester) async {
      final setup = (await tester.runAsync(() async {
        final local = await workspace('local');
        final remote = await workspace(
          'remote',
          workspaceId: local.workspaceId,
        );
        await makePair(local, remote);
        await local.writeLocalChange(
          record: _conflictNote,
          kind: SyncChangeKind.patch,
          fields: {'title': 'Original note'},
        );
        final seed = (await local.exportFor(remote.device.fingerprint))!;
        await remote.commitIncoming(
          await remote.previewIncoming(
            bytes: seed.bytes,
            senderId: local.device.fingerprint,
          ),
        );
        await local.writeLocalChange(
          record: _conflictNote,
          kind: SyncChangeKind.patch,
          fields: {'body': 'Offline edit'},
        );
        await remote.writeLocalChange(
          record: _conflictNote,
          kind: SyncChangeKind.delete,
        );
        await remote.writeLocalChange(
          record: _newNote,
          kind: SyncChangeKind.patch,
          fields: {'title': 'New note'},
        );
        final bundle = (await remote.exportFor(
          local.device.fingerprint,
          known: (await local.status()).watermark,
        ))!;
        return (local, remote, bundle.bytes);
      }))!;
      final (local, remote, bytes) = setup;
      var picks = 0;
      final projection = _ProjectionRecorder();
      await screen(
        tester,
        ManualSyncPageHost(
          openConfigured: () async => local,
          enable: (_) async => throw StateError('Sync is already enabled.'),
          copyToken: (_) async {},
          pasteToken: () async => null,
          pickBundle: () async {
            picks++;
            return bytes;
          },
          saveBundle: (_, _) async =>
              throw StateError('Import does not export a file.'),
        ),
        projector: projection,
        width: 480,
      );
      await _tap(tester, 'Paired device');
      await _tap(tester, 'Open change bundle');
      await _waitFor(tester, find.text('Review change bundle'));
      expect(picks, 1);
      expect(projection.previews, 0);
      final save = find.ancestor(
        of: find.text('Save reviewed bundle'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      await _waitFor(tester, save);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await _tap(tester, 'Approve removals and restores');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await _tap(tester, 'Keep both versions of conflicting records');
      await _tap(tester, 'Save reviewed bundle');
      await _waitFor(tester, find.text('Saved to the sync journal'));
      expect(projection.previews, 0);
      await _tap(tester, 'Review workspace changes');
      await _waitFor(tester, find.text('Apply to workspace'));
      expect(projection.previews, 1);
      expect(projection.applied, isEmpty);
      final unavailable = find.widgetWithText(
        CheckboxListTile,
        'Conflicting note',
      );
      expect(tester.widget<CheckboxListTile>(unavailable).onChanged, isNull);
      await _tap(tester, 'New note');
      await _tap(tester, 'Review 1 change');
      expect(find.text('Apply 1 change to your workspace?'), findsOneWidget);
      expect(projection.applied, isEmpty);
      await _tap(tester, 'Apply selected changes');
      await _waitFor(tester, find.text('Revoke this device'));
      expect(projection.applied, {_newNote});
      await _tap(tester, 'Revoke this device');
      await _waitFor(tester, find.text('Revoke this device?'));
      final current = (await tester.runAsync(local.status))!;
      expect(
        current.approvedPairKeyIds.containsKey(remote.device.fingerprint),
        isTrue,
      );
      await _tap(tester, 'Cancel');
      await _tap(tester, 'Revoke this device');
      await _tap(tester, 'Revoke device');
      await _waitFor(tester, find.text('Device revoked.'));
      expect(
        (await tester.runAsync(local.status))!.approvedPairKeyIds,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await _waitFor(tester, target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 270));
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    await tester.pump(const Duration(milliseconds: 60));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(finder, findsWidgets);
}

final class _MemoryVault implements SyncSecretVault {
  final _values = <String, String>{};
  @override
  Future<String?> read(String reference) async => _values[reference];
  @override
  Future<void> delete(String reference) async => _values.remove(reference);
  @override
  Future<void> write(String reference, String secret) async =>
      _values[reference] = secret;
}

final class _ProjectionRecorder implements ManualSyncProjector {
  var previews = 0;
  Set<SyncRecordKey> applied = {};

  @override
  Future<ManualSyncProjectionPreview> previewIncoming({
    required ManualSyncWorkspace sync,
    required SyncImportPreview imported,
    required SyncJournalStatus committed,
  }) async {
    previews++;
    expect(imported.hasConflicts, isTrue);
    return ManualSyncProjectionPreview(
      syncWorkspaceId: sync.workspaceId,
      syncRevision: committed.revision,
      expectedWorkspaceRevision: 4,
      records: const [
        ManualSyncProjectionRecord(
          key: _conflictNote,
          title: 'Conflicting note',
          action: ManualSyncProjectionAction.resolveConflict,
        ),
        ManualSyncProjectionRecord(
          key: _newNote,
          title: 'New note',
          action: ManualSyncProjectionAction.add,
        ),
      ],
    );
  }

  @override
  Future<WorkspaceRevision> applyIncoming(
    ManualSyncProjectionPreview preview, {
    required Set<SyncRecordKey> selected,
  }) async {
    applied = selected;
    return WorkspaceRevision(
      revision: preview.expectedWorkspaceRevision + 1,
      snapshot: WorkspaceSnapshot(
        workspaceJson: '{"events":[],"tasks":[],"notes":[]}',
        gymSessionJson: const [],
        workoutPlanJson: const [],
      ),
    );
  }
}
