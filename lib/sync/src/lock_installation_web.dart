import '../sync_credentials.dart';

Future<String?> readSyncInstallation(String? databasePath) async => null;

Future<void> writeSyncInstallation(String? databasePath, String value) async =>
    throw const SyncVaultException('Device sync needs a native store.');

Future<T> lockSyncInstallation<T>(
  String? databasePath,
  Future<T> Function() install,
) async => throw const SyncVaultException('Device sync needs a native store.');
