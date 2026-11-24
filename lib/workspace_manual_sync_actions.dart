part of 'main.dart';

extension _WorkspaceManualSyncActions on _WorkspaceState {
  Future<void> _openManualSync() async {
    final store = _store;
    if (kIsWeb || store == null || _manualSyncOpen) return;
    _manualSyncOpen = true;
    final installation = defaultTargetPlatform == TargetPlatform.linux
        ? ManualSyncInstallation.withPassphrase(
            preferences: _legacyPreferences,
            unlock: (forSetup) async {
              await WidgetsBinding.instance.endOfFrame;
              if (!mounted) return null;
              return showSyncPasswordVaultPrompt(context, forSetup: forSetup);
            },
          )
        : ManualSyncInstallation(
            preferences: _legacyPreferences,
            credentials: const SyncDeviceCredentials(SyncSystemSecretVault()),
          );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ManualSyncPage(
            host: ManualSyncPageHost(
              openConfigured: installation.openConfigured,
              enable: installation.enable,
              copyToken: (token) =>
                  Clipboard.setData(ClipboardData(text: token)),
              pasteToken: () async =>
                  (await Clipboard.getData(Clipboard.kTextPlain))?.text,
              pickBundle: () => _pickFileBytes(SyncEnvelopeCodec.maximumBytes),
              saveBundle: _saveSyncBundle,
            ),
            projector: WorkspaceManualSyncProjector(
              store: store,
              flushWorkspaceWrites: _flushManualSyncWrites,
              onRestored: _loadRevision,
            ),
          ),
        ),
      );
    } finally {
      try {
        await installation.close();
      } on Object {
        if (mounted) _inform('The sync workspace could not be closed.');
      } finally {
        _manualSyncOpen = false;
      }
    }
  }

  Future<void> _flushManualSyncWrites() async {
    await _pendingSave;
    if (!mounted ||
        _reviewSaving ||
        !identical(_data, _savedWorkspace) ||
        !identical(_gymSessions, _savedGymSessions) ||
        !identical(_workoutPlans, _savedWorkoutPlans)) {
      throw const SyncJournalException('Save local changes before continuing.');
    }
  }

  Future<void> _saveSyncBundle(Uint8List bytes, String filename) async {
    try {
      await _exportFile(bytes, filename, 'application/octet-stream');
    } on BackupExportCancelled {
      throw const ManualSyncTransferCancelled();
    }
  }
}
