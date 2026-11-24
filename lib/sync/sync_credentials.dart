import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'src/sync_wire.dart';
import 'sync_journal.dart';

abstract interface class SyncSecretVault {
  Future<String?> read(String reference);
  Future<void> write(String reference, String secret);
  Future<void> delete(String reference);
}

/// Uses the platform's credential service. Android keeps sync secrets in a
/// separate namespace so a provider-key reset cannot erase the device ID.
final class SyncSystemSecretVault implements SyncSecretVault {
  const SyncSystemSecretVault({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'easy_sync_v1',
        resetOnError: false,
        migrateWithBackup: true,
      ),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  });

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String reference) =>
      _native(() => storage.read(key: reference));

  @override
  Future<void> write(String reference, String secret) =>
      _native(() => storage.write(key: reference, value: secret));

  @override
  Future<void> delete(String reference) =>
      _native(() => storage.delete(key: reference));

  Future<T> _native<T>(Future<T> Function() operation) {
    if (kIsWeb) {
      throw const SyncVaultException(
        'Device sync needs a native credential vault.',
      );
    }
    return operation();
  }
}

final class SyncVaultException implements Exception {
  const SyncVaultException(this.message);

  final String message;
  @override
  String toString() => message;
}

const _deviceReference = 'easy.sync.v1.device';
const _unavailable = SyncVaultException(
  'The sync credential vault could not be opened.',
);
const _invalidKey = SyncVaultException(
  'A saved sync credential has an invalid format.',
);
Future<void>? _vaultQueue;

/// Stores private identity, local ledger and per-pair keys separately from
/// workspace records and backup files. Creation is always explicit.
final class SyncDeviceCredentials {
  const SyncDeviceCredentials(this.vault);

  final SyncSecretVault vault;

  Future<SyncDeviceIdentity?> loadIdentity() => _serialize(() async {
    final bytes = await _read(_deviceReference);
    if (bytes == null) return null;
    try {
      return await SyncDeviceIdentity.fromSeed(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  });

  Future<SyncDeviceIdentity> createIdentity() => _serialize(() async {
    if (await _access(() => vault.read(_deviceReference)) != null) {
      throw const SyncVaultException(
        'This installation already has a sync identity.',
      );
    }
    final identity = await SyncDeviceIdentity.generate();
    try {
      await _write(_deviceReference, await identity.copySeedForSecureStorage());
      return identity;
    } catch (_) {
      identity.destroy();
      rethrow;
    }
  });

  Future<SyncJournalKey?> loadJournalKey(SyncWorkspaceId workspace) =>
      _serialize(() async {
        final bytes = await _read(_journalReference(workspace));
        if (bytes == null) return null;
        try {
          return SyncJournalKey.fromBytes(bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      });

  Future<SyncJournalKey> createJournalKey(SyncWorkspaceId workspace) =>
      _serialize(() async {
        final reference = _journalReference(workspace);
        if (await _access(() => vault.read(reference)) != null) {
          throw const SyncVaultException(
            'This workspace already has a journal key.',
          );
        }
        final key = SyncJournalKey.generate();
        try {
          await _write(reference, key.copyBytesForSecureStorage());
          return key;
        } catch (_) {
          key.destroy();
          rethrow;
        }
      });

  Future<String> rememberPairKey({
    required SyncWorkspaceId workspace,
    required String deviceId,
    required SyncPairKey key,
  }) => _serialize(() async {
    final keyId = key.keyId;
    final reference = _pairReference(workspace, deviceId, keyId);
    final existing = await _read(reference);
    if (existing == null) {
      await _write(reference, key.copyBytesForSecureStorage());
    } else {
      final prior = SyncPairKey.fromBytes(existing);
      try {
        if (prior.keyId != keyId) throw _invalidKey;
      } finally {
        existing.fillRange(0, existing.length, 0);
        prior.destroy();
      }
    }
    return keyId;
  });

  Future<SyncPairKey> loadPairKey({
    required SyncWorkspaceId workspace,
    required String deviceId,
    required String keyId,
  }) => _serialize(() async {
    final bytes = await _read(_pairReference(workspace, deviceId, keyId));
    if (bytes == null) {
      throw const SyncVaultException('This paired device key is unavailable.');
    }
    try {
      final key = SyncPairKey.fromBytes(bytes);
      if (key.keyId != keyId) {
        key.destroy();
        throw _invalidKey;
      }
      return key;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  });

  Future<void> forgetPairKey({
    required SyncWorkspaceId workspace,
    required String deviceId,
    required String keyId,
  }) => _serialize(() async {
    final reference = _pairReference(workspace, deviceId, keyId);
    await _access(() => vault.delete(reference));
    if (await _access(() => vault.read(reference)) != null) {
      throw const SyncVaultException(
        'The vault could not remove the paired key.',
      );
    }
  });

  Future<Uint8List?> _read(String reference) async {
    final stored = await _access(() => vault.read(reference));
    if (stored == null) return null;
    if (stored.length != 44) throw _invalidKey;
    try {
      final bytes = base64Url.decode(stored);
      if (bytes.length != 32 || base64Url.encode(bytes) != stored) {
        throw _invalidKey;
      }
      return bytes;
    } on FormatException {
      throw _invalidKey;
    }
  }

  Future<void> _write(String reference, Uint8List bytes) async {
    final encoded = base64Url.encode(bytes);
    bytes.fillRange(0, bytes.length, 0);
    await _access(() => vault.write(reference, encoded));
    if (await _access(() => vault.read(reference)) != encoded) {
      throw const SyncVaultException(
        'The vault did not confirm saving the sync credential.',
      );
    }
  }
}

String _journalReference(SyncWorkspaceId workspace) =>
    'easy.sync.v1.journal.${workspace.value}';

String _pairReference(
  SyncWorkspaceId workspace,
  String deviceId,
  String keyId,
) {
  if (!syncMatches(syncDeviceIdPattern, deviceId) ||
      !syncMatches(syncDeviceIdPattern, keyId)) {
    throw _invalidKey;
  }
  return 'easy.sync.v1.pair.${workspace.value}.$deviceId.$keyId';
}

Future<T> _access<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on SyncVaultException {
    rethrow;
  } catch (_) {
    throw _unavailable;
  }
}

Future<T> _serialize<T>(Future<T> Function() action) {
  final result = (_vaultQueue ?? Future<void>.value()).then((_) => action());
  late final Future<void> tail;
  void release() {
    if (identical(_vaultQueue, tail)) _vaultQueue = null;
  }

  tail = result.then<void>((_) => release(), onError: (Object _) => release());
  _vaultQueue = tail;
  return result;
}
