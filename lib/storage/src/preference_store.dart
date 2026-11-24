import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'contracts.dart';
import 'snapshot_codec.dart';

/// Serializes writes in this isolate. Browser tabs have separate isolates.
Future<void>? _preferencesQueue;

Future<WorkspaceStore> openPreferenceWorkspaceStore({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
  String key = 'easy.storage.v2',
}) async {
  final store = _PreferenceWorkspaceStore(preferences, key);
  await store._initialize(readLegacy);
  return store;
}

class _PreferenceWorkspaceStore implements WorkspaceStore {
  _PreferenceWorkspaceStore(this._preferences, this._key);

  final SharedPreferencesAsync _preferences;
  final String _key;
  bool _closed = false;
  Future<void> _lastOperation = Future.value();

  Future<T> _queue<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future.error(
        const WorkspaceStoreException('The workspace is closed.'),
      );
    }
    final result = (_preferencesQueue ?? Future<void>.value()).then(
      (_) => operation(),
    );
    late final Future<void> tail;
    void release() {
      if (identical(_preferencesQueue, tail)) _preferencesQueue = null;
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object _) => release(),
    );
    _preferencesQueue = _lastOperation = tail;
    return result;
  }

  Future<void> _initialize(Future<WorkspaceSnapshot> Function() readLegacy) =>
      _queue(() async {
        final stored = await _preferences.getString(_key);
        if (stored != null) {
          validateSnapshot(_PreferenceState.decode(stored).current.snapshot);
          return;
        }
        final seed = await readLegacy();
        validateSnapshot(seed);
        await _write(
          _PreferenceState(
            current: WorkspaceRevision(revision: 1, snapshot: seed),
          ),
        );
      });

  Future<_PreferenceState> _read() async {
    final stored = await _preferences.getString(_key);
    if (stored == null) {
      throw const WorkspaceStoreException('The workspace is uninitialized.');
    }
    return _PreferenceState.decode(stored);
  }

  Future<void> _write(_PreferenceState state) =>
      _preferences.setString(_key, state.encode());

  @override
  Future<WorkspaceRevision> read() =>
      _queue(() async => (await _read()).current);

  @override
  Future<WorkspaceRevision> save(
    WorkspaceMutation mutation, {
    int? expectedRevision,
    String? operationId,
  }) => _queue(() async {
    final id = validateOperationId(operationId);
    final state = await _read();
    final current = state.current;
    final fingerprint = id == null ? null : mutationFingerprint(mutation);
    if (state.ids[id] case final previous?) {
      if (previous != fingerprint) {
        throw const WorkspaceStoreException(
          'That operation ID already belongs to a different change.',
        );
      }
      return current;
    }
    verifyRevision(expectedRevision, current.revision);
    final updated = mutation.apply(current.snapshot);
    final changed = !snapshotsEqual(updated, current.snapshot);
    if (!changed && id == null) return current;
    if (changed) validateSnapshot(updated);
    final next = changed
        ? WorkspaceRevision(revision: current.revision + 1, snapshot: updated)
        : current;
    await _write(
      _PreferenceState(
        current: next,
        ids: {...state.ids, ?id: ?fingerprint},
        recovery: state.recovery,
      ),
    );
    return next;
  });

  @override
  Future<Uint8List> createBackup() =>
      _queue(() async => encodeBackup((await _read()).current));

  @override
  Future<WorkspaceBackupPreview> previewBackup(Uint8List data) {
    final copy = Uint8List.fromList(data);
    return _queue(() async => decodeBackup(copy));
  }

  @override
  Future<WorkspaceRevision> restoreBackup(
    WorkspaceBackupPreview preview, {
    required int expectedRevision,
  }) => _queue(() async {
    final state = await _read();
    final current = state.current;
    verifyRevision(expectedRevision, current.revision);
    if (snapshotsEqual(current.snapshot, preview.snapshot)) return current;
    validateSnapshot(preview.snapshot);
    final next = WorkspaceRevision(
      revision: current.revision + 1,
      snapshot: preview.snapshot,
    );
    await _write(
      _PreferenceState(
        current: next,
        ids: state.ids,
        recovery: utf8.decode(encodeBackup(current)),
      ),
    );
    return next;
  });

  @override
  Future<Uint8List?> readRecoveryBackup() => _queue(() async {
    final recovery = (await _read()).recovery;
    if (recovery == null) return null;
    final bytes = Uint8List.fromList(utf8.encode(recovery));
    decodeBackup(bytes);
    return bytes;
  });

  @override
  Future<void> close() {
    _closed = true;
    return _lastOperation;
  }
}

class _PreferenceState {
  const _PreferenceState({
    required this.current,
    this.ids = const {},
    this.recovery,
  });

  final WorkspaceRevision current;
  final Map<String, String> ids;
  final String? recovery;

  factory _PreferenceState.decode(String raw) {
    final envelope = jsonObject(decodeJson(raw, 'workspace'), 'workspace');
    if (envelope['version'] != 1) {
      throw const FormatException('Unsupported local workspace version.');
    }
    final payload = stringField(envelope, 'payload');
    if (digestText(payload) != envelope['sha256']) {
      throw const FormatException('The local workspace checksum is invalid.');
    }
    final fields = jsonObject(decodeJson(payload, 'workspace'), 'workspace');
    final ids = jsonObject(fields['ids'], 'workspace operations');
    return _PreferenceState(
      current: WorkspaceRevision(
        revision: positiveRevision(fields['revision']),
        snapshot: snapshotFromFields(fields),
      ),
      ids: {for (final id in ids.keys) id: stringField(ids, id)},
      recovery: fields['recovery'] == null
          ? null
          : stringField(fields, 'recovery'),
    );
  }

  String encode() {
    final payload = jsonEncode({
      'revision': current.revision,
      ...snapshotFields(current.snapshot),
      'ids': ids,
      'recovery': recovery,
    });
    return jsonEncode({
      'version': 1,
      'sha256': digestText(payload),
      'payload': payload,
    });
  }
}
