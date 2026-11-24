import 'package:easy/nutrition/nutrition.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('recipes scale the saved snapshots, ranges and ingredient units', () {
    final rice = _riceFood(130);
    final sauce = NutritionFood(
      id: 'sauce',
      name: 'Sauce',
      referenceAmount: 100,
      referenceUnit: NutritionUnit.millilitres,
      values: const NutritionValues(fatGrams: 5),
    );
    final batch = NutritionRecipe(
      id: 'lunch',
      name: 'Lunch recipe',
      servings: 4,
      finishedWeightGrams: 500,
      ingredients: [
        NutritionPortion(food: rice, amount: 400, unit: NutritionUnit.grams),
        NutritionPortion(
          food: sauce,
          amount: 100,
          unit: NutritionUnit.millilitres,
          estimated: true,
          minimumAmount: 80,
          maximumAmount: 120,
          estimateSource: 'Measured by spoon',
        ),
      ],
    );

    final serving = batch.portionsForServings(1);
    expect(serving.first.amount, 100);
    expect(serving.first.food, same(rice));
    expect(serving.first.estimated, true);
    expect(serving.last.unit, NutritionUnit.millilitres);
    expect(serving.last.amount, 25);
    expect(serving.last.minimumAmount, 20);
    expect(serving.last.maximumAmount, 30);
    expect(serving.last.estimateSource, 'Proportional share of saved recipe');
    final byWeight = batch.portionsForWeight(125);
    expect(byWeight.first.amount, serving.first.amount);
    expect(byWeight.last.maximumAmount, serving.last.maximumAmount);
    expect(batch.portionsForServings(4), same(batch.ingredients));
    expect(nutritionTotals(serving)[Nutrient.energy]?.amount, 130);
    expect(nutritionTotals(serving)[Nutrient.energy]?.partial, true);

    final updated = NutritionData(
      foods: [rice],
      recipes: [batch],
    ).copyWith(foods: [_riceFood(155)]);
    final decoded = NutritionData.decode(updated.encode());
    expect(decoded.foods.single.values.energyKcal, 155);
    expect(
      decoded.recipes.single.ingredients.first.food.values.energyKcal,
      130,
    );
    expect(
      decoded.recipes.single.ingredients.last.estimateSource,
      'Measured by spoon',
    );
    expect(decoded.recipes.single.finishedWeightGrams, 500);
    expect(decoded.meals, isEmpty);
    expect(() => decoded.recipes.clear(), throwsUnsupportedError);
    expect(() => batch.ingredients.clear(), throwsUnsupportedError);
    expect(() => batch.portionsForServings(double.nan), throwsFormatException);
    expect(() => batch.portionsForWeight(-10), throwsFormatException);
  });

  test('batch weight is optional and versions without recipes load', () {
    final decoded = NutritionData.decode('{"version":1,"foods":[],"meals":[]}');
    expect(decoded.recipes, isEmpty);
    final recipe = NutritionRecipe(
      id: 'r',
      name: 'Rice batch',
      servings: 2,
      ingredients: [
        NutritionPortion(
          food: _riceFood(130),
          amount: .4,
          unit: NutritionUnit.kilograms,
        ),
      ],
    );
    expect(recipe.portionsForServings(1).single.amount, .2);
    expect(() => recipe.portionsForWeight(200), throwsFormatException);
  });

  testWidgets(
    'save a meal as a recipe and review a weighed share before logging',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final day = DateTime(2030, 4, 16, 12);
      final food = _riceFood(130);
      final existing = NutritionMeal(
        id: 'original-meal',
        name: 'Lunch batch',
        eatenAt: day,
        portions: [
          NutritionPortion(food: food, amount: 200, unit: NutritionUnit.grams),
        ],
      );
      NutritionData? persisted;
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: NutritionPage(
            foods: [food],
            meals: [existing],
            clock: () => day,
            onChanged: (data) => persisted = data,
          ),
        ),
      );
      await _tap(tester, find.text('Lunch batch'));
      await _tap(tester, find.text('Save as recipe'));
      await _enter(tester, 'Servings in batch', '4');
      await _enter(tester, 'Finished batch weight (g), optional', '650');
      await _tap(tester, find.text('Save recipe'));
      expect(persisted?.recipes.single.servings, 4);
      expect(persisted?.meals.single, same(existing));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Next day'));

      await _tap(tester, find.byTooltip('Saved recipes'));
      await _tap(tester, find.text('Lunch batch'));
      await _tap(tester, find.text('Servings'));
      await _tap(tester, find.text('Finished weight').last);
      await _enter(tester, 'Weight eaten (g)', '130');
      await _tap(tester, find.text('Review meal'));
      expect(find.text('New meal'), findsOneWidget);
      expect(find.text('40 g · Estimated'), findsOneWidget);
      expect(persisted?.meals, hasLength(1));

      await _tap(tester, find.text('Save meal'));
      expect(persisted?.meals, hasLength(2));
      expect(persisted?.meals.first, same(existing));
      final reused = persisted!.meals.last;
      expect(reused.id, isNot(existing.id));
      expect(reused.eatenAt.day, 17);
      expect(reused.portions.single.amount, 40);
      expect(reused.portions.single.food, same(food));
      expect(persisted!.recipes.single.ingredients.single.amount, 200);
      expect(tester.takeException(), isNull);
    },
  );
}

NutritionFood _riceFood(double energy) => NutritionFood(
  id: 'rice',
  name: 'Cooked rice',
  referenceAmount: 100,
  referenceUnit: NutritionUnit.grams,
  values: NutritionValues(energyKcal: energy),
);

Future<void> _tap(WidgetTester tester, Finder item) async {
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
