import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart' show accent, ink, line, paper, shell;

class OrbitDestination {
  const OrbitDestination(this.label, this.icon);

  final String label;
  final IconData icon;
}

class OrbitNavigation extends StatefulWidget {
  const OrbitNavigation({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final List<OrbitDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<OrbitNavigation> createState() => _OrbitNavigationState();
}

class _OrbitNavigationState extends State<OrbitNavigation> {
  static const _holdDuration = Duration(milliseconds: 320);
  static const _revealDuration = Duration(milliseconds: 140);
  static const _edgeInset = 20.0;
  static const _launcherSize = 56.0;
  static const _deadZone = 32.0;
  static const _firstAngle = -88 * math.pi / 180;
  static const _lastAngle = -10 * math.pi / 180;
  static const _edgeTolerance = 18 * math.pi / 180;

  final _launcherKey = GlobalKey();
  final _launcherFocus = FocusNode(debugLabel: 'Navigation launcher');
  final _navigationFocus = FocusScopeNode(
    debugLabel: 'Mobile navigation',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );

  bool _isOpen = false;
  bool _isDragging = false;
  int? _highlightedIndex;

  @override
  void didUpdateWidget(covariant OrbitNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.destinations.isEmpty) {
      _isOpen = false;
      _isDragging = false;
      _highlightedIndex = null;
      _navigationFocus.traversalEdgeBehavior =
          TraversalEdgeBehavior.parentScope;
    }
  }

  @override
  void dispose() {
    _navigationFocus.dispose();
    _launcherFocus.dispose();
    super.dispose();
  }

  double _angleFor(int index) {
    final lastIndex = widget.destinations.length - 1;
    final progress = lastIndex == 0 ? 0.5 : index / lastIndex;
    return _firstAngle + (_lastAngle - _firstAngle) * progress;
  }

  int? _destinationAt(Offset globalPosition) {
    final launcher = _launcherKey.currentContext?.findRenderObject();
    if (launcher is! RenderBox || !launcher.hasSize) return null;

    final center = launcher.localToGlobal(launcher.size.center(Offset.zero));
    final delta = globalPosition - center;
    if (delta.distance < _deadZone) return null;

    final angle = math.atan2(delta.dy, delta.dx);
    if (angle < _firstAngle - _edgeTolerance ||
        angle > _lastAngle + _edgeTolerance) {
      return null;
    }

    final progress = (angle - _firstAngle) / (_lastAngle - _firstAngle);
    final lastIndex = widget.destinations.length - 1;
    return (progress * lastIndex).round().clamp(0, lastIndex).toInt();
  }

  void _open({bool dragging = false}) {
    setState(() {
      _isOpen = true;
      _isDragging = dragging;
      _highlightedIndex = null;
      _navigationFocus.traversalEdgeBehavior = TraversalEdgeBehavior.closedLoop;
    });
    _launcherFocus.requestFocus();
  }

  void _dismiss() {
    if (!_isOpen) return;

    setState(() {
      _isOpen = false;
      _isDragging = false;
      _highlightedIndex = null;
      _navigationFocus.traversalEdgeBehavior =
          TraversalEdgeBehavior.parentScope;
    });
    _launcherFocus.requestFocus();
  }

  void _toggle() {
    if (_isOpen) {
      _dismiss();
    } else {
      _open();
    }
  }

  void _select(int index) {
    _dismiss();
    widget.onSelected(index);
  }

  void _updateDrag(LongPressMoveUpdateDetails details) {
    if (!_isDragging) return;

    final index = _destinationAt(details.globalPosition);
    if (index == _highlightedIndex) return;

    setState(() => _highlightedIndex = index);
  }

  void _endDrag(LongPressEndDetails details) {
    if (!_isDragging) return;

    final index = _destinationAt(details.globalPosition);
    if (index == null) {
      _dismiss();
    } else {
      _select(index);
    }
  }

  Widget _buildLauncher(double bottom, Duration motion) {
    return Positioned(
      key: const ValueKey('orbit-launcher'),
      left: _edgeInset,
      bottom: bottom,
      child: Listener(
        onPointerCancel: (_) {
          if (_isDragging) _dismiss();
        },
        child: RawGestureDetector(
          excludeFromSemantics: true,
          gestures: {
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(() => LongPressGestureRecognizer(duration: _holdDuration), (
                  recognizer,
                ) {
                  recognizer.onLongPressStart = (_) => _open(dragging: true);
                  recognizer.onLongPressMoveUpdate = _updateDrag;
                  recognizer.onLongPressEnd = _endDrag;
                }),
          },
          child: SizedBox.square(
            key: _launcherKey,
            dimension: _launcherSize,
            child: Semantics(
              expanded: _isOpen,
              child: IconButton.filled(
                tooltip: 'Navigate',
                focusNode: _launcherFocus,
                onPressed: _toggle,
                style: IconButton.styleFrom(
                  backgroundColor: shell,
                  foregroundColor: paper,
                  overlayColor: Colors.white,
                  elevation: 2,
                  shadowColor: shell.withValues(alpha: 0.24),
                  animationDuration: motion,
                  shape: const CircleBorder(),
                ),
                icon: Icon(
                  _isOpen ? Icons.close_rounded : Icons.grid_view_rounded,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDestination(
    int index,
    double bottom,
    double radius,
    double size,
    Duration motion,
  ) {
    final destination = widget.destinations[index];
    final angle = _angleFor(index);
    final isCurrent = widget.selectedIndex == index;
    final isHighlighted = _highlightedIndex == index;
    final background = isHighlighted
        ? accent
        : isCurrent
        ? Color.lerp(paper, accent, 0.10)!
        : paper;
    final foreground = isHighlighted
        ? Colors.white
        : (isCurrent ? accent : ink);
    final border = isHighlighted
        ? accent
        : (isCurrent ? accent.withValues(alpha: 0.42) : line);
    final centerOffset = (_launcherSize - size) / 2;
    final button = Semantics(
      selected: isCurrent,
      child: TextButton(
        onPressed: () => _select(index),
        style: TextButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const CircleBorder(),
          side: BorderSide(color: border),
          elevation: isHighlighted ? 3 : 1,
          shadowColor: shell.withValues(alpha: 0.24),
          animationDuration: motion,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(destination.icon, size: 20, color: foreground),
            const SizedBox(height: 3),
            Flexible(
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.16,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Positioned(
      key: ValueKey(index),
      left: _edgeInset + centerOffset + radius * math.cos(angle),
      bottom: bottom + centerOffset - radius * math.sin(angle),
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: _isDragging ? Duration.zero : motion,
          curve: Curves.easeOutCubic,
          child: button,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.destinations.isEmpty) return const SizedBox.expand();

    final bottom = MediaQuery.paddingOf(context).bottom + _edgeInset;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _revealDuration;
    return PopScope<Object?>(
      canPop: !_isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _dismiss();
      },
      child: FocusScope(
        node: _navigationFocus,
        child: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: CallbackShortcuts(
            bindings: {
              if (_isOpen)
                const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 360;
                final compact =
                    constraints.maxWidth < 320 ||
                    constraints.maxHeight - bottom < 190;
                final size = compact ? 48.0 : (narrow ? 56.0 : 60.0);
                final idealRadius = compact ? 118.0 : (narrow ? 134.0 : 146.0);
                final openHeight =
                    constraints.maxHeight - bottom - (_launcherSize + size) / 2;
                final radius = math.max(0.0, math.min(idealRadius, openHeight));
                final center = Offset(
                  _edgeInset + _launcherSize / 2,
                  constraints.maxHeight - bottom - _launcherSize / 2,
                );
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isOpen)
                      ModalBarrier(
                        color: shell.withValues(alpha: 0.12),
                        semanticsLabel: 'Close navigation',
                        onDismiss: _dismiss,
                      ),
                    if (_isOpen)
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _OrbitTrack(
                            center: center,
                            radius: radius,
                            startAngle: _angleFor(0),
                            endAngle: _angleFor(widget.destinations.length - 1),
                            highlightedAngle: _highlightedIndex == null
                                ? null
                                : _angleFor(_highlightedIndex!),
                          ),
                        ),
                      ),
                    _buildLauncher(bottom, motion),
                    if (_isOpen)
                      for (
                        var index = 0;
                        index < widget.destinations.length;
                        index++
                      )
                        _buildDestination(index, bottom, radius, size, motion),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbitTrack extends CustomPainter {
  const _OrbitTrack({
    required this.center,
    required this.radius,
    required this.startAngle,
    required this.endAngle,
    required this.highlightedAngle,
  });

  final Offset center;
  final double radius;
  final double startAngle;
  final double endAngle;
  final double? highlightedAngle;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()
      ..color = paper.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      endAngle - startAngle,
      false,
      track,
    );

    final selected = highlightedAngle;
    if (selected != null) {
      canvas.drawLine(
        center,
        center + Offset(math.cos(selected), math.sin(selected)) * radius,
        Paint()
          ..color = accent.withValues(alpha: 0.56)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OrbitTrack oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.radius != radius ||
      oldDelegate.startAngle != startAngle ||
      oldDelegate.endAngle != endAngle ||
      oldDelegate.highlightedAngle != highlightedAngle;
}
