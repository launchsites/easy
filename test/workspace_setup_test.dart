import 'dart:async';

import 'package:easy/onboarding/workspace_setup.dart';
import 'package:easy/preferences/feature_preferences.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('preset selection waits for an explicit starting choice', (
    tester,
  ) async {
    final choices = <WorkspaceSetupChoice>[];
    await _mount(tester, onChosen: (choice) async => choices.add(choice));
    expect(choices, isEmpty);
    await _tap(tester, 'Full');
    expect(choices, isEmpty);
    await _tap(tester, 'Explore with samples');
    final selected = choices.single;
    expect(selected.preset, EasyPreset.complete);
    expect(selected.content, WorkspaceStartingContent.samples);
    expect(selected.preferences.allows(EasyFeature.ai), true);
    expect(selected.focusModes.where((mode) => mode.id == 'gym'), hasLength(1));
  });

  testWidgets('skip opens a blank core workspace', (tester) async {
    final choices = <WorkspaceSetupChoice>[];
    await _mount(
      tester,
      onChosen: (choice) async => choices.add(choice),
      preset: EasyPreset.complete,
    );
    await _tap(tester, 'Skip');
    expect(choices.single.preset, EasyPreset.minimal);
    expect(choices.single.content, WorkspaceStartingContent.empty);
    expect(choices.single.preferences.enabled, isEmpty);
  });

  testWidgets('double submission is locked and a failed save can retry', (
    tester,
  ) async {
    final gate = Completer<void>();
    final choices = <WorkspaceSetupChoice>[];
    await _mount(
      tester,
      onChosen: (choice) async {
        choices.add(choice);
        if (choices.length == 1) await gate.future;
      },
    );
    await _tap(tester, 'Planner');
    final start = find.widgetWithText(FilledButton, 'Use my workspace');
    await tester.tap(start);
    await tester.pump();
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Explore with samples'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(choices, hasLength(1));
    gate.completeError(StateError('fixture failure'));
    await tester.pumpAndSettle();
    expect(find.text('Setup could not be saved. Try again.'), findsOneWidget);
    expect(find.textContaining('fixture failure'), findsNothing);
    await _tap(tester, 'Use my workspace');
    expect(choices.map((item) => item.preset), [
      EasyPreset.planner,
      EasyPreset.planner,
    ]);
    expect(choices.last.content, WorkspaceStartingContent.empty);
    expect(find.text('Setup could not be saved. Try again.'), findsNothing);
  });

  testWidgets('keyboard users can move through the preset radio group', (
    tester,
  ) async {
    await _mount(tester, onChosen: (_) async {});
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RadioGroup<EasyPreset>>(find.byType(RadioGroup<EasyPreset>))
          .groupValue,
      EasyPreset.planner,
    );
  });

  for (final (size, textScale, direction) in [
    (const Size(320, 568), 2.0, TextDirection.rtl),
    (const Size(390, 844), 1.0, TextDirection.ltr),
    (const Size(568, 320), 2.0, TextDirection.ltr),
    (const Size(800, 1080), 2.0, TextDirection.ltr),
    (const Size(1440, 900), 1.0, TextDirection.ltr),
  ]) {
    testWidgets(
      'presets and start fit $size at ${textScale * 100}% $direction',
      (tester) async {
        final choices = <WorkspaceSetupChoice>[];
        final appName = textScale == 2 ? 'Long Shared Workspace' : 'Easy';
        await _mount(
          tester,
          size: size,
          direction: direction,
          textScale: textScale,
          appName: appName,
          onChosen: (choice) async => choices.add(choice),
        );
        expect(find.text('Set up $appName'), findsOneWidget);
        await _tap(tester, 'Planner');
        await _tap(tester, 'Use my workspace');
        expect(choices.single.preset, EasyPreset.planner);
        expect(choices.single.content, WorkspaceStartingContent.empty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
  String appName = 'Easy',
  EasyPreset preset = EasyPreset.minimal,
  required Future<void> Function(WorkspaceSetupChoice) onChosen,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: WorkspaceSetupPage(
        appName: appName,
        initialPreset: preset,
        onChosen: onChosen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item.hitTestable());
  await tester.pumpAndSettle();
}
