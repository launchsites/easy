import 'dart:io';

import 'package:easy/sync/manual_sync_installation.dart';
import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test(
    'Create paired journals for the disposable two-app transfer probe',
    () async {
      final path = Platform.environment['EASY_SYNC_TRANSFER_FIXTURE'];
      if (path == null || !Directory(path).isAbsolute) {
        throw StateError('Provide an absolute disposable fixture directory.');
      }
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final id = SyncWorkspaceId.generate();
      final installations = <ManualSyncInstallation>[];
      try {
        final workspaces = <ManualSyncWorkspace>[];
        for (final profile in ['source', 'destination']) {
          final directory = Directory(
            '$path/$profile/data/app.launchsites.easy',
          );
          final syncFolder = Directory('${directory.path}/easy/sync');
          if (!await directory.exists() || await syncFolder.exists()) {
            throw StateError('Expected a fresh synthetic sync profile.');
          }
          final installation = ManualSyncInstallation.withPassphrase(
            preferences: SharedPreferencesAsync(),
            databasePath: '${syncFolder.path}/${id.value}.sqlite3',
            unlock: (forSetup) => openSyncPasswordVault(
              passphrase: 'Synthetic native setup test passphrase',
              filePath: '${syncFolder.path}/credentials.easyvault',
              createIfMissing: forSetup,
            ),
          );
          installations.add(installation);
          workspaces.add(await installation.enable(id));
        }
        final [source, destination] = workspaces;
        final invitation = await source.createInvitation();
        final response = await destination.respond(invitation.code);
        final review = await invitation.receiveResponse(response.code);
        final sourceApproval = await review.confirmComparison(
          response.review.comparisonCode,
        );
        final destinationApproval = await response.review.confirmComparison(
          review.comparisonCode,
        );
        final sourcePeer = await review.finish(destinationApproval);
        final destinationPeer = await response.review.finish(sourceApproval);
        try {
          await source.approvePair(sourcePeer, expectedRevision: 0);
          await destination.approvePair(destinationPeer, expectedRevision: 0);
        } finally {
          sourcePeer.discard();
          destinationPeer.discard();
        }
      } finally {
        for (final installation in installations) {
          await installation.close();
        }
      }
    },
  );
}
