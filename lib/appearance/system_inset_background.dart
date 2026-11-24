import 'package:material_ui/material_ui.dart';

/// Paints behind the operating system's controls within its existing insets.
class SystemInsetBackground extends StatelessWidget {
  const SystemInsetBackground({
    required this.color,
    required this.child,
    super.key,
  });

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewPaddingOf(context);
    if (insets == EdgeInsets.zero) return child;
    final background = ColoredBox(color: color);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        IgnorePointer(
          child: Stack(
            children: [
              if (insets.top > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: insets.top,
                  child: background,
                ),
              if (insets.bottom > 0)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: insets.bottom,
                  child: background,
                ),
              if (insets.left > 0)
                Positioned(
                  left: 0,
                  top: insets.top,
                  bottom: insets.bottom,
                  width: insets.left,
                  child: background,
                ),
              if (insets.right > 0)
                Positioned(
                  right: 0,
                  top: insets.top,
                  bottom: insets.bottom,
                  width: insets.right,
                  child: background,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
