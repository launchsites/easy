import '../sync_credentials.dart';

abstract interface class SyncPasswordVault implements SyncSecretVault {
  Future<void> close();
}
