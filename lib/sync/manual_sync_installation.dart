import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'manual_sync_workspace.dart';

const _configurationKey = 'easy.manualSync.installation.v1';

/// One open route owns a native journal. The installation preference stores
/// its opaque workspace ID and setup phase. Keys stay in the credential vault.
final class ManualSyncInstallation {
  ManualSyncInstallation({
    required SharedPreferencesAsync preferences,
    required SyncDeviceCredentials credentials,
    String? databasePath,
  }) : _preferences = preferences,
       _credentials = credentials,
       _databasePath = databasePath;

  final SharedPreferencesAsync _preferences;
  final SyncDeviceCredentials _credentials;
  final String? _databasePath;
  ManualSyncWorkspace? _session;
  Future<void>? _closeFuture;
  static Future<void> _configurationQueue = Future.value();

  Future<ManualSyncWorkspace?> openConfigured() => _queue(() async {
    if (_session case final workspace?) return workspace;
    final saved = await _read();
    if (saved == null || !saved.initialized) return null;
    return _session = await ManualSyncWorkspace.open(
      credentials: _credentials,
      workspaceId: saved.id,
      databasePath: _databasePath,
    );
  });

  Future<ManualSyncWorkspace> enable(SyncWorkspaceId? joinWorkspace) => _queue(
    () async {
      final saved = await _read();
      final id = saved?.id ?? joinWorkspace ?? SyncWorkspaceId.generate();
      if (joinWorkspace != null && id != joinWorkspace) {
        throw const SyncPairedWorkspaceException(
          'This device already has a different sync workspace.',
        );
      }
      if (_session case final workspace?) return workspace;
      if (saved?.initialized == true) {
        return _session = await ManualSyncWorkspace.open(
          credentials: _credentials,
          workspaceId: id,
          databasePath: _databasePath,
        );
      }
      if (saved == null) {
        // Check vault access before putting a partially configured workspace
        // on disk. An explicit retry can resume the same ID after interruption.
        final existing = await _credentials.loadIdentity();
        existing?.destroy();
        await _write(id, initialized: false);
      }
      final workspace = await ManualSyncWorkspace.create(
        credentials: _credentials,
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
    },
  );

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
    await session?.close();
  }
}
