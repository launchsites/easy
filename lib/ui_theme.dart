import 'package:material_ui/material_ui.dart';

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

const contentSurfaceRadius = BorderRadius.all(Radius.circular(16));
const contentControlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(11)),
);

ThemeData easyTheme() {
  final colors = ColorScheme.fromSeed(
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
  );
  final theme = ThemeData(
    colorScheme: colors,
    fontFamily: 'Geist',
    scaffoldBackgroundColor: paper,
    canvasColor: paper,
    dividerColor: line,
    hoverColor: const Color(0x0b426651),
    focusColor: const Color(0x16426651),
    splashColor: const Color(0x17426651),
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
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: const BorderSide(color: Color(0xff91988e), width: 1.4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: paper,
      modalBackgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(raisedPaper),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: line),
          ),
        ),
      ),
    ),
  );
  final text = theme.textTheme.apply(bodyColor: ink, displayColor: ink);
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
