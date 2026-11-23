import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

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
  static const _edgeInset = 20.0;
  static const _launcherSize = 56.0;
  static const _destinationSize = 56.0;
  static const _deadZone = 32.0;
  static const _firstAngle = -88 * math.pi / 180;
  static const _lastAngle = -10 * math.pi / 180;
  static const _edgeTolerance = 18 * math.pi / 180;

  static const _ink = Color(0xFF1B201E);
  static const _accent = Color(0xFF466955);
  static const _paper = Color(0xFFFAF9F6);
  static const _selectedPaper = Color(0xFFE5EDE5);
  static const _border = Color(0xFFDADFD9);

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

  Widget _buildLauncher(double bottom) {
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
                  backgroundColor: _ink,
                  foregroundColor: _paper,
                ),
                icon: Icon(
                  _isOpen ? Icons.close_rounded : Icons.explore_outlined,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDestination(int index, double bottom, double radius) {
    final destination = widget.destinations[index];
    final angle = _angleFor(index);
    final isCurrent = widget.selectedIndex == index;
    final isHighlighted = _highlightedIndex == index;
    final background = isHighlighted
        ? _accent
        : isCurrent
        ? _selectedPaper
        : _paper;
    final foreground = isHighlighted ? _paper : _ink;
    final border = isHighlighted || isCurrent ? _accent : _border;
    final centerOffset = (_launcherSize - _destinationSize) / 2;

    return Positioned(
      key: ValueKey(destination.label),
      left: _edgeInset + centerOffset + radius * math.cos(angle),
      bottom: bottom + centerOffset - radius * math.sin(angle),
      child: SizedBox.square(
        dimension: _destinationSize,
        child: Semantics(
          selected: isCurrent,
          child: TextButton(
            onPressed: () => _select(index),
            style: TextButton.styleFrom(
              backgroundColor: background,
              foregroundColor: foreground,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: CircleBorder(side: BorderSide(color: border)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(destination.icon, size: 19, color: foreground),
                const SizedBox(height: 2),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.destinations.isEmpty) return const SizedBox.expand();

    final bottom = MediaQuery.paddingOf(context).bottom + _edgeInset;
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
                final radius = constraints.maxWidth < 360 ? 128.0 : 144.0;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isOpen)
                      ModalBarrier(
                        color: const Color(0x151B201E),
                        semanticsLabel: 'Close navigation',
                        onDismiss: _dismiss,
                      ),
                    _buildLauncher(bottom),
                    if (_isOpen)
                      for (
                        var index = 0;
                        index < widget.destinations.length;
                        index++
                      )
                        _buildDestination(index, bottom, radius),
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
