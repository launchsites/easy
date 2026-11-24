import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'capture_archive.dart';
import 'voice_recording.dart';

enum HeldVoiceAction { holding, lock, cancelOnRelease, save, cancel }

class VoiceCaptureSheet extends StatefulWidget {
  const VoiceCaptureSheet({
    required this.onSave,
    this.heldAction,
    this.onClose,
    this.cancelRequests,
    this.openRecorder = PlatformVoiceRecorder.new,
    super.key,
  });

  final Future<CaptureArchiveEntry> Function(Uint8List, DateTime) onSave;
  final ValueNotifier<HeldVoiceAction>? heldAction;
  final ValueChanged<CaptureArchiveEntry?>? onClose;
  final ValueListenable<int>? cancelRequests;
  final VoiceRecorder Function() openRecorder;

  @override
  State<VoiceCaptureSheet> createState() => _VoiceCaptureSheetState();
}

enum _Phase { starting, recording, saving, failed }

class _VoiceCaptureSheetState extends State<VoiceCaptureSheet>
    with WidgetsBindingObserver {
  late final _recorder = widget.openRecorder();
  final _samples = VoiceSamples();
  final _recordedAt = DateTime.now();
  _Phase _phase = _Phase.starting;
  StreamSubscription<Uint8List>? _sampleSubscription;
  Timer? _elapsedUpdates;
  Timer? _recordingLimit;
  String? _problem;
  Duration _elapsed = Duration.zero;
  bool _locked = false;
  bool _cancelOnRelease = false;
  bool _finishRequested = false;
  bool _cancelRequested = false;
  bool _streamOpen = false;
  bool _closed = false;

  static const _teardownTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.heldAction?.addListener(_heldActionChanged);
    widget.cancelRequests?.addListener(_cancelRequestedExternally);
    if (widget.heldAction != null) _heldActionChanged();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      if (_cancelRequested || _finishRequested) {
        scheduleMicrotask(_close);
        return;
      }
      final allowed = await _recorder.requestPermission();
      if (!mounted || _closed) return;
      if (_cancelRequested || _finishRequested) {
        _close();
        return;
      }
      if (!allowed) {
        _fail('Allow microphone access to record a voice capture.');
        return;
      }
      final audio = await _recorder.start();
      if (!mounted || _closed) return;
      _streamOpen = true;
      setState(() => _phase = _Phase.recording);
      _sampleSubscription = audio.listen(
        (bytes) {
          _samples.add(bytes);
          if (_samples.isFull) unawaited(_finish());
        },
        onDone: () => unawaited(_finish()),
        onError: (Object _) => unawaited(_finish()),
      );
      _elapsedUpdates = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final elapsed = _samples.duration;
        if (elapsed.inSeconds != _elapsed.inSeconds && mounted) {
          setState(() => _elapsed = elapsed);
        }
      });
      _recordingLimit = Timer(
        VoiceSamples.maximumDuration,
        () => unawaited(_finish()),
      );
      if (_cancelRequested) {
        await _cancel();
      } else if (_finishRequested) {
        await _finish();
      }
    } catch (_) {
      _fail('The microphone could not be started.');
    }
  }

  void _heldActionChanged() {
    switch (widget.heldAction!.value) {
      case HeldVoiceAction.holding:
        if (_cancelOnRelease) setState(() => _cancelOnRelease = false);
      case HeldVoiceAction.lock:
        if (!_locked) {
          setState(() {
            _locked = true;
            _cancelOnRelease = false;
          });
        }
      case HeldVoiceAction.cancelOnRelease:
        if (!_locked && !_cancelOnRelease) {
          setState(() => _cancelOnRelease = true);
        }
      case HeldVoiceAction.save:
        if (!_locked) unawaited(_finish());
      case HeldVoiceAction.cancel:
        if (!_locked) unawaited(_cancel());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    if (_phase == _Phase.recording) {
      unawaited(_finish());
    } else if (_phase == _Phase.starting &&
        state != AppLifecycleState.inactive) {
      _cancelRequested = true;
    }
  }

  Future<void> _finish() async {
    if (_closed) return;
    if (_phase == _Phase.starting) {
      _finishRequested = true;
      return;
    }
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.saving);
    _stopTimers();
    try {
      await _recorder.stop().timeout(_teardownTimeout);
    } catch (_) {
      // Samples already received remain recoverable when the input closes.
    } finally {
      _streamOpen = false;
      unawaited(_releaseSamples(_sampleSubscription));
      _sampleSubscription = null;
    }
    if (!mounted) return;
    if (!_samples.hasRecording) {
      _fail('The microphone did not capture enough audio. Record again.');
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    setState(() {
      _phase = _Phase.saving;
      _problem = null;
    });
    try {
      final saved = await widget.onSave(_samples.toWav(), _recordedAt);
      _close(saved);
    } catch (_) {
      _fail('The recording is ready. Try saving it again.');
    }
  }

  Future<void> _cancel() async {
    if (_closed) return;
    if (_phase == _Phase.starting) {
      _cancelRequested = true;
      scheduleMicrotask(_close);
      return;
    }
    if (_phase == _Phase.saving) return;
    if (_streamOpen) {
      _streamOpen = false;
      setState(() => _phase = _Phase.saving);
      _stopTimers();
      try {
        await _recorder.cancel().timeout(_teardownTimeout);
      } catch (_) {
        // Recorder disposal still runs and discards its samples.
      }
    }
    _close();
  }

  void _cancelRequestedExternally() => unawaited(_cancel());

  void _close([CaptureArchiveEntry? draft]) {
    if (!mounted || _closed) return;
    _closed = true;
    final onClose = widget.onClose;
    if (onClose == null) {
      Navigator.pop(context, draft);
    } else {
      onClose(draft);
    }
  }

  void _fail(String message) {
    if (!mounted || _closed) return;
    setState(() {
      _phase = _Phase.failed;
      _problem = message;
    });
  }

  @override
  void dispose() {
    widget.heldAction?.removeListener(_heldActionChanged);
    widget.cancelRequests?.removeListener(_cancelRequestedExternally);
    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
    unawaited(_disposeRecorder());
    super.dispose();
  }

  void _stopTimers() {
    _elapsedUpdates?.cancel();
    _recordingLimit?.cancel();
  }

  Future<void> _releaseSamples(StreamSubscription<Uint8List>? samples) async {
    try {
      await samples?.cancel();
    } catch (_) {
      // A closed input stream cannot change the saved sample buffer.
    }
  }

  Future<void> _disposeRecorder() async {
    try {
      await _sampleSubscription?.cancel().timeout(_teardownTimeout);
      if (_streamOpen) await _recorder.cancel().timeout(_teardownTimeout);
    } catch (_) {
      // Disposal is still needed after a broken input stream.
    } finally {
      try {
        await _recorder.dispose().timeout(_teardownTimeout);
      } catch (_) {
        // Platform teardown cannot change the already saved draft.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    final failure = _problem;
    final elapsed = _elapsed.inSeconds;
    final clock =
        '${elapsed ~/ 60}:${(elapsed % 60).toString().padLeft(2, '0')}';
    final held = widget.heldAction != null && !_locked;
    final status = switch (phase) {
      _Phase.starting => 'Opening microphone…',
      _Phase.recording when _cancelOnRelease => 'Release to cancel',
      _Phase.recording when held => 'Release to save · slide up to lock',
      _Phase.recording => 'Recording',
      _Phase.saving => 'Saving recording…',
      _Phase.failed => failure!,
    };
    return PopScope(
      canPop: phase == _Phase.failed,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 23),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Voice capture', style: sectionHeadingStyle),
                    ),
                    if (phase == _Phase.recording)
                      Text(clock, style: contentMetadataStyle),
                  ],
                ),
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(status, style: contentMetadataStyle),
                ),
                const SizedBox(height: 19),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (phase != _Phase.saving)
                      TextButton(
                        onPressed: _cancel,
                        child: Text(
                          phase == _Phase.failed ? 'Close' : 'Cancel',
                        ),
                      ),
                    if (phase == _Phase.recording)
                      FilledButton.icon(
                        onPressed: _finish,
                        icon: const Icon(Icons.stop_rounded, size: 19),
                        label: const Text('Stop and save'),
                      ),
                    if (phase == _Phase.failed && _samples.hasRecording)
                      FilledButton(
                        onPressed: _save,
                        child: const Text('Retry save'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
