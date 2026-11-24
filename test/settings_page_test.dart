import 'package:easy/settings_page.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Settings opens an item and backs out of its route', (
    tester,
  ) async {
    _viewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (settingsContext) => SettingsPage(
                    sections: [
                      SettingsSection(
                        title: 'Workspace',
                        items: [
                          SettingsItem(
                            icon: Icons.calendar_month_outlined,
                            title: 'Calendars',
                            onTap: () => Navigator.of(settingsContext)
                                .push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => const Scaffold(
                                      body: Text('Calendars destination'),
                                    ),
                                  ),
                                ),
                          ),
                        ],
                      ),
                      SettingsSection(title: 'Empty section', items: []),
                    ],
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Empty section'), findsNothing);

    await tester.tap(find.text('Calendars'));
    await tester.pumpAndSettle();
    expect(find.text('Calendars destination'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('keyboard activation works for actions and switches', (
    tester,
  ) async {
    _viewport(tester, const Size(1100, 760));
    var opened = false;
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => SettingsPage(
            sections: [
              SettingsSection(
                title: 'Preferences',
                items: [
                  SettingsItem(
                    icon: Icons.palette_outlined,
                    title: 'Theme',
                    value: 'System',
                    onTap: () => opened = true,
                  ),
                  SettingsItem.toggle(
                    icon: Icons.cloud_outlined,
                    title: 'Calendar sync',
                    selected: enabled,
                    onChanged: (value) => setState(() => enabled = value),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('System')).dx,
      greaterThan(tester.getTopRight(find.text('Theme')).dx),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate(_hasFocusMarker), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('compact settings presents full labels at double text size', (
    tester,
  ) async {
    _viewport(tester, const Size(320, 568));
    var syncChanged = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2), disableAnimations: true),
          child: child!,
        ),
        home: SettingsPage(
          sections: [
            SettingsSection(
              title: 'Workspace preferences',
              items: [
                SettingsItem(
                  icon: Icons.save_outlined,
                  title: 'Backup and restore',
                  subtitle: 'Export a copy of your workspace.',
                  value: 'On this device',
                  onTap: () {},
                ),
                SettingsItem.toggle(
                  icon: Icons.calendar_month_outlined,
                  title: 'Independent calendar updates',
                  selected: false,
                  onChanged: (value) => syncChanged = value,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    final title = tester.getRect(find.text('Backup and restore'));
    final value = tester.getRect(find.text('On this device'));
    expect(value.top, greaterThanOrEqualTo(title.bottom));
    expect(value.right, lessThan(320));

    final switchLabel = find.text('Independent calendar updates');
    await tester.ensureVisible(switchLabel);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(switchLabel);
    expect(syncChanged, isTrue);
  });
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

bool _hasFocusMarker(Widget widget) =>
    widget is DecoratedBox &&
    widget.position == DecorationPosition.foreground &&
    widget.decoration is BoxDecoration &&
    (widget.decoration as BoxDecoration).border ==
        const BorderDirectional(start: BorderSide(color: accent, width: 2));
