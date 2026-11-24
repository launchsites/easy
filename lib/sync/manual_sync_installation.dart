import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'manual_sync_contracts.dart';
import 'manual_sync_workspace.dart';
import 'src/lock_installation_web.dart'
    if (dart.library.io) 'src/lock_installation_native.dart';

const _configurationKey = 'easy.manualSync.installation.v1';

typedef _SavedSyncInstallation = ({
  SyncWorkspaceId id,
  bool initialized,
  bool legacyPreference,
});

/// One open route owns a native journal. The installation marker stores
/// its opaque workspace ID and setup phase. Keys stay in the credential vault.
final class ManualSyncInstallation {
  ManualSyncInstallation({
    required this._preferences,
    required SyncDeviceCredentials this._credentials,
    this._databasePath,
  }) : _unlock = null;

  ManualSyncInstallation.withPassphrase({
    required this._preferences,
    required Future<SyncPasswordVault?> Function(bool forSetup) this._unlock,
    this._databasePath,
  }) : _credentials = null;

  final SharedPreferencesAsync _preferences;
  final SyncDeviceCredentials? _credentials;
  final Future<SyncPasswordVault?> Function(bool forSetup)? _unlock;
  final String? _databasePath;
  SyncPasswordVault? _passwordVault;
  ManualSyncWorkspace? _session;
  Future<void>? _closeFuture;
  static Future<void> _configurationQueue = Future.value();

  Future<ManualSyncWorkspace?> openConfigured() => _queue(() async {
    if (_session case final workspace?) return workspace;
    final saved = await _read();
    if (saved == null || !saved.initialized) return null;
    final credentials = await _openCredentials(forSetup: false);
    if (!saved.legacyPreference) return _openSaved(saved, credentials);
    return lockSyncInstallation(_databasePath, () async {
      final current = await _read();
      if (current == null || current.id != saved.id || !current.initialized) {
        throw const SyncVaultException('The sync configuration changed.');
      }
      return _openSaved(current, credentials);
    });
  });

  Future<ManualSyncWorkspace> enable(SyncWorkspaceId? joinWorkspace) =>
      _queue(() async {
        final beforeUnlock = await _read();
        _checkJoinWorkspace(beforeUnlock?.id, joinWorkspace);
        if (_session case final workspace?) return workspace;
        final credentials = await _openCredentials(
          forSetup: beforeUnlock == null,
        );
        if (beforeUnlock == null && _credentials != null) {
          // Check that the system vault is available before creating a lock.
          // Repeat the lookup under the lock before changing anything.
          final existing = await credentials.loadIdentity();
          existing?.destroy();
        }
        return lockSyncInstallation(_databasePath, () async {
          final saved = await _read();
          _checkJoinWorkspace(saved?.id, joinWorkspace);
          final id = saved?.id ?? joinWorkspace ?? SyncWorkspaceId.generate();
          if (saved != null && saved.initialized) {
            return _openSaved(saved, credentials);
          }
          if (saved == null) {
            // Persist vault contents before the pending marker. A restarted
            // passphrase setup requires this existing file when it resumes.
            final identity =
                await credentials.loadIdentity() ??
                await credentials.createIdentity();
            identity.destroy();
            await _write(id, initialized: false);
          }
          final workspace = await ManualSyncWorkspace.create(
            credentials: credentials,
            workspaceId: id,
            databasePath: _databasePath,
          );
          try {
            await _write(id, initialized: true);
            return _session = workspace;
          } catch (_) {
            await workspace.close();
            rethrow;
          }
        });
      });

  Future<ManualSyncWorkspace> _openSaved(
    _SavedSyncInstallation saved,
    SyncDeviceCredentials credentials,
  ) async {
    final workspace = await ManualSyncWorkspace.open(
      credentials: credentials,
      workspaceId: saved.id,
      databasePath: _databasePath,
    );
    try {
      if (saved.legacyPreference) await _write(saved.id, initialized: true);
      return _session = workspace;
    } catch (_) {
      await workspace.close();
      rethrow;
    }
  }

  void _checkJoinWorkspace(SyncWorkspaceId? saved, SyncWorkspaceId? invited) {
    if (saved != null && invited != null && saved != invited) {
      throw const SyncPairedWorkspaceException(
        'This device already has a different sync workspace.',
      );
    }
  }

  Future<SyncDeviceCredentials> _openCredentials({
    required bool forSetup,
  }) async {
    if (_credentials case final credentials?) return credentials;
    final open = _unlock!;
    final vault = _passwordVault ??= await open(forSetup);
    if (vault == null) throw const ManualSyncTransferCancelled();
    return SyncDeviceCredentials(vault);
  }

  Future<_SavedSyncInstallation?> _read() async {
    final marker = await readSyncInstallation(_databasePath);
    final value = marker ?? await _preferences.getString(_configurationKey);
    if (value == null) return null;
    if (value.length <= 100) {
      try {
        if (jsonDecode(value) case [1, final String id, final bool ready]) {
          return (
            id: SyncWorkspaceId(id),
            initialized: ready,
            legacyPreference: marker == null,
          );
        }
      } on FormatException {
        // This installation cannot open an unrecognized configuration.
      }
    }
    throw const SyncVaultException('Saved sync configuration is invalid.');
  }

  Future<void> _write(SyncWorkspaceId id, {required bool initialized}) async {
    final value = jsonEncode([1, id.value, initialized]);
    await writeSyncInstallation(_databasePath, value);
    if (await readSyncInstallation(_databasePath) != value) {
      throw const SyncVaultException('Sync setup could not be saved.');
    }
  }

  Future<T> _queue<T>(Future<T> Function() operation) {
    if (_closeFuture != null) {
      return Future.error(
        const SyncVaultException('Sync settings are closed.'),
      );
    }
    final next = _configurationQueue.then((_) => operation());
    _configurationQueue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> close() => _closeFuture ??= _endSession();

  Future<void> _endSession() async {
    await _configurationQueue;
    final session = _session;
    _session = null;
    try {
      await session?.close();
    } finally {
      final vault = _passwordVault;
      _passwordVault = null;
      await vault?.close();
    }
  }
}
