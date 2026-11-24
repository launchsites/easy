import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contracts.dart';
import 'sqlite_store.dart';

Future<WorkspaceStore> openDefaultWorkspaceStore({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
  String? databasePath,
}) async {
  final path =
      databasePath ??
      (await getApplicationSupportDirectory()).uri
          .resolve('easy/workspace.sqlite3')
          .toFilePath();
  return openSqliteWorkspaceStore(path: path, readLegacy: readLegacy);
}
