import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'manual_sync_contracts.dart';
import 'manual_sync_workspace.dart';

const _configurationKey = 'easy.manualSync.installation.v1';

/// One open route owns a native journal. The installation preference stores
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
    return _session = await ManualSyncWorkspace.open(
      credentials: await _openCredentials(forSetup: false),
      workspaceId: saved.id,
      databasePath: _databasePath,
    );
  });

  Future<ManualSyncWorkspace> enable(SyncWorkspaceId? joinWorkspace) =>
      _queue(() async {
        final saved = await _read();
        final id = saved?.id ?? joinWorkspace ?? SyncWorkspaceId.generate();
        if (joinWorkspace != null && id != joinWorkspace) {
          throw const SyncPairedWorkspaceException(
            'This device already has a different sync workspace.',
          );
        }
        if (_session case final workspace?) return workspace;
        final credentials = await _openCredentials(forSetup: saved == null);
        if (saved?.initialized == true) {
          return _session = await ManualSyncWorkspace.open(
            credentials: credentials,
            workspaceId: id,
            databasePath: _databasePath,
          );
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

  Future<SyncDeviceCredentials> _openCredentials({
    required bool forSetup,
  }) async {
    if (_credentials case final credentials?) return credentials;
    final open = _unlock!;
    final vault = _passwordVault ??= await open(forSetup);
    if (vault == null) throw const ManualSyncTransferCancelled();
    return SyncDeviceCredentials(vault);
  }

  Future<({SyncWorkspaceId id, bool initialized})?> _read() async {
    final value = await _preferences.getString(_configurationKey);
    if (value == null) return null;
    if (value.length <= 100) {
      try {
        if (jsonDecode(value) case [1, final String id, final bool ready]) {
          return (id: SyncWorkspaceId(id), initialized: ready);
        }
      } on FormatException {
        // This installation cannot open an unrecognized configuration.
      }
    }
    throw const SyncVaultException('Saved sync configuration is invalid.');
  }

  Future<void> _write(SyncWorkspaceId id, {required bool initialized}) async {
    final value = jsonEncode([1, id.value, initialized]);
    await _preferences.setString(_configurationKey, value);
    if (await _preferences.getString(_configurationKey) != value) {
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
