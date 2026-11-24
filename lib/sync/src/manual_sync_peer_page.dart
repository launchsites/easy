import 'package:material_ui/material_ui.dart';

import '../../storage/workspace_store.dart';
import '../../ui_theme.dart';
import '../manual_sync_contracts.dart';
import '../manual_sync_workspace.dart';
import 'manual_sync_ui.dart';

class ManualSyncPeerPage extends StatefulWidget {
  const ManualSyncPeerPage({
    required this.workspace,
    required this.peerId,
    required this.host,
    required this.projector,
    super.key,
  });

  final ManualSyncWorkspace workspace;
  final String peerId;
  final ManualSyncPageHost host;
  final ManualSyncProjector? projector;

  @override
  State<ManualSyncPeerPage> createState() => _ManualSyncPeerPageState();
}

class _ManualSyncPeerPageState extends State<ManualSyncPeerPage> {
  ({String message, bool error})? _feedback;
  SyncRevocationPreview? _pendingCleanup;
  var _busy = false;
  var _revoked = false;

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await work();
    } on ManualSyncTransferCancelled {
      // The user dismissed a transfer prompt.
    } catch (error) {
      _inform(
        manualSyncError(error, 'The sync action could not be completed.'),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _inform(String message, {bool error = false}) {
    if (mounted) setState(() => _feedback = (message: message, error: error));
  }

  Future<void> _export() => _run(() async {
    final receipt = await requestManualSyncToken(
      context,
      title: 'Export changes',
      label: 'Progress code from the other device, if available',
      action: 'Build change bundle',
      maximumLength: 8192,
      paste: widget.host.pasteToken,
      optional: true,
    );
    if (receipt == null || !mounted) return;
    final bundle = await widget.workspace.exportFor(
      widget.peerId,
      peerProgress: receipt.isEmpty ? null : receipt,
    );
    if (!mounted) return;
    if (bundle == null) {
      _inform('No changes to export for this progress code.');
      return;
    }
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .split('.')
        .first;
    await widget.host.saveBundle(
      bundle.bytes,
      'workspace-changes-$stamp.easysync',
    );
    _inform(
      bundle.hasMore
          ? 'Bundle saved. Exchange a fresh progress code to export the next bundle.'
          : '${_changes(bundle.changeCount)} saved in an encrypted bundle.',
    );
  });

  Future<void> _copyProgress() => _run(() async {
    final receipt = await widget.workspace.progressFor(widget.peerId);
    if (!mounted) return;
    await widget.host.copyToken(receipt);
    _inform(
      'Progress code copied. Give it to this device before the next export.',
    );
  });

  Future<void> _import() => _run(() async {
    final bytes = await widget.host.pickBundle();
    if (bytes == null || !mounted) return;
    final preview = await widget.workspace.previewIncoming(
      bytes: bytes,
      senderId: widget.peerId,
    );
    if (!mounted) return;
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _BundleReview(
          workspace: widget.workspace,
          preview: preview,
          projector: widget.projector,
        ),
      ),
    );
    if (imported == true) _inform('Change bundle saved in the sync journal.');
  });

  Future<void> _revoke() => _run(() async {
    final reviewed = await widget.workspace.reviewRevocation(widget.peerId);
    if (!mounted) return;
    final confirm = await confirmManualSync(
      context,
      title: 'Revoke this device?',
      explanation:
          'This removes access for ${manualFingerprint(widget.peerId)}. Copies already shared stay with the recipient.',
      action: 'Revoke device',
    );
    if (!confirm || !mounted) return;
    final result = await widget.workspace.confirmRevocation(reviewed);
    if (!mounted) return;
    setState(() {
      _revoked = true;
      _pendingCleanup = result.credentialRemoved ? null : reviewed;
    });
    _inform(
      result.credentialRemoved
          ? 'Device revoked.'
          : 'Device revoked. Unlock the vault to remove its saved key.',
    );
  });

  Future<void> _retryCleanup() => _run(() async {
    final removed = await widget.workspace.retryRevocationCleanup(
      _pendingCleanup!,
    );
    if (!mounted) return;
    if (removed) setState(() => _pendingCleanup = null);
    _inform(
      removed
          ? 'Device key removed.'
          : 'Unlock the vault to remove its saved key.',
    );
  });

  @override
  Widget build(BuildContext context) => ManualSyncFrame(
    title: 'Paired device',
    canPop: !_busy,
    child: ListView(
      padding: manualSyncPadding,
      children: [
        ManualSyncSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _revoked ? 'Revoked device' : 'Device fingerprint',
                style: sectionHeadingStyle,
              ),
              const SizedBox(height: 7),
              SelectableText(
                manualFingerprint(widget.peerId),
                style: contentMetadataStyle,
              ),
            ],
          ),
        ),
        if (!_revoked) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('Export changes'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Open change bundle'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _busy ? null : _copyProgress,
              child: const Text('Copy progress code'),
            ),
          ),
        ],
        if (_feedback case final feedback?) ...[
          const SizedBox(height: 10),
          ManualSyncFeedback(feedback.message, error: feedback.error),
        ],
        const SizedBox(height: 18),
        if (!_revoked)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _busy ? null : _revoke,
              child: const Text('Revoke this device'),
            ),
          )
        else if (_pendingCleanup != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _busy ? null : _retryCleanup,
              child: const Text('Remove saved key'),
            ),
          ),
      ],
    ),
  );
}

class _BundleReview extends StatefulWidget {
  const _BundleReview({
    required this.workspace,
    required this.preview,
    required this.projector,
  });

  final ManualSyncWorkspace workspace;
  final SyncImportPreview preview;
  final ManualSyncProjector? projector;

  @override
  State<_BundleReview> createState() => _BundleReviewState();
}

class _BundleReviewState extends State<_BundleReview> {
  SyncJournalStatus? _committed;
  String? _error;
  var _approveRemovals = false;
  var _approveConflicts = false;
  var _busy = false;

  Future<void> _commit() => _run(() async {
    final state = await widget.workspace.commitIncoming(
      widget.preview,
      approveDestructiveChanges: _approveRemovals,
      approveConflicts: _approveConflicts,
    );
    if (mounted) setState(() => _committed = state);
  });

  Future<void> _project() => _run(() async {
    final projector = widget.projector!;
    final preview = await projector.previewIncoming(
      sync: widget.workspace,
      imported: widget.preview,
      committed: _committed!,
    );
    if (!mounted) return;
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            _WorkspaceProjectionReview(projector: projector, preview: preview),
      ),
    );
    if (mounted && applied == true) Navigator.of(context).pop(true);
  });

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) {
        _error = manualSyncError(error, 'These changes could not be saved.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final committed = _committed != null;
    final deferred = preview.missing.counters.isNotEmpty;
    final canApply =
        !_busy &&
        !deferred &&
        (!preview.hasDestructiveChanges || _approveRemovals) &&
        (!preview.hasConflicts || _approveConflicts);
    return ManualSyncFrame(
      title: 'Review change bundle',
      canPop: !_busy,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: manualSyncPadding,
              children: [
                Text(
                  committed
                      ? 'Saved to the sync journal'
                      : preview.changeCount == 0 && preview.records.isNotEmpty
                      ? 'Previously saved records'
                      : _changes(preview.changeCount),
                  style: sectionHeadingStyle,
                ),
                const SizedBox(height: 7),
                Text(
                  manualFingerprint(preview.senderId),
                  style: contentMetadataStyle,
                ),
                if (deferred) ...[
                  const SizedBox(height: 12),
                  const ManualSyncFeedback(
                    'Open the missing earlier bundles before saving these changes.',
                    error: true,
                  ),
                ],
                if (preview.duplicateCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${_changes(preview.duplicateCount)} already saved.',
                    style: contentMetadataStyle,
                  ),
                ],
                if (preview.records.isNotEmpty) ...[
                  const SizedBox(height: 15),
                  ManualSyncSurface(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final (index, change)
                            in preview.records.indexed) ...[
                          if (index > 0) const Divider(),
                          ListTile(
                            title: Text(
                              _recordTitle(change),
                              style: contentTitleStyle,
                            ),
                            subtitle: Text(
                              _syncChangeLabel(change),
                              style: contentMetadataStyle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (!committed && !deferred) ...[
                  if (preview.hasDestructiveChanges)
                    CheckboxListTile(
                      title: const Text('Approve removals and restores'),
                      value: _approveRemovals,
                      onChanged: _busy
                          ? null
                          : (value) => setState(
                              () => _approveRemovals = value ?? false,
                            ),
                    ),
                  if (preview.hasConflicts)
                    CheckboxListTile(
                      title: const Text(
                        'Keep both versions of conflicting records',
                      ),
                      value: _approveConflicts,
                      onChanged: _busy
                          ? null
                          : (value) => setState(
                              () => _approveConflicts = value ?? false,
                            ),
                    ),
                ],
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  ManualSyncFeedback(error, error: true),
                ],
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 11, 20, 15),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!committed)
                    FilledButton(
                      onPressed: canApply ? _commit : null,
                      child: Text(
                        preview.changeCount == 0 && preview.records.isNotEmpty
                            ? 'Continue with saved records'
                            : 'Save reviewed bundle',
                      ),
                    ),
                  if (committed &&
                      widget.projector != null &&
                      preview.records.isNotEmpty)
                    FilledButton(
                      onPressed: _busy ? null : _project,
                      child: const Text('Review workspace changes'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(committed),
                    child: Text(committed ? 'Done' : 'Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceProjectionReview extends StatefulWidget {
  const _WorkspaceProjectionReview({
    required this.projector,
    required this.preview,
  });

  final ManualSyncProjector projector;
  final ManualSyncProjectionPreview preview;

  @override
  State<_WorkspaceProjectionReview> createState() =>
      _WorkspaceProjectionReviewState();
}

class _WorkspaceProjectionReviewState
    extends State<_WorkspaceProjectionReview> {
  final _selected = <SyncRecordKey>{};
  String? _error;
  var _busy = false;
  var _stale = false;

  Future<void> _apply() async {
    if (_busy) return;
    final count = _selected.length;
    final removals = widget.preview.records
        .where(
          (record) =>
              _selected.contains(record.key) &&
              record.action == ManualSyncProjectionAction.remove,
        )
        .length;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirm = await confirmManualSync(
        context,
        title: 'Apply ${_changes(count)} to your workspace?',
        explanation:
            '${removals > 0 ? '$removals ${removals == 1 ? 'record will be removed' : 'records will be removed'}. ' : ''}Your current records are saved as a recovery point first.',
        action: 'Apply selected changes',
      );
      if (!confirm || !mounted) return;
      await widget.projector.applyIncoming(
        widget.preview,
        selected: Set.unmodifiable(_selected),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on WorkspaceRevisionConflict {
      _stale = true;
      _error = 'Your workspace changed while you reviewed this selection. Open a fresh workspace review.';
    } catch (error) {
      _error = manualSyncError(
        error,
        'These records could not be applied to your workspace.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ManualSyncFrame(
    title: 'Apply to workspace',
    canPop: !_busy,
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: manualSyncPadding,
            children: [
              const Text(
                'Choose changes for your workspace',
                style: sectionHeadingStyle,
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 10),
                ManualSyncFeedback(error, error: true),
              ],
              const SizedBox(height: 12),
              if (widget.preview.records.isEmpty)
                const Text(
                  'The reviewed records already match your workspace.',
                  style: contentMetadataStyle,
                ),
              for (final record in widget.preview.records)
                CheckboxListTile(
                  key: ValueKey(record.key),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(record.title, style: contentTitleStyle),
                  subtitle: Text(
                    record.details ?? _projectionLabel(record.action),
                    style: contentMetadataStyle,
                  ),
                  value: _selected.contains(record.key),
                  onChanged: _busy || _stale || !record.selectable
                      ? null
                      : (value) => setState(() {
                          if (value ?? false) {
                            _selected.add(record.key);
                          } else {
                            _selected.remove(record.key);
                          }
                        }),
                ),
            ],
          ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 11, 20, 15),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              onPressed: _busy || _stale || _selected.isEmpty ? null : _apply,
              child: Text(
                _selected.isEmpty
                    ? 'Review selection'
                    : 'Review ${_changes(_selected.length)}',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

String _changes(int count) => '$count ${count == 1 ? 'change' : 'changes'}';

String _recordTitle(SyncRecordChange change) {
  final record = change.after ?? change.before;
  for (final field in ['title', 'name', 'text', 'body']) {
    final value = record?.fields[field]?.firstOrNull?.value;
    if (value is String && value.trim().isNotEmpty) {
      return String.fromCharCodes(value.runes.take(120));
    }
  }
  return switch (change.key.kind) {
    SyncRecordKind.task => 'Task',
    SyncRecordKind.calendarEvent => 'Calendar event',
    SyncRecordKind.note => 'Note',
    SyncRecordKind.capture => 'Capture',
    SyncRecordKind.gymSession => 'Gym session',
    SyncRecordKind.workoutPlan => 'Workout plan',
    SyncRecordKind.meal => 'Meal',
  };
}

String _syncChangeLabel(SyncRecordChange change) {
  if (change.isReplay) return 'Current saved version';
  if (change.after?.hasConflicts ?? false) return 'Conflicting versions';
  if (change.after?.state == SyncRecordState.deleted) return 'Removal';
  if (change.before?.state == SyncRecordState.deleted) return 'Restore';
  return change.before == null ? 'New record' : 'Record update';
}

String _projectionLabel(ManualSyncProjectionAction action) => switch (action) {
  ManualSyncProjectionAction.add => 'Add to workspace',
  ManualSyncProjectionAction.update => 'Update in workspace',
  ManualSyncProjectionAction.remove => 'Remove from workspace',
  ManualSyncProjectionAction.resolveConflict => 'Resolution required',
};
