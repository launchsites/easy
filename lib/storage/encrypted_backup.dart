import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

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
const _maxPasswordBytes = 1024;

// Argon2id parameter sets are format-versioned. This is 19 MiB, 2 passes,
// 1 lane and a 256-bit result, with at most one backup operation at a time.
const _kdf = DartArgon2id(
  memory: 19 * 1024,
  iterations: 2,
  parallelism: 1,
  hashLength: 32,
  maxIsolates: 1,
);

Future<void>? _cryptoQueue;

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
  _validatePassword(password);
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
  _validatePassword(password);
  if (!isEncryptedWorkspaceBackup(backup) ||
      backup.length <= _overhead ||
      backup.length > workspaceBackupByteLimit + _overhead) {
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
    _validatePassword(password);
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

void _validatePassword(String password) {
  if (password.isEmpty ||
      password.length > _maxPasswordBytes ||
      utf8.encode(password).length > _maxPasswordBytes) {
    throw ArgumentError(
      'Use a backup password of 1 to $_maxPasswordBytes UTF-8 bytes.',
    );
  }
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
  final key = await _deriveKey(
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
  final key = await _deriveKey(
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

Future<SecretKeyData> _deriveKey(String password, Uint8List salt) async {
  final material = Uint8List.fromList(utf8.encode(password));
  final state = _kdf.newState();
  try {
    return SecretKeyData(
      await state.deriveKeyBytes(password: material, nonce: salt),
      overwriteWhenDestroyed: true,
    );
  } finally {
    material.fillRange(0, material.length, 0);
    state.tryReleaseMemory();
  }
}
