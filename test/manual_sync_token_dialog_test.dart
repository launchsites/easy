import 'package:easy/sync/src/manual_sync_ui.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final (viewport, scale, keyboard) in [
    (const Size(1440, 900), 1.0, 0.0),
    (const Size(320, 620), 2.0, 195.0),
  ]) {
    testWidgets('a long pasted code keeps the sync dialog width at $viewport', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final token = 'easy-pair1:${'n' * 3072}';
      final returned = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => returned.add(
                  await requestManualSyncToken(
                    context,
                    title: 'Enter invitation',
                    label: 'Invitation token',
                    paste: () async => token,
                  ),
                ),
                child: const Text('Open token prompt'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open token prompt'));
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      final originalWidth = tester.getSize(field).width;
      final paste = find.widgetWithText(TextButton, 'Paste from clipboard');
      await tester.ensureVisible(paste);
      await tester.tap(paste);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, token);
      expect(tester.getSize(field).width, originalWidth);
      expect(originalWidth, lessThanOrEqualTo(472));

      final confirm = find.widgetWithText(FilledButton, 'Continue');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(returned, [token]);
      expect(tester.takeException(), isNull);
    });
  }
}
