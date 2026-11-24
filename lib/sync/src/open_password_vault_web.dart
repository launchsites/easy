import '../sync_credentials.dart';
import 'password_vault_contract.dart';

Future<SyncPasswordVault> openPasswordVault({
  required String passphrase,
  String? filePath,
}) async => throw const SyncVaultException(
  'The password vault needs native file storage.',
);
