import 'src/open_password_vault_web.dart'
    if (dart.library.io) 'src/open_password_vault_native.dart'
    as platform;
import 'src/password_vault_contract.dart';

export 'src/password_vault_contract.dart';

/// Explicit password file for a native device whose credential service is
/// unavailable. The caller supplies the passphrase again on each open.
Future<SyncPasswordVault> openSyncPasswordVault({
  required String passphrase,
  String? filePath,
}) => platform.openPasswordVault(passphrase: passphrase, filePath: filePath);
