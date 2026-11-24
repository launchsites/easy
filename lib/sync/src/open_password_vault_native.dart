import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../storage/encrypted_backup.dart';
import '../sync_credentials.dart';
import 'password_vault_contract.dart';
import 'sync_wire.dart';

const _vaultFormat = 'easy.manual-sync-vault';
const _maxFileBytes = 512 * 1024;
const _maxEntries = 2000;
final _referencePattern = RegExp(r'^easy\.sync\.v1\.[a-z0-9.]{1,190}$');
final _queues = <String, Future<void>>{};
const _vaultError = SyncVaultException(
  'The encrypted credential file could not be opened.',
);
const _vaultMissing = SyncVaultException(
  'Restore the saved encrypted sync vault to unlock this device.',
);

Future<SyncPasswordVault> openPasswordVault({
  required String passphrase,
  String? filePath,
  required bool createIfMissing,
}) async {
  if (passphrase.isEmpty ||
      passphrase.length > 1024 ||
      utf8.encode(passphrase).length > 1024) {
    throw const SyncVaultException(
      'Enter a passphrase of up to 1,024 UTF-8 bytes.',
    );
  }
  try {
    final path =
        filePath ??
        (await getApplicationSupportDirectory()).uri
            .resolve('easy/sync/credentials.easyvault')
            .toFilePath();
    final file = File(path).absolute;
    if (!createIfMissing && !await _regularFileOrMissing(file)) {
      throw _vaultMissing;
    }
    final vault = _NativePasswordVault(
      file,
      passphrase,
      requiresFile: !createIfMissing,
    );
    await vault._locked((password) async => vault._read(password));
    return vault;
  } on SyncVaultException {
    rethrow;
  } catch (_) {
    throw _vaultError;
  }
}

final class _NativePasswordVault implements SyncPasswordVault {
  _NativePasswordVault(
    this._file,
    this._passphrase, {
    required this._requiresFile,
  });

  final File _file;
  String? _passphrase;
  bool _requiresFile;

  @override
  Future<String?> read(String reference) => _locked((password) async {
    _checkReference(reference);
    return (await _read(password))[reference];
  });

  @override
  Future<void> write(String reference, String secret) =>
      _locked((password) async {
        _checkReference(reference);
        if (!_validValue(secret)) throw _vaultError;
        final entries = await _read(password);
        if (entries[reference] == secret) return;
        entries[reference] = secret;
        await _write(entries, password);
      });

  @override
  Future<void> delete(String reference) => _locked((password) async {
    _checkReference(reference);
    final entries = await _read(password);
    if (entries.remove(reference) != null) await _write(entries, password);
  });

  Future<T> _locked<T>(Future<T> Function(String password) action) {
    final result = (_queues[_file.path] ?? Future<void>.value()).then((
      _,
    ) async {
      final password = _passphrase;
      if (password == null) {
        throw const SyncVaultException('The password vault is closed.');
      }
      final lock = File('${_file.path}.lock');
      try {
        await _file.parent.create(recursive: true);
        await _regularFileOrMissing(lock);
        final descriptor = await lock.open(mode: FileMode.append);
        try {
          await descriptor.lock(FileLock.blockingExclusive);
          try {
            return await action(password);
          } finally {
            await descriptor.unlock();
          }
        } finally {
          await descriptor.close();
        }
      } on SyncVaultException {
        rethrow;
      } catch (_) {
        throw _vaultError;
      }
    });
    late final Future<void> tail;
    void release() {
      if (identical(_queues[_file.path], tail)) _queues.remove(_file.path);
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object _) => release(),
    );
    _queues[_file.path] = tail;
    return result;
  }

  Future<Map<String, String>> _read(String password) async {
    if (!await _regularFileOrMissing(_file)) {
      if (_requiresFile) throw _vaultMissing;
      return {};
    }
    _requiresFile = true;
    if (await _file.length() > _maxFileBytes) throw _vaultError;
    final bytes = BytesBuilder(copy: false);
    await for (final block in _file.openRead()) {
      if (block.length > _maxFileBytes - bytes.length) throw _vaultError;
      bytes.add(block);
    }
    final Uint8List plaintext;
    try {
      plaintext = await decryptWorkspaceBackup(bytes.takeBytes(), password);
    } on WorkspaceBackupAuthenticationException {
      throw const SyncVaultException(
        'The passphrase could not unlock this credential file.',
      );
    }
    try {
      final object = syncDecodeJson(
        utf8.decode(plaintext),
        maxChars: _maxFileBytes,
        maxDepth: 4,
      );
      if (object is! Map<String, dynamic> ||
          object['format'] != _vaultFormat ||
          object['version'] != 1) {
        throw _vaultError;
      }
      final entries = object['entries'];
      if (entries is! Map<String, dynamic> ||
          entries.length > _maxEntries ||
          entries.entries.any(
            (entry) =>
                !syncMatches(_referencePattern, entry.key) ||
                !_validValue(entry.value),
          )) {
        throw _vaultError;
      }
      return Map<String, String>.of(entries.cast<String, String>());
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  Future<void> _write(Map<String, String> entries, String password) async {
    if (entries.length > _maxEntries) throw _vaultError;
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({'format': _vaultFormat, 'version': 1, 'entries': entries}),
      ),
    );
    final Uint8List encrypted;
    try {
      if (plaintext.length > _maxFileBytes - 128) throw _vaultError;
      encrypted = await encryptWorkspaceBackup(plaintext, password);
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    final staging = await _file.parent.createTemp('.easy-vault-');
    try {
      final prepared = File(staging.uri.resolve('write').toFilePath());
      await prepared.writeAsBytes(encrypted, flush: true);
      if (!await _regularFileOrMissing(_file) && _requiresFile) {
        throw _vaultMissing;
      }
      await prepared.rename(_file.path);
      _requiresFile = true;
    } finally {
      await staging.delete(recursive: true);
    }
  }

  @override
  Future<void> close() async {
    _passphrase = null;
    await _queues[_file.path];
  }
}

Future<bool> _regularFileOrMissing(File file) async {
  return switch (await FileSystemEntity.type(file.path, followLinks: false)) {
    FileSystemEntityType.file => true,
    FileSystemEntityType.notFound => false,
    _ => throw _vaultError,
  };
}

void _checkReference(String value) {
  if (!syncMatches(_referencePattern, value)) throw _vaultError;
}

bool _validValue(Object? value) {
  if (value is! String || value.length != 44) return false;
  try {
    final bytes = base64Url.decode(value);
    return bytes.length == 32 && base64Url.encode(bytes) == value;
  } on FormatException {
    return false;
  }
}
