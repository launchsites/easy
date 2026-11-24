# Easy appearance

Easy ships with paper content and dark navigation. `easyTheme()` supplies that palette. `previewEasyTheme()` supplies mixed, light, and full-dark palettes for Settings, Focus Modes, orbit navigation, Calendar, and both Today layouts. [Theme](../lib/ui_theme.dart) · [Palettes](../lib/appearance/appearance.dart)

Use Material `ColorScheme` for content and `WorkspaceChrome.of(context)` for the desktop shell. These roles keep focus, selection, and text color consistent across palettes.

| Surface | Integration |
| --- | --- |
| Desktop header, rail, and search control | Use chrome `background`, `surface`, `foreground`, `mutedForeground`, `outline`, `selection`, and `onSelection`. Give keyboard focus its own visible outline. |
| Tasks, Notes, and their editors | Follow the Today views and use `surface` for the page, `surfaceContainerLow` for raised panels, `onSurface` and `onSurfaceVariant` for text, `outlineVariant` for dividers, and `outline` for controls. |
| Workouts, Plans, capture, and feature settings | Use the same content roles for navigation, fields, scroll boundaries, summary values, and sheets. Pair status colors with signs and labels so each state stays distinct. |
| Focus modes and user colors | Treat the selected mode color as an accent. Resolve any text or focus ring against the current surface and preserve the stored color value. |

Enable an application-wide appearance picker after each destination, dialog, menu, and sheet uses the semantic palette. Verify calendar grid lines, text and control contrast, keyboard traversal, two-times text size, reduced motion, and RTL at narrow phone, tablet, and desktop sizes. The current compact route check exercises the shipped app. RTL uses a forced-direction Settings preview so labels can be checked independently of localization. [Accessibility checks](../test/appearance_accessibility_test.dart) · [Gesture checks](../test/orbit_navigation_test.dart) · [Calendar and Today checks](../test/appearance_routes_test.dart)
