import 'package:easy/nutrition/nutrition.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final (size, direction) in [
    (const Size(320, 568), TextDirection.rtl),
    (const Size(390, 844), TextDirection.ltr),
    (const Size(568, 320), TextDirection.ltr),
    (const Size(1440, 900), TextDirection.ltr),
  ]) {
    testWidgets(
      'portion picking remains usable at $size, 200% and $direction',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        NutritionPortion? portion;
        await tester.pumpWidget(
          MaterialApp(
            theme: easyTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: Directionality(textDirection: direction, child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    portion = await showNutritionPortionEditor(
                      context,
                      foods: [],
                      initialSearch: 'roast chicken breast',
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await _tap(tester, 'Open');
        await _tap(tester, 'Skinless chicken breast, roasted');
        final field = find.widgetWithText(TextField, 'Amount eaten');
        await tester.ensureVisible(field);
        await tester.enterText(field, '82');
        await tester.pumpAndSettle();
        await _tap(tester, 'Save portion');
        expect(portion?.food.id, 'usda:sr-legacy:171477');
        expect(portion?.amount, 82);
        expect(portion?.estimated, false);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _tap(WidgetTester tester, String label) async {
  final item = find.text(label);
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      120,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
  }
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item.hitTestable());
  await tester.pumpAndSettle();
}
