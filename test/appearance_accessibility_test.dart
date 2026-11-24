import 'dart:math' as math;

import 'package:easy/appearance/appearance.dart';
import 'package:easy/calendar_page.dart';
import 'package:easy/focus/focus_modes_page.dart';
import 'package:easy/main.dart';
import 'package:easy/mobile_home.dart';
import 'package:easy/orbit_navigation.dart';
import 'package:easy/settings_page.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
  });

  test('the default keeps the paper workspace with dark navigation', () {
    final theme = easyTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, const Color(0xfffaf9f5));
    expect(
      theme.extension<WorkspaceChrome>()!.background,
      const Color(0xff171c18),
    );
  });

  for (final profile in AppearanceProfile.values) {
    test('${profile.name} palette meets content and chrome contrast', () {
      final theme = previewEasyTheme(profile);
      final content = theme.colorScheme;
      final chrome = theme.extension<WorkspaceChrome>()!;
      final textPairs = <String, (Color, Color)>{
        'body': (content.onSurface, content.surface),
        'supporting text': (content.onSurfaceVariant, content.surface),
        'supporting text on raised surface': (
          content.onSurfaceVariant,
          content.surfaceContainerLow,
        ),
        'button': (content.onPrimary, content.primary),
        'selected item': (content.onPrimaryContainer, content.primaryContainer),
        'floating control': (content.onInverseSurface, content.inverseSurface),
        'chrome': (chrome.foreground, chrome.background),
        'muted chrome': (chrome.mutedForeground, chrome.background),
        'chosen chrome item': (chrome.onSelection, chrome.selection),
        'chrome accent': (chrome.accentForeground, chrome.surface),
      };
      for (final MapEntry(key: label, value: (foreground, background))
          in textPairs.entries) {
        expect(
          _contrast(foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: label,
        );
      }
      expect(
        _contrast(content.primary, content.surface),
        greaterThanOrEqualTo(3),
      );
      expect(
        _contrast(content.outline, content.surfaceContainerLow),
        greaterThanOrEqualTo(3),
      );
    });
  }

  testWidgets(
    '320px at 200% keeps navigation, settings, and mode editor usable',
    (tester) async {
      _viewport(tester, const Size(320, 568));
      final dispatcher = tester.platformDispatcher;
      dispatcher.textScaleFactorTestValue = 2;
      dispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(dispatcher.clearTextScaleFactorTestValue);
      addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
      await _openWorkspace(tester);
      final home = find.byType(MobileHome);
      expect(home, findsOneWidget);
      expect(MediaQuery.textScalerOf(tester.element(home)).scale(14), 28);
      expect(MediaQuery.reduceMotionOf(tester.element(home)), isTrue);

      final navigate = find.byTooltip('Navigate');
      await tester.tap(navigate);
      await tester.pump();
      final orbit = find.byType(OrbitNavigation);
      final calendar = find.descendant(
        of: orbit,
        matching: find.text('Calendar'),
      );
      final calendarRow = find.ancestor(
        of: calendar,
        matching: find.byType(ListTile),
      );
      expect(calendarRow, findsOneWidget);
      expect(tester.getSize(calendarRow).height, greaterThanOrEqualTo(48));
      expect(tester.widget<Text>(calendar).maxLines, isNull);
      expect(tester.getRect(calendarRow).right, lessThanOrEqualTo(300));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(calendar, findsNothing);

      final mode = find.widgetWithText(TextButton, 'Mode').hitTestable();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Settings'));
      await tester.pumpAndSettle();
      final settings = find.byType(SettingsPage);
      expect(settings, findsOneWidget);
      final focusModes = find.descendant(
        of: settings,
        matching: find.text('Focus modes'),
      );
      await tester.ensureVisible(focusModes);
      await tester.tap(focusModes);
      await tester.pumpAndSettle();
      expect(find.byType(FocusModesPage), findsOneWidget);
      await tester.tap(find.text('New mode'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('Save mode').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('820px tablet uses the rail and keyboard Search shortcut', (
    tester,
  ) async {
    _viewport(tester, const Size(820, 1180));
    await _openWorkspace(tester);
    expect(find.byType(OrbitNavigation), findsNothing);
    final calendarButton = find.byTooltip('Calendar');
    expect(calendarButton.hitTestable(), findsOneWidget);
    await tester.tap(calendarButton);
    await tester.pumpAndSettle();
    expect(find.byType(CalendarPage), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final searchDialog = find.byType(Dialog);
    expect(
      find.descendant(
        of: searchDialog,
        matching: find.text('Search workspace'),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(CalendarPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark RTL Settings preview mirrors control order and accepts Tab',
    (tester) async {
      _viewport(tester, const Size(320, 568));
      bool opened = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: previewEasyTheme(AppearanceProfile.fullDark),
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
          ),
          home: SettingsPage(
            sections: [
              SettingsSection(
                title: 'إعدادات مساحة العمل',
                items: [
                  SettingsItem(
                    icon: Icons.event_outlined,
                    title: 'التقويمات',
                    subtitle: 'اختر التقويمات في كل عرض',
                    onTap: () => opened = true,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final label = find.text('التقويمات');
      final leading = find.byIcon(Icons.event_outlined);
      final trailing = find.byIcon(Icons.chevron_right_rounded);
      expect(
        tester.getRect(leading).left,
        greaterThan(tester.getRect(label).right),
      );
      expect(
        tester.getRect(trailing).right,
        lessThan(tester.getRect(label).left),
      );
      expect(tester.widget<Icon>(trailing).icon!.matchTextDirection, isTrue);
      expect(tester.widget<Text>(label).style?.color, const Color(0xffedf2e8));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openWorkspace(WidgetTester tester) async {
  await tester.pumpWidget(
    const EasyApp(openStore: openPreferenceWorkspaceStore),
  );
  await tester.pumpAndSettle();
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

double _contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}
