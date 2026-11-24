import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/workspace_store.dart';
import 'ai_runtime.dart';

/// A separate device database keeps reservations and settled usage intact when
/// the user restores a workspace backup or changes an API endpoint.
class AiDeviceState {
  AiDeviceState(this._store);

  static const _stateKey = 'aiState';
  static const _maximumStateLength = 8 * 1024 * 1024;
  static const _empty = {'events': [], 'tasks': [], 'notes': []};

  final WorkspaceStore _store;

  static Future<AiDeviceState> open({
    required SharedPreferencesAsync preferences,
    String? databasePath,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Device AI state is unavailable on web.');
    }
    final path =
        databasePath ??
        (await getApplicationSupportDirectory()).uri
            .resolve('easy/ai-device.sqlite3')
            .toFilePath();
    return AiDeviceState(
      await openWorkspaceStore(
        preferences: preferences,
        readLegacy: () async => WorkspaceSnapshot(
          workspaceJson: jsonEncode(_empty),
          gymSessionJson: [],
          workoutPlanJson: [],
        ),
        databasePath: path,
      ),
    );
  }

  String? _value(WorkspaceRevision revision) {
    final document = jsonDecode(revision.snapshot.workspaceJson);
    if (document is! Map<String, dynamic>) {
      throw const FormatException('Invalid device AI state.');
    }
    final value = document[_stateKey];
    if (value == null) return null;
    if (value is! String || value.length > _maximumStateLength) {
      throw const FormatException('Invalid device AI state.');
    }
    return value;
  }

  Future<AiStoredState?> read() async {
    final revision = await _store.read();
    final value = _value(revision);
    return value == null
        ? null
        : AiStoredState(revision: revision.revision, value: value);
  }

  Future<int?> compareAndSwap(int expectedRevision, String value) async {
    if (value.length > _maximumStateLength) {
      throw const FormatException('Device AI state exceeds the storage limit.');
    }
    final latest = await _store.read();
    final state = _value(latest);
    final observedRevision = state == null ? 0 : latest.revision;
    if (expectedRevision != observedRevision) return null;
    try {
      final updated = await _store.save(
        WorkspaceMutation.workspace(jsonEncode({..._empty, _stateKey: value})),
        expectedRevision: latest.revision,
      );
      return updated.revision;
    } on WorkspaceRevisionConflict {
      return null;
    }
  }

  Future<void> close() => _store.close();
}

/// Uses the device's credential service with no sync, export or plaintext
/// fallback. The provider never sees a key until the user authorizes a request.
class AiSystemCredentialVault implements AiWritableCredentialVault {
  const AiSystemCredentialVault({
    this.storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  });

  final FlutterSecureStorage storage;

  @override
  bool get persistent => true;

  @override
  Future<String?> read(String reference) => storage.read(key: reference);

  @override
  Future<void> write(String reference, String secret) async {
    await storage.write(key: reference, value: secret);
    if (await storage.read(key: reference) != secret) {
      throw StateError('The system credential service did not store the key.');
    }
  }

  @override
  Future<void> delete(String reference) => storage.delete(key: reference);
}
