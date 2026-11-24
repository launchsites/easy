import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'encrypted_backup.dart';
import 'workspace_store.dart';

/// File selection and export stay with the host platform. A save adapter can
/// throw this exception when the user dismisses its destination picker.
final class BackupExportCancelled implements Exception {
  const BackupExportCancelled();
}

class WorkspaceBackupPage extends StatefulWidget {
  const WorkspaceBackupPage({
    required this.store,
    required this.pickBackup,
    required this.exportBackup,
    required this.onRestored,
    super.key,
  });

  final WorkspaceStore store;
  final Future<Uint8List?> Function() pickBackup;
  final Future<void> Function(Uint8List bytes, String filename) exportBackup;
  final Future<void> Function(WorkspaceRevision) onRestored;

  @override
  State<WorkspaceBackupPage> createState() => _WorkspaceBackupPageState();
}

enum _Activity {
  export('Creating backup…', 'The backup could not be exported.'),
  preview('Reading backup…', 'The backup could not be opened.'),
  recovery(
    'Reading recovery point…',
    'The recovery point could not be opened.',
  ),
  restore('Restoring records…', 'The workspace could not be restored.');

  const _Activity(this.label, this.failure);

  final String label;
  final String failure;
}

enum _BackupSource {
  encrypted('Password-protected backup', Icons.lock_outline_rounded),
  plain('Checksum-verified backup', Icons.description_outlined),
  recovery('Previous workspace', Icons.history_rounded);

  const _BackupSource(this.label, this.icon);

  final String label;
  final IconData icon;
}

typedef _Selection = ({
  WorkspaceBackupPreview preview,
  int expectedRevision,
  _BackupSource source,
});

class _WorkspaceBackupPageState extends State<WorkspaceBackupPage> {
  final _previewKey = GlobalKey();
  _Activity? _activity;
  _Selection? _selection;
  ({String message, bool error})? _feedback;
  bool _promptOpen = false;

  Future<void> _run(_Activity activity, Future<void> Function() action) async {
    if (_activity != null) return;
    setState(() {
      _activity = activity;
      _feedback = null;
    });
    try {
      await action();
    } on BackupExportCancelled {
      // The user closed the save picker.
    } on WorkspaceBackupAuthenticationException {
      _inform(
        'Check the passphrase, then choose the backup again.',
        error: true,
      );
    } on WorkspaceRevisionConflict {
      if (mounted) setState(() => _selection = null);
      _inform(
        'The workspace changed after this preview. Open the backup again to review it.',
        error: true,
      );
    } on FormatException {
      _inform(
        'The file is damaged or uses an unsupported backup format.',
        error: true,
      );
    } catch (_) {
      _inform(activity.failure, error: true);
    } finally {
      if (mounted) setState(() => _activity = null);
    }
  }

  void _inform(String message, {bool error = false}) {
    if (mounted) setState(() => _feedback = (message: message, error: error));
  }

  Future<T?> _prompt<T>(WidgetBuilder builder) async {
    setState(() => _promptOpen = true);
    try {
      return await showDialog<T>(context: context, builder: builder);
    } finally {
      if (mounted) setState(() => _promptOpen = false);
    }
  }

  Future<String?> _passphrase({required bool export}) =>
      _prompt((_) => _PassphraseDialog(export: export));

  Future<void> _export() => _run(_Activity.export, () async {
    final passphrase = await _passphrase(export: true);
    if (!mounted || passphrase == null) return;
    final bytes = await widget.store.createEncryptedBackup(passphrase);
    if (!mounted) return;
    await widget.exportBackup(bytes, _backupFilename(DateTime.now()));
    _inform('Password-protected backup saved.');
  });

  Future<void> _chooseBackup() => _run(_Activity.preview, () async {
    final data = await widget.pickBackup();
    if (!mounted || data == null) return;
    // Choosing a replacement file invalidates the old preview, even if
    // the new file or its passphrase turns out to be invalid.
    setState(() => _selection = null);
    final encrypted = isEncryptedWorkspaceBackup(data);
    final password = encrypted ? await _passphrase(export: false) : null;
    if (!mounted || encrypted && password == null) return;
    final expected = (await widget.store.read()).revision;
    final preview = password != null
        ? await widget.store.previewEncryptedBackup(data, password)
        : await widget.store.previewBackup(data);
    _showSelection(
      preview,
      expected,
      encrypted ? _BackupSource.encrypted : _BackupSource.plain,
    );
  });

  Future<void> _chooseRecovery() => _run(_Activity.recovery, () async {
    final expected = (await widget.store.read()).revision;
    final bytes = await widget.store.readRecoveryBackup();
    if (bytes == null) {
      _inform('A recovery point is created the first time you restore.');
      return;
    }
    final preview = await widget.store.previewBackup(bytes);
    _showSelection(preview, expected, _BackupSource.recovery);
  });

  void _showSelection(
    WorkspaceBackupPreview preview,
    int expected,
    _BackupSource source,
  ) {
    if (mounted) {
      setState(() {
        _selection = (
          preview: preview,
          expectedRevision: expected,
          source: source,
        );
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final anchor = _previewKey.currentContext;
        if (anchor == null || !mounted) return;
        Scrollable.ensureVisible(
          anchor,
          duration: MediaQuery.disableAnimationsOf(anchor)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  Future<void> _confirmRestore() => _run(_Activity.restore, () async {
    final selected = _selection;
    if (selected == null) return;
    final confirm = await _prompt<bool>(
      (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: const Text(
          'This replaces your workspace records. Easy saves the current records '
          'as a recovery point first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore records'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    final restored = await widget.store.restoreBackup(
      selected.preview,
      expectedRevision: selected.expectedRevision,
    );
    if (mounted) setState(() => _selection = null);
    if (restored.revision == selected.expectedRevision) {
      _inform('The workspace already matches this backup.');
      return;
    }
    try {
      await widget.onRestored(restored);
    } catch (_) {
      _inform(
        'Records were restored. Reopen Easy to load the workspace.',
        error: true,
      );
      return;
    }
    _inform('Workspace restored. Your previous records are in Recovery point.');
  });

  @override
  Widget build(BuildContext context) {
    final activity = _activity;
    final enabled = activity == null;
    final selected = _selection;
    return PopScope(
      canPop: enabled,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Backup and restore'),
          backgroundColor: paper,
          surfaceTintColor: paper,
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Workspace records', style: sectionHeadingStyle),
                    const SizedBox(height: 6),
                    const Text(
                      'Backups include your saved records. Media files stay on this device.',
                      style: contentMetadataStyle,
                    ),
                    const SizedBox(height: 14),
                    _BackupCard(
                      child: Column(
                        children: [
                          _BackupAction(
                            title: 'Export encrypted backup',
                            description: 'Save a copy with a passphrase.',
                            icon: Icons.lock_outline_rounded,
                            onTap: enabled ? _export : null,
                          ),
                          const Divider(),
                          _BackupAction(
                            title: 'Open a backup',
                            description:
                                'Review its contents before restoring.',
                            icon: Icons.folder_open_rounded,
                            onTap: enabled ? _chooseBackup : null,
                          ),
                          const Divider(),
                          _BackupAction(
                            title: 'Recovery point',
                            description: 'Open the workspace saved before the last restore.',
                            icon: Icons.history_rounded,
                            onTap: enabled ? _chooseRecovery : null,
                          ),
                        ],
                      ),
                    ),
                    if (activity != null && !_promptOpen) ...[
                      const SizedBox(height: 14),
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          children: [
                            const SizedBox.square(
                              dimension: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                activity.label,
                                style: contentMetadataStyle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_feedback case final feedback?) ...[
                      const SizedBox(height: 14),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          feedback.message,
                          style: feedback.error
                              ? contentMetadataStyle.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                )
                              : contentMetadataStyle,
                        ),
                      ),
                    ],
                    if (selected != null) ...[
                      const SizedBox(height: 24),
                      _RestorePreview(
                        key: _previewKey,
                        selection: selected,
                        onRestore: enabled ? _confirmRestore : null,
                        onDismiss: enabled
                            ? () => setState(() => _selection = null)
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _BackupAction extends StatelessWidget {
  const _BackupAction({
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: softAccent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: accent, size: 19),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: contentTitleStyle),
                const SizedBox(height: 3),
                Text(description, style: contentMetadataStyle),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded, color: muted, size: 18),
        ],
      ),
    ),
  );
}

class _RestorePreview extends StatelessWidget {
  const _RestorePreview({
    required this.selection,
    required this.onRestore,
    required this.onDismiss,
    super.key,
  });

  final _Selection selection;
  final VoidCallback? onRestore;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final preview = selection.preview;
    final counts = preview.counts;
    return _BackupCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Restore preview', style: sectionHeadingStyle),
            const SizedBox(height: 9),
            Row(
              children: [
                Icon(selection.source.icon, color: accent, size: 18),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    selection.source.label,
                    style: contentMetadataStyle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            for (final (title, count) in [
              ('Tasks', counts.tasks),
              ('Calendar events', counts.events),
              ('Notes', counts.notes),
              if (counts.captures > 0) ('Captures', counts.captures),
              ('Gym sessions', counts.gymSessions),
              ('Workout plans', counts.workoutPlans),
            ]) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(child: Text(title, style: contentMetadataStyle)),
                    Text('$count', style: contentTitleStyle),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                FilledButton(
                  onPressed: onRestore,
                  child: const Text('Review restore'),
                ),
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Close preview'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.export});

  final bool export;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  final _confirmationFocus = FocusNode();
  String? _error;

  void _submit() {
    final phrase = _passphrase.text;
    final error = phrase.isEmpty
        ? 'Enter a passphrase.'
        : phrase.length > 1024 || utf8.encode(phrase).length > 1024
        ? 'Use a shorter passphrase.'
        : widget.export && phrase != _confirm.text
        ? 'Enter the same passphrase again.'
        : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(phrase);
  }

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    _confirmationFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.export ? 'Protect your backup' : 'Unlock backup'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.export) ...[
          const Text('Keep this passphrase somewhere you can retrieve it.'),
          const SizedBox(height: 13),
        ],
        TextField(
          controller: _passphrase,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: widget.export
              ? TextInputAction.next
              : TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Passphrase'),
          onSubmitted: (_) {
            if (widget.export) {
              _confirmationFocus.requestFocus();
            } else {
              _submit();
            }
          },
        ),
        if (widget.export)
          TextField(
            controller: _confirm,
            focusNode: _confirmationFocus,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Repeat passphrase'),
            onSubmitted: (_) => _submit(),
          ),
        if (_error case final error?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.export ? 'Continue' : 'Open'),
      ),
    ],
  );
}

String _backupFilename(DateTime date) {
  String two(int number) => number.toString().padLeft(2, '0');
  return 'Easy-backup-${date.year}-${two(date.month)}-${two(date.day)}'
      '-${two(date.hour)}${two(date.minute)}${two(date.second)}.easybackup';
}
