import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'sync_credentials.dart';
import 'sync_password_vault.dart';

/// Returns an unlocked vault from an explicit setup or unlock action. The
/// caller owns a returned vault and closes it when its sync session ends.
Future<SyncPasswordVault?> showSyncPasswordVaultPrompt(
  BuildContext context, {
  required bool forSetup,
  String? filePath,
}) => showDialog<SyncPasswordVault>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SyncPasswordPrompt(forSetup: forSetup, filePath: filePath),
);

class _SyncPasswordPrompt extends StatefulWidget {
  const _SyncPasswordPrompt({required this.forSetup, required this.filePath});

  final bool forSetup;
  final String? filePath;

  @override
  State<_SyncPasswordPrompt> createState() => _SyncPasswordPromptState();
}

class _SyncPasswordPromptState extends State<_SyncPasswordPrompt> {
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();
  final _passphraseFocus = FocusNode();
  final _repeatFocus = FocusNode();
  String? _error;
  bool _opening = false;
  bool _showPassphrase = false;

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    _passphraseFocus.dispose();
    _repeatFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_opening) return;
    final passphrase = _passphrase.text;
    if (passphrase.trim().isEmpty) {
      setState(() => _error = 'Enter your passphrase.');
      return;
    }
    if (widget.forSetup && _repeat.text != passphrase) {
      setState(() => _error = 'Enter the same passphrase twice.');
      _repeatFocus.requestFocus();
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final vault = await openSyncPasswordVault(
        passphrase: passphrase,
        filePath: widget.filePath,
        createIfMissing: widget.forSetup,
      );
      if (!mounted) {
        await vault.close();
        return;
      }
      _passphrase.clear();
      _repeat.clear();
      Navigator.of(context).pop(vault);
    } on SyncVaultException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        if (_error != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _opening || _error == null) return;
            _passphraseFocus.requestFocus();
            if (!widget.forSetup) {
              _passphrase.selection = TextSelection(
                baseOffset: 0,
                extentOffset: _passphrase.text.length,
              );
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_opening,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.forSetup ? 'Protect sync' : 'Unlock sync'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.forSetup
                ? 'Keep this passphrase somewhere safe. You’ll need it to reopen the saved sync vault.'
                : 'Enter the passphrase used to protect your saved sync keys.',
            style: contentMetadataStyle,
          ),
          const SizedBox(height: 14),
          TextField(
            autofocus: true,
            controller: _passphrase,
            focusNode: _passphraseFocus,
            obscureText: !_showPassphrase,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            enabled: !_opening,
            textInputAction: widget.forSetup
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: (_) =>
                widget.forSetup ? _repeatFocus.requestFocus() : _submit(),
            decoration: InputDecoration(
              labelText: 'Passphrase',
              suffixIcon: IconButton(
                onPressed: _opening
                    ? null
                    : () => setState(() {
                        _showPassphrase = !_showPassphrase;
                      }),
                tooltip: _showPassphrase
                    ? 'Hide passphrase'
                    : 'Show passphrase',
                icon: Icon(
                  _showPassphrase
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          if (widget.forSetup) ...[
            const SizedBox(height: 10),
            TextField(
              focusNode: _repeatFocus,
              controller: _repeat,
              obscureText: !_showPassphrase,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              enabled: !_opening,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Repeat passphrase'),
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: contentMetadataStyle.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _opening ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _opening ? null : _submit,
          child: Text(
            _opening
                ? 'Opening…'
                : widget.forSetup
                ? 'Continue'
                : 'Unlock',
          ),
        ),
      ],
    ),
  );
}
