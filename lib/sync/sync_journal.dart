import 'src/open_sync_journal_web.dart'
    if (dart.library.io) 'src/open_sync_journal_native.dart'
    as platform;
import 'src/sync_change.dart';
import 'src/sync_journal_types.dart';
import 'src/sync_security.dart';

export 'src/sync_journal_types.dart';
export 'workspace_sync.dart';

/// Opens an explicitly configured local journal. The browser currently has no
/// durable implementation. Opening the journal creates no network activity.
Future<SyncJournal?> openSyncJournal({
  required SyncWorkspaceId workspaceId,
  required SyncDevicePublicKey localDevicePublicKey,
  required SyncJournalKey journalKey,
  String? databasePath,
}) => platform.openPlatformSyncJournal(
  workspaceId: workspaceId,
  localDevicePublicKey: localDevicePublicKey,
  journalKey: journalKey,
  databasePath: databasePath,
);
