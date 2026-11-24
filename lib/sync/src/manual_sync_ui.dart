import 'package:material_ui/material_ui.dart';

import '../../ui_theme.dart';
import '../manual_sync_workspace.dart';

class ManualSyncFrame extends StatelessWidget {
  const ManualSyncFrame({
    required this.title,
    required this.child,
    this.canPop = true,
    super.key,
  });

  final String title;
  final Widget child;
  final bool canPop;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    child: Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: paper,
        surfaceTintColor: paper,
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      ),
    ),
  );
}

class ManualSyncSurface extends StatelessWidget {
  const ManualSyncSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: contentSurfaceRadius,
      side: BorderSide(color: line),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class ManualSyncFeedback extends StatelessWidget {
  const ManualSyncFeedback(this.message, {this.error = false, super.key});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: error
          ? contentMetadataStyle.copyWith(
              color: Theme.of(context).colorScheme.error,
            )
          : contentMetadataStyle,
    ),
  );
}

const manualSyncPadding = EdgeInsets.fromLTRB(20, 14, 20, 36);

String manualFingerprint(String value) =>
    RegExp(r'.{1,4}')
        .allMatches(value.toUpperCase())
        .map((match) => match.group(0))
        .join(' ');

String manualSyncError(Object? error, String fallback) => switch (error) {
  SyncPairingException(:final message) => message,
  SyncPairedWorkspaceException(:final message) => message,
  SyncVaultException(:final message) => message,
  SyncTrustException(:final message) => message,
  SyncHistoryException(:final message) => message,
  SyncJournalException(:final message) => message,
  SyncJournalRevisionConflict() =>
    'The sync workspace changed. Review it again.',
  SyncAuthenticationException() =>
    'The file or code could not be verified for this device.',
  FormatException() => 'The file or code has an unsupported format.',
  _ => fallback,
};

Future<bool> confirmManualSync(
  BuildContext context, {
  required String title,
  required String explanation,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> requestManualSyncToken(
  BuildContext context, {
  required String title,
  required String label,
  String action = 'Continue',
  int maximumLength = 4096,
  Future<String?> Function()? paste,
  bool optional = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TokenDialog(
    title: title,
    label: label,
    action: action,
    maximumLength: maximumLength,
    paste: paste,
    optional: optional,
  ),
);

class _TokenDialog extends StatefulWidget {
  const _TokenDialog({
    required this.title,
    required this.label,
    required this.action,
    required this.maximumLength,
    required this.paste,
    required this.optional,
  });

  final String title;
  final String label;
  final String action;
  final int maximumLength;
  final Future<String?> Function()? paste;
  final bool optional;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final _token = TextEditingController();
  String? _error;
  var _pasting = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _token.text.trim();
    if (value.length > widget.maximumLength) {
      setState(() => _error = 'This code is too long.');
      return;
    }
    if (value.isNotEmpty || widget.optional) Navigator.pop(context, value);
  }

  Future<void> _paste() async {
    setState(() => _pasting = true);
    try {
      final value = await widget.paste!();
      if (!mounted) return;
      if (value != null && value.length <= widget.maximumLength) {
        _token.text = value.trim();
      } else if (value != null) {
        _error = 'This code is too long.';
      }
    } catch (_) {
      if (mounted) _error = 'The clipboard could not be opened.';
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 520),
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 472,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _token,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            maxLength: widget.maximumLength,
            maxLines: widget.maximumLength < 20 ? 1 : 4,
            decoration: InputDecoration(
              labelText: widget.label,
              counterText: '',
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.paste != null)
            TextButton.icon(
              onPressed: _pasting ? null : _paste,
              icon: const Icon(Icons.content_paste_rounded, size: 17),
              label: const Text('Paste from clipboard'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _token.text.trim().isEmpty && !widget.optional
            ? null
            : _submit,
        child: Text(widget.action),
      ),
    ],
  );
}
