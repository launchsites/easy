import 'package:easy/ai/vision/meal_vision.dart';
import 'package:easy/nutrition/meal_vision_review.dart';
import 'package:easy/nutrition/nutrition.dart';
import 'package:easy/nutrition/reference_food_catalog.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final catalog = referenceFoodCatalog;

  test(
    'the published extract is bounded, distinct and nutritionally valid',
    () {
      expect(catalog.foods, hasLength(138));
      expect(catalog.foods.map((food) => food.fdcId).toSet(), hasLength(138));
      expect(catalog.foods.expand((food) => food.measures), hasLength(474));
      expect(
        catalog.foods.expand((food) => food.composition.values),
        hasLength(2057),
      );
      final rows = <int>{};
      final portions = <int>{};
      for (final food in catalog.foods) {
        final snapshot = food.toNutritionFood();
        expect(snapshot.referenceAmount, 100);
        expect(snapshot.referenceUnit, NutritionUnit.grams);
        expect(snapshot.source, contains('FDC ${food.fdcId}'));
        expect(catalog.referenceFor(snapshot), same(food));
        expect(food.officialDescription, isNotEmpty);
        for (final entry in food.composition.values) {
          expect(entry.per100Grams.isFinite && entry.per100Grams >= 0, true);
          expect(rows.add(entry.fdcNutrientRowId), true);
        }
        for (final measure in food.measures) {
          expect(measure.label, isNotEmpty);
          expect(portions.add(measure.fdcPortionId), true);
          expect(
            food.estimatedPortion(measure.fdcPortionId).amount,
            measure.gramWeight,
          );
        }
      }
      expect(() => catalog.foods.clear(), throwsUnsupportedError);
    },
  );

  test('cooking state, published zero and absent values remain distinct', () {
    expect(catalog.exactMatches('rice'), hasLength(4));
    expect(catalog.exactMatches('milk'), hasLength(3));
    expect(catalog.exactMatches('chicken breast'), hasLength(2));
    expect(catalog.exactMatches('rice pudding with cinnamon'), isEmpty);
    final cooked = catalog.exactMatches('COOKED WHITE RICE').single;
    final raw = catalog.exactMatches('uncooked white rice').single;
    expect(cooked.fdcId, 169757);
    expect(cooked.toNutritionFood().values.energyKcal, 130);
    expect(raw.toNutritionFood().values.energyKcal, 365);
    expect(
      catalog
          .exactMatches('raw chicken breast')
          .single
          .toNutritionFood()
          .values
          .proteinGrams,
      22.5,
    );
    expect(
      catalog
          .exactMatches('roast chicken breast')
          .single
          .toNutritionFood()
          .values
          .proteinGrams,
      31.02,
    );
    expect(
      catalog.search('whi ri').map((food) => food.fdcId),
      containsAll([169757, 169756]),
    );
    expect(catalog.exactMatches('whi ri'), isEmpty);

    final apple = catalog.exactMatches('apple').single;
    final vinegar = catalog.exactMatches('balsamic vinegar').single;
    expect(apple.composition[ReferenceNutrient.vitaminD]?.per100Grams, 0);
    expect(vinegar.composition.containsKey(ReferenceNutrient.vitaminD), false);
    expect(ReferenceNutrient.iron.unit, 'mg');
    expect(ReferenceNutrient.vitaminD.unit, 'µg');
    final portion = apple.estimatedPortion(89193, multiplier: .5);
    expect(portion.amount, 91);
    expect(portion.estimated, true);
    expect(portion.estimateSource, contains('89193'));
    expect(portion.food.source, isNot(contains('89193')));
    expect(
      NutritionPortion.fromJson(portion.toJson()).estimateSource,
      portion.estimateSource,
    );
    expect(
      () => apple.estimatedPortion(89193, multiplier: -1),
      throwsFormatException,
    );
    expect(() => apple.estimatedPortion(1), throwsFormatException);
    expect(
      () => NutritionPortion(
        food: portion.food,
        amount: 91,
        unit: NutritionUnit.grams,
        estimateSource: 'Estimate',
      ),
      throwsFormatException,
    );
  });

  test('photo suggestions use a unique exact reference or the saved food', () {
    const interval = MealGramInterval(minimum: 80, maximum: 120);
    final review = MealVisionReview([
      const MealVisionCandidate(label: 'rice', grams: interval),
      const MealVisionCandidate(label: 'Cooked white rice', grams: interval),
      const MealVisionCandidate(label: 'banana'),
      const MealVisionCandidate(label: 'Chicken and rice', grams: interval),
    ]);
    final reference = matchMealVisionFoods(review, []);
    expect(reference.map((match) => match.issue), [
      MealVisionMatchIssue.foodAmbiguous,
      null,
      MealVisionMatchIssue.portionUnknown,
      MealVisionMatchIssue.foodMissing,
    ]);
    expect(reference[1].portion?.food.id, 'usda:sr-legacy:169757');
    expect(reference[1].portion?.estimateSource, 'Photo estimate');
    expect(reference[2].identifiedFood?.id, 'usda:sr-legacy:173944');
    expect(mealVisionNutritionTotals(reference)[Nutrient.energy]?.minimum, 104);
    expect(
      mealVisionNutritionTotals(reference)[Nutrient.energy]?.partial,
      true,
    );

    final saved = NutritionFood(
      id: 'saved',
      name: 'Cooked white rice',
      referenceAmount: 100,
      referenceUnit: NutritionUnit.grams,
      values: const NutritionValues(energyKcal: 155),
    );
    expect(matchMealVisionFoods(review, [saved])[1].portion?.food, same(saved));
  });

  testWidgets('an offline measure saves a meal without adding a library food', (
    tester,
  ) async {
    _viewport(tester);
    NutritionData? persisted;
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: NutritionPage(
          foods: const [],
          meals: const [],
          onChanged: (value) => persisted = value,
          clock: () => DateTime(2026, 11, 24, 12),
        ),
      ),
    );
    await _tap(tester, 'Add meal');
    await _tap(tester, 'Add food');
    await _enter(tester, 'Search foods', 'apple');
    await _tap(tester, 'Apple with skin, raw');
    expect(_input(tester, 'Amount eaten'), isEmpty);
    await _tap(tester, 'Published measures');
    await _tap(tester, '1 medium (3" dia) · 182 g');
    expect(_input(tester, 'Amount eaten'), '182');
    await _tap(tester, 'Save portion');
    await _tap(tester, 'Save meal');
    expect(persisted?.foods, isEmpty);
    final portion = persisted!.meals.single.portions.single;
    expect(portion.food.id, 'usda:sr-legacy:171688');
    expect(portion.amount, 182);
    expect(portion.estimateSource, contains('89193'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an ambiguous photo can be corrected before applying it', (
    tester,
  ) async {
    _viewport(tester);
    List<NutritionPortion>? result;
    final review = MealVisionReview([
      const MealVisionCandidate(
        label: 'Rice',
        grams: MealGramInterval(minimum: 80, maximum: 120),
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: easyTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showMealVisionReview(context, review, []),
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, 'Open review');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Use selected'),
          )
          .onPressed,
      isNull,
    );
    await _tap(tester, 'Rice');
    expect(find.text('Long-grain white rice, dry'), findsOneWidget);
    await _tap(tester, 'Long-grain white rice, cooked');
    expect(_input(tester, 'Amount eaten'), '100');
    await _enter(tester, 'Amount eaten', '90');
    expect(_input(tester, 'Minimum (g), optional'), isEmpty);
    await _tap(tester, 'Estimated portion');
    await _tap(tester, 'Save portion');
    expect(result, isNull);
    expect(find.text('Energy 117 kcal'), findsOneWidget);
    await _tap(tester, 'Use selected');
    expect(result!.single.food.id, 'usda:sr-legacy:169757');
    expect(result!.single.amount, 90);
    expect(result!.single.estimated, false);
    expect(result!.single.estimateSource, isNull);
    expect(tester.takeException(), isNull);
  });
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

String _input(WidgetTester tester, String label) => tester
    .widget<TextField>(find.widgetWithText(TextField, label))
    .controller!
    .text;

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}
