import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';

import '../storage/attachment_store.dart';
import '../ui_theme.dart';

class VoicePlaybackDialog extends StatefulWidget {
  const VoicePlaybackDialog({required this.audio, super.key});

  final StoredAttachment audio;

  @override
  State<VoicePlaybackDialog> createState() => _VoicePlaybackDialogState();
}

class _VoicePlaybackDialogState extends State<VoicePlaybackDialog>
    with WidgetsBindingObserver {
  late final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _states;
  var _playing = false;
  var _busy = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _states = _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    unawaited(_play());
  }

  Future<void> _play() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (_playing) {
        await _player.stop();
      } else {
        final audio = widget.audio;
        await _player.play(
          BytesSource(audio.bytes, mimeType: audio.ref.mimeType),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  Future<void> _stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // The dialog can close regardless of the audio backend state.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    unawaited(_disposePlayer());
    super.dispose();
  }

  Future<void> _disposePlayer() async {
    try {
      await _player.dispose();
    } catch (_) {
      // The native player may be unavailable on this device.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Voice capture'),
      content: Semantics(
        liveRegion: true,
        child: Text(
          _failed
              ? 'This recording could not be played on this device.'
              : _busy
              ? 'Opening recording…'
              : _playing
              ? 'Playing recording'
              : 'Ready to play',
          style: contentMetadataStyle,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _play,
          icon: Icon(_playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
          label: Text(_playing ? 'Stop' : 'Play'),
        ),
      ],
    );
  }
}
