import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'capture_archive.dart';
import 'voice_capture_sheet.dart';
import 'voice_recording.dart';

/// Presents the recorder while the capture button still owns the pointer.
/// Pushing a Navigator route would cancel that active pointer.
class HeldVoiceCaptureOverlay extends PopEntry<Object?> {
  final _canPop = ValueNotifier(false);
  final _cancelRequests = ValueNotifier(0);
  OverlayEntry? _entry;
  ModalRoute<Object?>? _route;
  Completer<CaptureArchiveEntry?>? _result;

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  Future<CaptureArchiveEntry?> show(
    BuildContext context, {
    required ValueNotifier<HeldVoiceAction> action,
    required Future<CaptureArchiveEntry> Function(Uint8List, DateTime) onSave,
    VoiceRecorder Function() openRecorder = PlatformVoiceRecorder.new,
  }) {
    if (_result != null) return Future.value();
    final overlay = Overlay.of(context, rootOverlay: true);
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    final result = Completer<CaptureArchiveEntry?>();
    final entry = OverlayEntry(
      builder: (_) => themes.wrap(
        BlockSemantics(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ModalBarrier(dismissible: false, color: Colors.black54),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  bottom: false,
                  child: Semantics(
                    scopesRoute: true,
                    namesRoute: true,
                    explicitChildNodes: true,
                    label: 'Voice capture',
                    child: FocusScope(
                      debugLabel: 'Voice capture',
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.escape):
                              _requestCancel,
                        },
                        child: Focus(
                          autofocus: true,
                          skipTraversal: true,
                          child: Material(
                            color: paper,
                            clipBehavior: Clip.antiAlias,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                            child: VoiceCaptureSheet(
                              heldAction: action,
                              onSave: onSave,
                              onClose: _close,
                              cancelRequests: _cancelRequests,
                              openRecorder: openRecorder,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _result = result;
    _entry = entry;
    _route = ModalRoute.of(context)?..registerPopEntry(this);
    overlay.insert(entry);
    return result.future;
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    final pending = _result;
    // The route is iterating over its pop entries when it calls this method.
    scheduleMicrotask(() {
      if (pending == null || _result != pending) return;
      if (didPop) {
        _close(null);
      } else {
        _requestCancel();
      }
    });
  }

  void _requestCancel() {
    if (_result != null) _cancelRequests.value++;
  }

  void _close(CaptureArchiveEntry? draft) {
    final result = _result;
    if (result == null) return;
    _result = null;
    _route?.unregisterPopEntry(this);
    _route = null;
    _entry!
      ..remove()
      ..dispose();
    _entry = null;
    result.complete(draft);
  }

  void dispose() {
    _close(null);
    _cancelRequests.dispose();
    _canPop.dispose();
  }
}
