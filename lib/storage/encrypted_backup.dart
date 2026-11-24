import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'src/backup_password.dart';
import 'src/run_crypto_inline.dart'
    if (dart.library.io) 'src/run_crypto_native.dart';
import 'src/snapshot_codec.dart' show workspaceBackupByteLimit;
import 'workspace_store.dart';

// Version 1 stores a fixed header followed by AES-GCM ciphertext and its tag.
// Header bytes are authenticated too. No input can select an arbitrary KDF.
const _magic = [0x45, 0x41, 0x53, 0x59, 0x42, 0x4b, 0x50, 0]; // EASYBKP
const _version = 1;
const _saltBytes = 16;
const _nonceBytes = 12;
const _tagBytes = 16;
final _saltOffset = _magic.length + 1;
final _nonceOffset = _saltOffset + _saltBytes;
final _headerBytes = _nonceOffset + _nonceBytes;
final _overhead = _headerBytes + _tagBytes;

Future<void>? _cryptoQueue;

int get maximumEncryptedWorkspaceBackupBytes =>
    workspaceBackupByteLimit + _overhead;

/// Identifies a password-protected backup. Full parsing and authentication are
/// handled separately. This also recognizes a newer unsupported version.
bool isEncryptedWorkspaceBackup(Uint8List bytes) {
  if (bytes.length < _magic.length) return false;
  for (var index = 0; index < _magic.length; index++) {
    if (bytes[index] != _magic[index]) return false;
  }
  return true;
}

/// Encrypts a logical workspace backup for storage outside the device.
Future<Uint8List> encryptWorkspaceBackup(
  Uint8List backup,
  String password,
) async {
  validateBackupPassphrase(password);
  if (backup.isEmpty || backup.length > workspaceBackupByteLimit) {
    throw const FormatException('Invalid workspace backup size.');
  }
  final bytes = Uint8List.fromList(backup);
  return _serialCrypto(() => _encrypt(bytes, password));
}

/// Opens an authenticated backup. Use the store's normal preview to validate
/// the plaintext and check the revision before restoring it.
Future<Uint8List> decryptWorkspaceBackup(
  Uint8List backup,
  String password,
) async {
  validateBackupPassphrase(password);
  if (!isEncryptedWorkspaceBackup(backup) ||
      backup.length <= _overhead ||
      backup.length > maximumEncryptedWorkspaceBackupBytes) {
    throw const FormatException('Invalid encrypted workspace backup.');
  }
  if (backup[_magic.length] != _version) {
    throw const FormatException('Unsupported encrypted backup version.');
  }
  final bytes = Uint8List.fromList(backup);
  return _serialCrypto(() => _decrypt(bytes, password));
}

extension WorkspaceEncryptedBackups on WorkspaceStore {
  Future<Uint8List> createEncryptedBackup(String password) async {
    validateBackupPassphrase(password);
    return encryptWorkspaceBackup(await createBackup(), password);
  }

  Future<WorkspaceBackupPreview> previewEncryptedBackup(
    Uint8List backup,
    String password,
  ) async => previewBackup(await decryptWorkspaceBackup(backup, password));
}

/// Wrong passwords, modified ciphertext and modified authenticated headers all
/// fail through the same error.
final class WorkspaceBackupAuthenticationException implements Exception {
  const WorkspaceBackupAuthenticationException();

  @override
  String toString() => 'Could not unlock the backup with this password.';
}

Future<T> _serialCrypto<T>(Future<T> Function() action) {
  final result = (_cryptoQueue ?? Future<void>.value()).then(
    (_) => runBackupCrypto(action),
  );
  late final Future<void> tail;
  void release() {
    if (identical(_cryptoQueue, tail)) _cryptoQueue = null;
  }

  tail = result.then<void>((_) => release(), onError: (Object _) => release());
  _cryptoQueue = tail;
  return result;
}

Future<Uint8List> _encrypt(Uint8List plaintext, String password) async {
  final header = Uint8List(_headerBytes)
    ..setRange(0, _magic.length, _magic)
    ..[_magic.length] = _version;
  final random = Random.secure();
  for (var index = _saltOffset; index < _headerBytes; index++) {
    header[index] = random.nextInt(256);
  }
  final key = await deriveBackupKey(
    password,
    Uint8List.sublistView(header, _saltOffset, _nonceOffset),
  );
  try {
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: key,
      nonce: Uint8List.sublistView(header, _nonceOffset),
      aad: header,
    );
    return (BytesBuilder(copy: false)
          ..add(header)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .takeBytes();
  } finally {
    key.destroy();
  }
}

Future<Uint8List> _decrypt(Uint8List bytes, String password) async {
  final key = await deriveBackupKey(
    password,
    Uint8List.sublistView(bytes, _saltOffset, _nonceOffset),
  );
  try {
    final box = SecretBox.fromConcatenation(
      Uint8List.sublistView(bytes, _nonceOffset),
      nonceLength: _nonceBytes,
      macLength: _tagBytes,
      copy: false,
    );
    final result = await AesGcm.with256bits().decrypt(
      box,
      secretKey: key,
      aad: Uint8List.sublistView(bytes, 0, _headerBytes),
    );
    return result is Uint8List ? result : Uint8List.fromList(result);
  } on SecretBoxAuthenticationError {
    throw const WorkspaceBackupAuthenticationException();
  } finally {
    key.destroy();
  }
}
