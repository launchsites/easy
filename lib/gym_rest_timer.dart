import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';

const workoutRestDurations = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(seconds: 90),
  Duration(minutes: 2),
  Duration(minutes: 3),
  Duration(minutes: 5),
];

class GymRestTimer extends StatefulWidget {
  const GymRestTimer({
    required this.endsAt,
    required this.onStart,
    required this.onClear,
    this.clock,
    super.key,
  });

  final DateTime? endsAt;
  final ValueChanged<Duration> onStart;
  final VoidCallback onClear;
  final DateTime Function()? clock;

  @override
  State<GymRestTimer> createState() => _GymRestTimerState();
}

class _GymRestTimerState extends State<GymRestTimer>
    with WidgetsBindingObserver {
  Timer? _ticker;
  late int? _remaining = _readSeconds();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshTicker();
  }

  @override
  void didUpdateWidget(GymRestTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endsAt != widget.endsAt || oldWidget.clock != widget.clock) {
      _refreshTicker();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  int? _readSeconds() {
    final end = widget.endsAt;
    if (end == null) return null;
    final milliseconds = end
        .difference((widget.clock ?? DateTime.now)())
        .inMilliseconds;
    return milliseconds <= 0 ? 0 : (milliseconds + 999) ~/ 1000;
  }

  void _refreshTicker() {
    _ticker?.cancel();
    _tick();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if ((_remaining ?? 0) > 0 &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void _tick() {
    final seconds = _readSeconds();
    if (seconds != _remaining) setState(() => _remaining = seconds);
    if ((seconds ?? 0) <= 0) _ticker?.cancel();
  }

  Future<void> _choose() async {
    final duration = await showDialog<Duration>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Rest timer'),
        children: [
          for (final duration in workoutRestDurations)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, duration),
              child: Text(
                duration.inSeconds % 60 == 0
                    ? '${duration.inMinutes} min'
                    : '${duration.inSeconds} sec',
              ),
            ),
          if (_remaining != null) ...[
            const Divider(),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, Duration.zero),
              child: Text(_remaining == 0 ? 'Clear timer' : 'Stop timer'),
            ),
          ],
        ],
      ),
    );
    if (!mounted || duration == null) return;
    if (duration == Duration.zero) {
      widget.onClear();
    } else {
      widget.onStart(duration);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _remaining;
    final colors = Theme.of(context).colorScheme;
    if (seconds == null) {
      return IconButton.outlined(
        tooltip: 'Rest timer',
        onPressed: _choose,
        icon: const Icon(Icons.timer_outlined, size: 20),
        style: IconButton.styleFrom(minimumSize: const Size.square(48)),
      );
    }
    return Tooltip(
      message: 'Rest timer',
      child: FilledButton.tonal(
        onPressed: _choose,
        style: FilledButton.styleFrom(
          minimumSize: const Size(56, 48),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          shape: contentControlShape,
        ),
        child: Semantics(
          value: seconds == 0 ? 'Rest complete' : '$seconds seconds remaining',
          liveRegion: seconds == 0,
          excludeSemantics: true,
          child: seconds == 0
              ? const Icon(Icons.check_rounded, size: 20)
              : Text(
                  '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                  style: contentMetadataStyle.copyWith(
                    color: colors.onSecondaryContainer,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}
