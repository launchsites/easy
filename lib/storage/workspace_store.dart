import 'package:shared_preferences/shared_preferences.dart';

import 'src/contracts.dart';
import 'src/open_web.dart'
    if (dart.library.io) 'src/open_native.dart'
    as implementation;
import 'src/preference_store.dart';

export 'src/contracts.dart'
    show
        WorkspaceBackupPreview,
        WorkspaceMutation,
        WorkspaceRecordCounts,
        WorkspaceRevision,
        WorkspaceRevisionConflict,
        WorkspaceSnapshot,
        WorkspaceStore,
        WorkspaceStoreException;
export 'src/preference_store.dart' show openPreferenceWorkspaceStore;

/// Opens the workspace. Legacy preferences are read only for a new store.
///
/// After migration the three old preference keys can remain intact as a
/// recovery source. All subsequent writes must use the returned store.
Future<WorkspaceStore> openWorkspaceStore({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
  String? databasePath,
  bool usePreferences = false,
}) {
  if (usePreferences) {
    if (databasePath != null) {
      return Future.error(ArgumentError('A database path requires SQLite.'));
    }
    return openPreferenceWorkspaceStore(
      preferences: preferences,
      readLegacy: readLegacy,
    );
  }
  return implementation.openDefaultWorkspaceStore(
    preferences: preferences,
    readLegacy: readLegacy,
    databasePath: databasePath,
  );
}
