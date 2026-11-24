import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The default workspace and the two complete palettes available to previews.
enum AppearanceProfile { mixed, light, fullDark }

/// Keeps a category tint legible on its actual background.
Color readableTint(
  Color tint, {
  required Color surface,
  required Color foreground,
  double minimumContrast = 4.5,
}) {
  final backgroundLuminance = surface.computeLuminance();
  bool meetsContrast(Color color) {
    final luminance = Color.alphaBlend(color, surface).computeLuminance();
    final lighter = math.max(luminance, backgroundLuminance);
    final darker = math.min(luminance, backgroundLuminance);
    return (lighter + .05) / (darker + .05) >= minimumContrast;
  }

  if (meetsContrast(tint)) return tint;
  final stronger = Color.lerp(tint, foreground, .5)!;
  return meetsContrast(stronger) ? stronger : foreground;
}

const paper = Color(0xfffaf9f5);
const ink = Color(0xff242922);
const muted = Color(0xff686d63);
const line = Color(0xffe7e7df);
const accent = Color(0xff426651);
const shell = Color(0xff171c18);
const sidebarText = Color(0xffc2c9bd);
const raisedPaper = Color(0xfffffefa);
const softAccent = Color(0xffe7eee4);
const shellSurface = Color(0xff222923);

/// Navigation surfaces can have a different brightness than their content.
@immutable
class WorkspaceChrome extends ThemeExtension<WorkspaceChrome> {
  const WorkspaceChrome({
    required this.background,
    required this.surface,
    required this.foreground,
    required this.mutedForeground,
    required this.outline,
    required this.selection,
    required this.onSelection,
    required this.accentForeground,
  });

  final Color background;
  final Color surface;
  final Color foreground;
  final Color mutedForeground;
  final Color outline;
  final Color selection;
  final Color onSelection;
  final Color accentForeground;

  static WorkspaceChrome of(BuildContext context) =>
      Theme.of(context).extension<WorkspaceChrome>() ?? _mixedChrome;

  @override
  WorkspaceChrome copyWith({
    Color? background,
    Color? surface,
    Color? foreground,
    Color? mutedForeground,
    Color? outline,
    Color? selection,
    Color? onSelection,
    Color? accentForeground,
  }) => WorkspaceChrome(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    foreground: foreground ?? this.foreground,
    mutedForeground: mutedForeground ?? this.mutedForeground,
    outline: outline ?? this.outline,
    selection: selection ?? this.selection,
    onSelection: onSelection ?? this.onSelection,
    accentForeground: accentForeground ?? this.accentForeground,
  );

  @override
  WorkspaceChrome lerp(covariant WorkspaceChrome? other, double t) {
    if (other == null) return this;
    return WorkspaceChrome(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      onSelection: Color.lerp(onSelection, other.onSelection, t)!,
      accentForeground: Color.lerp(
        accentForeground,
        other.accentForeground,
        t,
      )!,
    );
  }
}

const _mixedChrome = WorkspaceChrome(
  background: shell,
  surface: shellSurface,
  foreground: Color(0xfff5f7f1),
  mutedForeground: sidebarText,
  outline: Color(0xff343d34),
  selection: Color(0xff2a342b),
  onSelection: Color(0xfff0f5ec),
  accentForeground: Color(0xffdcead9),
);

@immutable
class WorkspaceAppearance {
  const WorkspaceAppearance._({required this.content, required this.chrome});

  final ColorScheme content;
  final WorkspaceChrome chrome;

  static WorkspaceAppearance forProfile(AppearanceProfile profile) =>
      switch (profile) {
        AppearanceProfile.mixed => _mixed,
        AppearanceProfile.light => _light,
        AppearanceProfile.fullDark => _fullDark,
      };

  static final _mixed = WorkspaceAppearance._(
    content: ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: softAccent,
      onPrimaryContainer: const Color(0xff293e2f),
      surface: paper,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerLow: raisedPaper,
      surfaceContainer: const Color(0xfff1f1eb),
      outline: const Color(0xff808a7e),
      outlineVariant: line,
      inverseSurface: shell,
      onInverseSurface: paper,
    ),
    chrome: _mixedChrome,
  );

  static final _light = WorkspaceAppearance._(
    content: ColorScheme.fromSeed(
      seedColor: const Color(0xff3a604d),
      primary: const Color(0xff3a604d),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xffe2ebe0),
      onPrimaryContainer: const Color(0xff304338),
      surface: const Color(0xfffaf8f2),
      onSurface: const Color(0xff262a21),
      onSurfaceVariant: const Color(0xff585f53),
      surfaceContainerLow: const Color(0xfffffdfa),
      surfaceContainer: const Color(0xffefede4),
      outline: const Color(0xff737a70),
      outlineVariant: const Color(0xffe6e0d5),
      inverseSurface: const Color(0xff28352c),
      onInverseSurface: const Color(0xfffaf8f2),
    ),
    chrome: const WorkspaceChrome(
      background: Color(0xffece9df),
      surface: Color(0xffe3e0d6),
      foreground: Color(0xff263129),
      mutedForeground: Color(0xff4a544a),
      outline: Color(0xffb5b3a6),
      selection: Color(0xffdce5da),
      onSelection: Color(0xff304b3d),
      accentForeground: Color(0xff3a604d),
    ),
  );

  static final _fullDark = WorkspaceAppearance._(
    content: ColorScheme.fromSeed(
      brightness: Brightness.dark,
      seedColor: accent,
      primary: const Color(0xffb7dcc4),
      onPrimary: const Color(0xff183225),
      primaryContainer: const Color(0xff2c4336),
      onPrimaryContainer: const Color(0xffe3f1e5),
      surface: const Color(0xff1b211e),
      onSurface: const Color(0xffedf2e8),
      onSurfaceVariant: const Color(0xffaebbb0),
      surfaceContainerLow: const Color(0xff242e28),
      surfaceContainer: const Color(0xff313d35),
      outline: const Color(0xff849489),
      outlineVariant: const Color(0xff3c4840),
      inverseSurface: const Color(0xffdce9df),
      onInverseSurface: const Color(0xff18251e),
    ),
    chrome: const WorkspaceChrome(
      background: Color(0xff101612),
      surface: Color(0xff1b271f),
      foreground: Color(0xfff0f6ec),
      mutedForeground: Color(0xffb8c7ba),
      outline: Color(0xff53675a),
      selection: Color(0xff2f4638),
      onSelection: Color(0xffe6f4e7),
      accentForeground: Color(0xffcde9d6),
    ),
  );
}
