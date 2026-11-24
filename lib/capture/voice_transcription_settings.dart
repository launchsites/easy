import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'local_transcriber.dart';

class VoiceTranscriptionSettings extends StatefulWidget {
  const VoiceTranscriptionSettings({
    required this.initialConfig,
    required this.onSave,
    super.key,
  });

  final VoiceTranscriptionConfig? initialConfig;
  final Future<void> Function(VoiceTranscriptionConfig?) onSave;

  @override
  State<VoiceTranscriptionSettings> createState() =>
      _VoiceTranscriptionSettingsState();
}

class _VoiceTranscriptionSettingsState
    extends State<VoiceTranscriptionSettings> {
  late String? _executable = widget.initialConfig?.executable;
  late String? _model = widget.initialConfig?.model;
  bool _busy = false;
  String? _error;

  Future<void> _choose({required bool executable}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await openFile(
        acceptedTypeGroups: executable
            ? const []
            : const [
                XTypeGroup(label: 'Whisper model', extensions: ['bin']),
              ],
      );
      if (!mounted || picked == null) return;
      setState(() {
        if (executable) {
          _executable = picked.path;
        } else {
          _model = picked.path;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The file picker could not be opened.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({required bool clear}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(
        clear
            ? null
            : VoiceTranscriptionConfig(
                executable: _executable!,
                model: _model!,
              ),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Transcription settings could not be saved.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice transcription')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Choose a trusted whisper.cpp executable and its model. Easy runs it locally when you choose to transcribe a recording.',
                ),
                const SizedBox(height: 18),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('whisper.cpp executable'),
                  subtitle: _executable == null
                      ? null
                      : Text(
                          _executable!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: const Icon(Icons.folder_open_outlined),
                  onTap: _busy ? null : () => _choose(executable: true),
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Whisper model file'),
                  subtitle: _model == null
                      ? null
                      : Text(
                          _model!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: const Icon(Icons.folder_open_outlined),
                  onTap: _busy ? null : () => _choose(executable: false),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    if (widget.initialConfig != null)
                      TextButton(
                        onPressed: _busy ? null : () => _save(clear: true),
                        child: const Text('Clear'),
                      ),
                    FilledButton(
                      onPressed: _busy || _executable == null || _model == null
                          ? null
                          : () => _save(clear: false),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      backgroundColor: paper,
    );
  }
}
