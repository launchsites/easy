import 'package:easy/nutrition/nutrition.dart';
import 'package:easy/storage/attachment_store.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

NutritionFood _fruit({bool estimated = false}) => NutritionFood(
  id: 'fruit',
  name: 'Example fruit',
  referenceAmount: 100,
  referenceUnit: NutritionUnit.grams,
  values: const NutritionValues(energyKcal: 50, carbsGrams: 12, fatGrams: 0),
  source: 'Example label',
  estimated: estimated,
);

final _day = DateTime(2030, 4, 16, 12);

void main() {
  test(
    'converts compatible units and keeps missing values and ranges distinct',
    () {
      final portion = NutritionPortion(
        food: _fruit(),
        amount: .25,
        unit: NutritionUnit.kilograms,
        estimated: true,
        minimumAmount: .2,
        maximumAmount: .3,
      );
      final unknown = NutritionPortion(
        food: NutritionFood(
          id: 'other',
          name: 'Label unavailable',
          referenceAmount: 1,
          referenceUnit: NutritionUnit.servings,
        ),
        amount: 1,
        unit: NutritionUnit.servings,
      );
      final totals = nutritionTotals([portion, unknown]);
      expect(totals[Nutrient.energy]!.amount, 125);
      expect(totals[Nutrient.energy]!.minimum, 100);
      expect(totals[Nutrient.energy]!.maximum, 150);
      expect(totals[Nutrient.energy]!.partial, isTrue);
      expect(totals[Nutrient.energy]!.estimated, isTrue);
      expect(totals[Nutrient.protein]!.amount, isNull);
      expect(totals[Nutrient.fat]!.amount, 0);
      expect(formatNutritionNumber(100, decimals: 0), '100');

      final coarse = NutritionPortion(
        food: _fruit(estimated: true),
        amount: 100,
        unit: NutritionUnit.grams,
      );
      final withCoarse = nutritionTotals([coarse, portion])[Nutrient.energy]!;
      expect(withCoarse.estimated, isTrue);
      expect(withCoarse.minimum, isNull);
    },
  );

  test('rejects mismatched units, invalid ranges and implausible values', () {
    final fruit = _fruit();
    expect(
      () =>
          NutritionPortion(food: fruit, amount: 1, unit: NutritionUnit.litres),
      throwsFormatException,
    );
    expect(
      () => NutritionPortion(food: fruit, amount: 0, unit: NutritionUnit.grams),
      throwsFormatException,
    );
    expect(
      () => NutritionPortion(
        food: fruit,
        amount: 100,
        unit: NutritionUnit.grams,
        minimumAmount: 90,
      ),
      throwsFormatException,
    );
    expect(
      () => NutritionPortion(
        food: fruit,
        amount: 100,
        unit: NutritionUnit.grams,
        minimumAmount: 110,
        maximumAmount: 120,
      ),
      throwsFormatException,
    );
    expect(
      () => NutritionPortion(
        food: fruit,
        amount: 1000,
        unit: NutritionUnit.kilograms,
      ),
      throwsFormatException,
    );
    expect(
      () => NutritionFood(
        id: 'bad',
        name: 'Example food',
        referenceAmount: 100,
        referenceUnit: NutritionUnit.grams,
        values: const NutritionValues(energyKcal: 1000000),
      ),
      throwsFormatException,
    );
    expect(
      () => NutritionFood(
        id: 'bad',
        name: 'Example food',
        referenceAmount: 100,
        referenceUnit: NutritionUnit.grams,
        values: const NutritionValues(proteinGrams: 70, carbsGrams: 60),
      ),
      throwsFormatException,
    );
  });

  test('versioned data retains source, estimates, photo references and prior food values', () {
    final food = _fruit();
    final photo = AttachmentRef(
      id: List.filled(64, '0').join(),
      format: AttachmentFormat.png,
      byteLength: 128,
    );
    final previous = NutritionPortion(
      food: food,
      amount: 100,
      unit: NutritionUnit.grams,
      estimated: true,
    );
    final replacement = NutritionFood(
      id: food.id,
      name: food.name,
      referenceAmount: 100,
      referenceUnit: NutritionUnit.grams,
      values: const NutritionValues(energyKcal: 60),
    );
    final data = NutritionData(
      foods: [replacement],
      meals: [
        NutritionMeal(
          id: 'saved',
          name: 'Lunch',
          eatenAt: _day,
          portions: [previous],
          photo: photo,
        ),
        NutritionMeal(
          id: 'draft',
          name: 'Draft',
          eatenAt: _day,
          portions: [previous],
          draft: true,
        ),
        NutritionMeal(
          id: 'other',
          name: 'Another day',
          eatenAt: DateTime(2030, 4, 17, 12),
          portions: [previous],
        ),
      ],
    );
    final loaded = NutritionData.decode(data.encode());
    expect(loaded.meals.first.photo?.id, photo.id);
    expect(loaded.meals.first.portions.single.food.source, 'Example label');
    expect(loaded.meals.first.portions.single.estimated, isTrue);
    expect(loaded.totalsFor(_day)[Nutrient.energy]!.amount, 50);
    expect(loaded.foods.single.values.energyKcal, 60);
  });

  testWidgets('manual food and meal editing works at narrow mobile width', (
    tester,
  ) async {
    NutritionData? latest;
    await _mount(tester, onChanged: (data) => latest = data);
    await _tap(tester, 'Foods');
    await _tap(tester, 'New food');
    await _enter(tester, 'Food name', 'Yogurt');
    await _enter(tester, 'Energy (kcal)', '75');
    await _enter(tester, 'Protein (g)', '10');
    await _enter(tester, 'Source (optional)', 'Container label');
    await _tap(tester, 'Save food');
    expect(latest!.foods.single.values.energyKcal, 75);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _tap(tester, 'Add meal');
    await _enter(tester, 'Meal name', 'Lunch');
    await _tap(tester, 'Add food');
    await _enter(tester, 'Amount eaten', '125');
    await _tap(tester, 'Estimated portion');
    await _enter(tester, 'Minimum (g), optional', '100');
    await _enter(tester, 'Maximum (g), optional', '140');
    await _tap(tester, 'Save portion');
    await _tap(tester, 'Save meal');
    expect(find.text('Daily totals'), findsOneWidget);
    expect(find.text('75–105 kcal'), findsOneWidget);
    expect(find.text('Unknown'), findsWidgets);
    expect(latest!.meals.single.portions.single.food.source, 'Container label');
    expect(latest!.meals.single.portions.single.amount, 125);
    await tester.tap(find.byTooltip('Next day'));
    await tester.pumpAndSettle();
    expect(find.text('No meals logged.'), findsOneWidget);
    expect(find.text('Daily totals'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'attaching a photo publishes a draft before editing or confirmation',
    (tester) async {
      NutritionData? latest;
      final photo = AttachmentRef(
        id: List.filled(64, 'a').join(),
        format: AttachmentFormat.png,
        byteLength: 128,
      );
      AttachmentRef? viewed;
      await _mount(
        tester,
        onChanged: (data) => latest = data,
        attach: () async => photo,
        view: (photo) async => viewed = photo,
      );
      await _tap(tester, 'Attach photo');
      expect(latest!.meals.single.draft, isTrue);
      expect(latest!.meals.single.photo, same(photo));
      expect(find.text('Meal draft'), findsOneWidget);
      await _tap(tester, 'Meal photo attached');
      expect(viewed, same(photo));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Meal photo'), findsOneWidget);
      expect(find.text('Daily totals'), findsNothing);
    },
  );
}

Future<void> _mount(
  WidgetTester tester, {
  required ValueChanged<NutritionData> onChanged,
  Future<AttachmentRef?> Function()? attach,
  Future<void> Function(AttachmentRef)? view,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: NutritionPage(
        foods: const [],
        meals: const [],
        onChanged: onChanged,
        clock: () => _day,
        onAttachPhoto: attach,
        onViewPhoto: view,
      ),
    ),
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final item = find.widgetWithText(TextField, label);
  await tester.ensureVisible(item);
  await tester.enterText(item, value);
  await tester.pumpAndSettle();
}
