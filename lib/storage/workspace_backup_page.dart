import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'attachment_store.dart';
import 'encrypted_backup.dart';
import 'media_backup.dart';
import 'workspace_history_page.dart';
import 'workspace_store.dart';

/// File selection and export stay with the host platform. A save adapter can
/// throw this exception when the user dismisses its destination picker.
final class BackupExportCancelled implements Exception {
  const BackupExportCancelled();
}

/// Native file and attachment adapters for portable backups with media.
final class WorkspaceMediaBackupUiSupport {
  const WorkspaceMediaBackupUiSupport({
    required this.loadAttachments,
    required this.pickBackupFile,
    required this.saveMediaArchive,
    this.limits = const WorkspaceMediaBackupLimits(),
    this.scratchDirectory,
  });

  final Future<AttachmentStore?> Function() loadAttachments;
  final Future<XFile?> Function() pickBackupFile;
  final Future<void> Function(WorkspaceMediaBackupFile) saveMediaArchive;
  final WorkspaceMediaBackupLimits limits;
  final String? scratchDirectory;
}

class WorkspaceBackupPage extends StatefulWidget {
  const WorkspaceBackupPage({
    required this.store,
    required this.pickBackup,
    required this.exportBackup,
    required this.onRestored,
    this.media,
    super.key,
  });

  final WorkspaceStore store;
  final Future<Uint8List?> Function() pickBackup;
  final Future<void> Function(Uint8List bytes, String filename) exportBackup;
  final Future<void> Function(WorkspaceRevision) onRestored;
  final WorkspaceMediaBackupUiSupport? media;

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
  media('Password-protected backup with media', Icons.lock_outline_rounded),
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
  WorkspaceMediaBackupPreview? media,
});

typedef _BackupPassphrase = ({String passphrase, bool includeMedia});

class _WorkspaceBackupPageState extends State<WorkspaceBackupPage> {
  final _previewKey = GlobalKey();
  _Activity? _activity;
  _Selection? _selection;
  ({String message, bool error})? _feedback;
  bool _promptOpen = false;

  @override
  void dispose() {
    unawaited(_closeMediaPreview(_selection?.media));
    super.dispose();
  }

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
    } on WorkspaceMediaBackupAuthenticationException {
      _inform(
        'Check the passphrase, then choose the backup again.',
        error: true,
      );
    } on WorkspaceRevisionConflict {
      await _discardSelection();
      _inform(
        'The workspace changed after this preview. Open the backup again to review it.',
        error: true,
      );
    } on WorkspaceMediaBackupException catch (error) {
      _inform(error.message, error: true);
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

  Future<_BackupPassphrase?> _passphrase({required bool export}) => _prompt(
    (_) => _PassphraseDialog(export: export, allowMedia: widget.media != null),
  );

  Future<AttachmentStore> _attachmentStore(
    WorkspaceMediaBackupUiSupport support,
  ) async =>
      await support.loadAttachments() ??
      (throw const WorkspaceMediaBackupException(
        'The attachment store could not be opened.',
      ));

  Future<void> _export() => _run(_Activity.export, () async {
    final chosen = await _passphrase(export: true);
    if (!mounted || chosen == null) return;
    if (widget.media case final support? when chosen.includeMedia) {
      final archive = await createWorkspaceMediaBackup(
        store: widget.store,
        attachments: await _attachmentStore(support),
        passphrase: chosen.passphrase,
        limits: support.limits,
        scratchDirectory: support.scratchDirectory,
      );
      try {
        if (!mounted) return;
        await support.saveMediaArchive(archive);
      } finally {
        await archive.close();
      }
      _inform('Password-protected backup with media saved.');
      return;
    }
    final bytes = await widget.store.createEncryptedBackup(chosen.passphrase);
    if (!mounted) return;
    await widget.exportBackup(bytes, _backupFilename(DateTime.now()));
    _inform('Password-protected backup saved.');
  });

  Future<void> _chooseBackup() => _run(_Activity.preview, () async {
    final support = widget.media;
    final Uint8List? data;
    if (support != null) {
      final file = await support.pickBackupFile();
      if (!mounted || file == null) return;
      await _discardSelection();
      final prefix = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, 8)) {
        prefix.add(chunk);
      }
      if (isWorkspaceMediaBackup(prefix.takeBytes())) {
        await _previewMedia(file, support);
        return;
      }
      data = await _readLogicalFile(file);
    } else {
      data = await widget.pickBackup();
      if (!mounted || data == null) return;
      await _discardSelection();
    }
    if (!mounted) return;
    final encrypted = isEncryptedWorkspaceBackup(data);
    final password = encrypted
        ? (await _passphrase(export: false))?.passphrase
        : null;
    if (!mounted || encrypted && password == null) return;
    final expected = (await widget.store.read()).revision;
    final preview = password != null
        ? await widget.store.previewEncryptedBackup(data, password)
        : await widget.store.previewBackup(data);
    await _showSelection(
      preview,
      expected,
      encrypted ? _BackupSource.encrypted : _BackupSource.plain,
    );
  });

  Future<Uint8List> _readLogicalFile(XFile file) async {
    final limit = maximumEncryptedWorkspaceBackupBytes;
    if (await file.length() > limit) {
      throw const FormatException('The selected backup is too large.');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (chunk.length > limit - buffer.length) {
        throw const FormatException('The selected backup is too large.');
      }
      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }

  Future<void> _previewMedia(
    XFile file,
    WorkspaceMediaBackupUiSupport support,
  ) async {
    if (!mounted) return;
    final password = (await _passphrase(export: false))?.passphrase;
    if (!mounted || password == null) return;
    final preview = await previewWorkspaceMediaBackup(
      store: widget.store,
      source: file.openRead(),
      passphrase: password,
      limits: support.limits,
      scratchDirectory: support.scratchDirectory,
    );
    await _showSelection(
      preview.backup,
      preview.expectedRevision,
      _BackupSource.media,
      media: preview,
    );
  }

  Future<void> _discardSelection() async {
    final old = _selection;
    if (mounted) setState(() => _selection = null);
    await _closeMediaPreview(old?.media);
  }

  Future<void> _chooseRecovery() => _run(_Activity.recovery, () async {
    final expected = (await widget.store.read()).revision;
    final bytes = await widget.store.readRecoveryBackup();
    if (bytes == null) {
      _inform('A recovery point is created the first time you restore.');
      return;
    }
    final preview = await widget.store.previewBackup(bytes);
    await _showSelection(preview, expected, _BackupSource.recovery);
  });

  Future<void> _openHistory(WorkspaceHistoryStore store) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => WorkspaceHistoryPage(
            store: store,
            onRestored: (revision) async {
              await _discardSelection();
              await widget.onRestored(revision);
            },
          ),
        ),
      );

  Future<void> _showSelection(
    WorkspaceBackupPreview preview,
    int expected,
    _BackupSource source, {
    WorkspaceMediaBackupPreview? media,
  }) async {
    await _discardSelection();
    if (mounted) {
      setState(() {
        _selection = (
          preview: preview,
          expectedRevision: expected,
          source: source,
          media: media,
        );
      });
    } else {
      await _closeMediaPreview(media);
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
        content: Text(
          selected.media == null
              ? 'This replaces your workspace records. Easy saves the current records as a recovery point first.'
              : 'This replaces your workspace records and restores the original media in this backup. Easy saves the current records as a recovery point first.',
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
    final restored = switch (selected.media) {
      final preview? => await restoreWorkspaceMediaBackup(
        store: widget.store,
        attachments: await _attachmentStore(widget.media!),
        preview: preview,
      ),
      _ => await widget.store.restoreBackup(
        selected.preview,
        expectedRevision: selected.expectedRevision,
      ),
    };
    await _discardSelection();
    if (restored.revision == selected.expectedRevision) {
      _inform(
        selected.media == null ? 'The workspace already matches this backup.' : 'Media restored. The workspace records already match this backup.',
      );
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
                    Text(
                      widget.media == null
                          ? 'Save and restore your workspace records.'
                          : 'Save your records with optional voice recordings and meal photos.',
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
                          if (widget.store
                              case final WorkspaceHistoryStore history) ...[
                            const Divider(),
                            _BackupAction(
                              title: 'Version history',
                              description: 'Review saved versions or restore selected records.',
                              icon: Icons.bookmarks_outlined,
                              onTap: enabled
                                  ? () => _openHistory(history)
                                  : null,
                            ),
                          ],
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
                        onDismiss: enabled ? _discardSelection : null,
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
              if (counts.meals > 0) ('Meals', counts.meals),
              if (counts.foods > 0) ('Saved foods', counts.foods),
              if (counts.activities > 0) ('Activities', counts.activities),
              if (counts.routines > 0) ('Routines', counts.routines),
              if (selection.media case final media?)
                ('Original files', media.attachments.length),
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
  const _PassphraseDialog({required this.export, required this.allowMedia});

  final bool export;
  final bool allowMedia;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  final _confirmationFocus = FocusNode();
  var _includeMedia = false;
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
    Navigator.of(context)
        .pop((passphrase: phrase, includeMedia: _includeMedia));
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
        if (widget.export && widget.allowMedia)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeMedia,
            title: const Text('Include voice recordings and meal photos'),
            onChanged: (enabled) => setState(() => _includeMedia = enabled!),
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

Future<void> _closeMediaPreview(WorkspaceMediaBackupPreview? preview) async {
  if (preview == null) return;
  try {
    await preview.close();
  } catch (_) {
    // The native temporary directory can remove an encrypted file later.
  }
}

String _backupFilename(DateTime date) {
  String two(int number) => number.toString().padLeft(2, '0');
  return 'Easy-backup-${date.year}-${two(date.month)}-${two(date.day)}'
      '-${two(date.hour)}${two(date.minute)}${two(date.second)}.easybackup';
}
