import 'dart:io';

import 'package:easy/sync/sync_credentials.dart';
import 'package:easy/sync/sync_password_vault.dart';
import 'package:easy/sync/sync_password_vault_prompt.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _passphrase = 'Synthètic device unlock phrase';

void main() {
  late Directory temporary;
  late String path;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('easy-sync-prompt-');
    path = temporary.uri.resolve('credentials.easyvault').toFilePath();
  });

  tearDown(() => temporary.delete(recursive: true));

  Future<void> open(
    WidgetTester tester,
    List<SyncPasswordVault?> results, {
    required bool forSetup,
    Size viewport = const Size(320, 620),
    double textScale = 1.35,
    TextDirection direction = TextDirection.ltr,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: Directionality(textDirection: direction, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await showSyncPasswordVaultPrompt(
                  context,
                  forSetup: forSetup,
                  filePath: path,
                ),
              ),
              child: const Text('Open vault prompt'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open vault prompt'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'setup confirms a masked passphrase with a compact keyboard layout',
    (tester) async {
      final results = <SyncPasswordVault?>[];
      await open(tester, results, forSetup: true);
      expect(find.text('Protect sync'), findsOneWidget);
      final passphrase = find.widgetWithText(TextField, 'Passphrase');
      final repeat = find.widgetWithText(TextField, 'Repeat passphrase');
      expect(tester.widget<TextField>(passphrase).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show passphrase'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(passphrase).obscureText, isFalse);
      await tester.tap(find.byTooltip('Hide passphrase'));

      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await tester.ensureVisible(passphrase);
      await tester.enterText(passphrase, _passphrase);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.ensureVisible(repeat);
      await tester.enterText(repeat, 'Synthetic mismatch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Enter the same passphrase twice.'), findsOneWidget);
      expect(results, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(repeat);
      await tester.enterText(repeat, _passphrase);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _waitFor(tester, () => results.isNotEmpty);
      final owner = results.single!;
      expect(tester.takeException(), isNull);
      await tester.runAsync(owner.close);
      expect(File(path).existsSync(), isFalse);
    },
  );

  testWidgets('cancelling setup leaves the vault absent', (tester) async {
    final results = <SyncPasswordVault?>[];
    await open(tester, results, forSetup: true);
    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      _passphrase,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets('landscape setup stays operable at 200% text with the keyboard', (
    tester,
  ) async {
    final results = <SyncPasswordVault?>[];
    await open(
      tester,
      results,
      forSetup: true,
      viewport: const Size(568, 320),
      textScale: 2,
      direction: TextDirection.rtl,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 155);
    await tester.pumpAndSettle();
    final passphrase = find.widgetWithText(TextField, 'Passphrase');
    final repeat = find.widgetWithText(TextField, 'Repeat passphrase');
    await tester.ensureVisible(passphrase);
    await tester.enterText(passphrase, _passphrase);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.ensureVisible(repeat);
    await tester.enterText(repeat, _passphrase);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets(
    'unlock keeps a wrong passphrase on the review and returns the saved vault',
    (tester) async {
      await tester.runAsync(() async {
        final vault = await openSyncPasswordVault(
          passphrase: _passphrase,
          filePath: path,
        );
        final device = await SyncDeviceCredentials(vault).createIdentity();
        device.destroy();
        await vault.close();
      });
      final original = File(path).readAsBytesSync();
      final results = <SyncPasswordVault?>[];
      await open(tester, results, forSetup: false);
      expect(find.text('Unlock sync'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Repeat passphrase'), findsNothing);
      final field = find.widgetWithText(TextField, 'Passphrase');
      await tester.enterText(field, 'Synthetic wrong passphrase');
      await tester.tap(find.text('Unlock'));
      final error = find.text(
        'The passphrase could not unlock this credential file.',
      );
      await _waitFor(tester, () => error.evaluate().isNotEmpty);
      expect(results, isEmpty);
      expect(File(path).readAsBytesSync(), original);
      await tester.enterText(field, _passphrase);
      await tester.tap(find.text('Unlock'));
      await _waitFor(tester, () => results.isNotEmpty);
      await tester.runAsync(results.single!.close);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 110; attempt++) {
    await tester.pump(const Duration(milliseconds: 30));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  expect(ready(), isTrue);
}
