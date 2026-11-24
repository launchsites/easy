import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'voice_capture_sheet.dart';

/// A single thumb control with independent tap, held recording, and lock.
class HoldCaptureButton extends StatefulWidget {
  const HoldCaptureButton({
    required this.onTap,
    this.onHeldRecord,
    this.label = 'Add item',
    this.icon = Icons.add_rounded,
    this.heroTag = 'capture',
    super.key,
  });

  final VoidCallback onTap;
  final Future<void> Function(ValueNotifier<HeldVoiceAction>)? onHeldRecord;
  final String label;
  final IconData icon;
  final Object? heroTag;

  @override
  State<HoldCaptureButton> createState() => _HoldCaptureButtonState();
}

class _HoldCaptureButtonState extends State<HoldCaptureButton> {
  ValueNotifier<HeldVoiceAction>? _gesture;

  void _start(LongPressStartDetails details) {
    final callback = widget.onHeldRecord;
    if (callback == null || _gesture != null) return;
    final action = ValueNotifier(HeldVoiceAction.holding);
    _gesture = action;
    unawaited(_open(callback, action));
  }

  Future<void> _open(
    Future<void> Function(ValueNotifier<HeldVoiceAction>) callback,
    ValueNotifier<HeldVoiceAction> action,
  ) async {
    try {
      await callback(action);
    } finally {
      if (_gesture == action) _gesture = null;
      action.dispose();
    }
  }

  void _move(LongPressMoveUpdateDetails details) {
    final action = _gesture;
    if (action == null || action.value == HeldVoiceAction.lock) return;
    final delta = details.offsetFromOrigin;
    if (delta.dy < -58 && -delta.dy > delta.dx.abs()) {
      action.value = HeldVoiceAction.lock;
    } else if (delta.dx < -57 && -delta.dx > delta.dy.abs()) {
      action.value = HeldVoiceAction.cancelOnRelease;
    } else {
      action.value = HeldVoiceAction.holding;
    }
  }

  void _end(LongPressEndDetails details) {
    final action = _gesture;
    if (action == null || action.value == HeldVoiceAction.lock) return;
    action.value = action.value == HeldVoiceAction.cancelOnRelease
        ? HeldVoiceAction.cancel
        : HeldVoiceAction.save;
  }

  void _cancel() {
    final action = _gesture;
    if (action != null &&
        (action.value == HeldVoiceAction.holding ||
            action.value == HeldVoiceAction.cancelOnRelease)) {
      action.value = HeldVoiceAction.cancel;
    }
  }

  @override
  void dispose() {
    // Responsive layouts can remove the control while its pointer is held.
    if (_gesture != null) scheduleMicrotask(_cancel);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowVoice = widget.onHeldRecord != null;
    return GestureDetector(
      excludeFromSemantics: true,
      onLongPressStart: allowVoice ? _start : null,
      onLongPressMoveUpdate: allowVoice ? _move : null,
      onLongPressEnd: allowVoice ? _end : null,
      onLongPressCancel: allowVoice ? _cancel : null,
      child: Tooltip(
        message: widget.label,
        triggerMode: TooltipTriggerMode.manual,
        child: FloatingActionButton(
          heroTag: widget.heroTag,
          onPressed: widget.onTap,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          elevation: 3,
          highlightElevation: 1,
          hoverElevation: 5,
          child: Icon(widget.icon, size: 26),
        ),
      ),
    );
  }
}
