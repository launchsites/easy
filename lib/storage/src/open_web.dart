import 'package:shared_preferences/shared_preferences.dart';

import 'contracts.dart';
import 'preference_store.dart';

Future<WorkspaceStore> openDefaultWorkspaceStore({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
  String? databasePath,
}) {
  if (databasePath != null) {
    return Future.error(
      const WorkspaceStoreException(
        'A database path requires a native workspace.',
      ),
    );
  }
  return openPreferenceWorkspaceStore(
    preferences: preferences,
    readLegacy: readLegacy,
  );
}
