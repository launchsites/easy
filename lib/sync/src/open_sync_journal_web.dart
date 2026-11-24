import 'sync_change.dart';
import 'sync_journal_types.dart';
import 'sync_security.dart';

Future<SyncJournal?> openPlatformSyncJournal({
  required SyncWorkspaceId workspaceId,
  required SyncDevicePublicKey localDevicePublicKey,
  required SyncJournalKey journalKey,
  String? databasePath,
  required bool createIfMissing,
}) async => null;
