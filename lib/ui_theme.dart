import 'package:material_ui/material_ui.dart';

import 'appearance/appearance.dart';

export 'appearance/appearance.dart'
    show
        accent,
        ink,
        line,
        muted,
        paper,
        raisedPaper,
        shell,
        shellSurface,
        sidebarText,
        softAccent;

const contentSurfaceRadius = BorderRadius.all(Radius.circular(16));
const contentControlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(11)),
);

ThemeData easyTheme() => _buildTheme(AppearanceProfile.mixed);

/// Preview surfaces that use semantic colors throughout.
ThemeData previewEasyTheme(AppearanceProfile profile) => _buildTheme(profile);

ThemeData _buildTheme(AppearanceProfile profile) {
  final appearance = WorkspaceAppearance.forProfile(profile);
  final colors = appearance.content;
  final theme = ThemeData(
    colorScheme: colors,
    extensions: [appearance.chrome],
    fontFamily: 'Geist',
    scaffoldBackgroundColor: colors.surface,
    canvasColor: colors.surface,
    dividerColor: colors.outlineVariant,
    hoverColor: colors.primary.withAlpha(0x0b),
    focusColor: colors.primary.withAlpha(0x16),
    splashColor: colors.primary.withAlpha(0x17),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: contentControlShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: contentControlShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: contentControlShape),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: colors.outline, width: 1.4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      modalBackgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerLow),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
      ),
    ),
  );
  final text = theme.textTheme.apply(
    bodyColor: colors.onSurface,
    displayColor: colors.onSurface,
  );
  return theme.copyWith(
    textTheme: text.copyWith(
      labelLarge: text.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
  );
}

TextStyle workspaceHeadingStyle(bool mobile) => TextStyle(
  color: ink,
  fontSize: mobile ? 44 : 54,
  fontWeight: FontWeight.w700,
  letterSpacing: mobile ? -2.5 : -3.3,
  height: 1.05,
);

const sectionHeadingStyle = TextStyle(
  color: ink,
  fontSize: 19,
  fontWeight: FontWeight.w700,
  letterSpacing: -.52,
  height: 1.2,
);

const contentTitleStyle = TextStyle(
  color: ink,
  fontSize: 15,
  fontWeight: FontWeight.w600,
  height: 1.33,
  letterSpacing: -.20,
);

const contentMetadataStyle = TextStyle(
  color: muted,
  fontSize: 13,
  height: 1.35,
);
