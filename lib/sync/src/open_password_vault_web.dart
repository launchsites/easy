import '../sync_credentials.dart';
import 'password_vault_contract.dart';

Future<SyncPasswordVault> openPasswordVault({
  required String passphrase,
  String? filePath,
  required bool createIfMissing,
}) async => throw const SyncVaultException(
  'The password vault needs native file storage.',
);
