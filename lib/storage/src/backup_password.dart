import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

const _maxPasswordBytes = 1024;

// This Argon2id parameter set occupies 19 MiB with two passes and one lane.
// Its output is shared by the versioned workspace backup formats.
const _kdf = DartArgon2id(
  memory: 19 * 1024,
  iterations: 2,
  parallelism: 1,
  hashLength: 32,
  maxIsolates: 1,
);

void validateBackupPassphrase(String passphrase) {
  if (passphrase.isEmpty ||
      passphrase.length > _maxPasswordBytes ||
      utf8.encode(passphrase).length > _maxPasswordBytes) {
    throw ArgumentError(
      'Use a backup passphrase of 1 to $_maxPasswordBytes UTF-8 bytes.',
    );
  }
}

Future<SecretKeyData> deriveBackupKey(String passphrase, Uint8List salt) async {
  final material = Uint8List.fromList(utf8.encode(passphrase));
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
