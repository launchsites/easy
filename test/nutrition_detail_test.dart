import 'package:easy/ai/vision/meal_vision.dart';
import 'package:easy/nutrition/meal_vision_review.dart';
import 'package:easy/nutrition/nutrition.dart';
import 'package:easy/nutrition/reference_food_catalog.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final day = DateTime(2026, 11, 24, 12);
  final apple = referenceFoodCatalog.byFdcId(171688)!.toNutritionFood();

  test('ranged totals retain canonical masses and a published zero', () {
    expect(apple.values[Nutrient.vitaminC], 4.6);
    expect(apple.values[Nutrient.vitaminD], 0);
    final entries = nutritionTotals([
      NutritionPortion(
        food: apple,
        amount: .1,
        unit: NutritionUnit.kilograms,
        estimated: true,
        minimumAmount: .08,
        maximumAmount: .12,
      ),
      NutritionPortion(food: apple, amount: 100, unit: NutritionUnit.grams),
    ]);
    final vitaminC = entries[Nutrient.vitaminC]!;
    expect(vitaminC.amount, 9.2);
    expect(vitaminC.minimum, closeTo(8.28, 1e-9));
    expect(vitaminC.maximum, closeTo(10.12, 1e-9));
    expect(vitaminC.reportedPortions, 2);
    expect(vitaminC.estimated, true);
    expect(vitaminC.partial, false);
    expect(entries[Nutrient.vitaminD]!.amount, 0);
    expect(entries[Nutrient.vitaminD]!.minimum, 0);
    expect(Nutrient.vitaminC.unit, 'mg');
    expect(Nutrient.vitaminD.unit, 'µg');
  });

  test('unreported details withhold complete totals across a mixed diary', () {
    final known = NutritionPortion(
      food: apple,
      amount: 100,
      unit: NutritionUnit.grams,
    );
    final label = NutritionPortion(
      food: _food(const NutritionValues(energyKcal: 0)),
      amount: 100,
      unit: NutritionUnit.grams,
    );
    final journal = NutritionData(
      meals: [
        NutritionMeal(
          id: 'breakfast',
          name: 'Breakfast',
          eatenAt: day,
          portions: [known],
        ),
        NutritionMeal(
          id: 'lunch',
          name: 'Lunch',
          eatenAt: day,
          portions: [label],
        ),
        NutritionMeal(
          id: 'draft-meal',
          name: 'Draft',
          eatenAt: day,
          portions: [known],
          draft: true,
        ),
      ],
    );
    final totals = journal.totalsFor(day);
    expect(totals[Nutrient.energy]!.amount, 52);
    expect(totals[Nutrient.energy]!.partial, false);
    for (final key in [Nutrient.vitaminC, Nutrient.vitaminD]) {
      final total = totals[key]!;
      expect(total.amount, isNull);
      expect(total.minimum, isNull);
      expect(total.maximum, isNull);
      expect(total.portionCount, 2);
      expect(total.reportedPortions, 1);
      expect(total.partial, true);
    }
    final unsupported = mealVisionNutritionTotals([
      MealVisionMatch(
        candidate: const MealVisionCandidate(label: 'Apple'),
        portion: known,
      ),
      const MealVisionMatch(
        candidate: MealVisionCandidate(label: 'Mixed dish'),
        issue: MealVisionMatchIssue.foodMissing,
      ),
    ]);
    expect(unsupported[Nutrient.energy]!.amount, 52);
    expect(unsupported[Nutrient.energy]!.partial, true);
    expect(unsupported[Nutrient.vitaminD]!.amount, isNull);
    expect(unsupported[Nutrient.vitaminD]!.reportedPortions, 1);
    expect(unsupported[Nutrient.vitaminD]!.portionCount, 2);
  });

  test('snapshot decoding preserves units and rejects malformed details', () {
    final loaded = NutritionFood.fromJson(apple.toJson());
    expect(loaded, apple);
    expect(loaded.source, contains('171688'));
    expect(
      loaded.values.toJson()['details'],
      containsPair('vitaminD', {'amount': 0.0, 'unit': 'µg'}),
    );
    expect(NutritionValues.fromJson(const {})[Nutrient.vitaminD], isNull);
    for (final malformed in <Object>[
      [],
      {
        'vitaminD': {'amount': 4, 'unit': 'mg'},
      },
      {
        'vitaminD': {'amount': '4', 'unit': 'µg'},
      },
      {
        'vitaminD': {'amount': null, 'unit': 'µg'},
      },
      {
        'vitaminD': {'amount': double.infinity, 'unit': 'µg'},
      },
      {
        'vitaminD': {'amount': -1, 'unit': 'µg'},
      },
      {
        'energy': {'amount': 1, 'unit': 'kcal'},
      },
      {
        'marker': {'amount': 1, 'unit': 'µg'},
      },
    ]) {
      expect(
        () => NutritionValues.fromJson({'details': malformed}),
        throwsFormatException,
      );
    }
    expect(
      () => NutritionValues.fromJson({'energyKcal': '0'}),
      throwsFormatException,
    );
    expect(
      () => _food(NutritionValues.detailed(details: {Nutrient.sodium: 200000})),
      throwsFormatException,
    );
    final old = NutritionFood(
      id: apple.id,
      name: apple.name,
      source: apple.source,
      referenceAmount: apple.referenceAmount,
      referenceUnit: apple.referenceUnit,
      values: NutritionValues(
        energyKcal: apple.values.energyKcal,
        proteinGrams: apple.values.proteinGrams,
        carbsGrams: apple.values.carbsGrams,
        fatGrams: apple.values.fatGrams,
      ),
    );
    expect(referenceFoodCatalog.referenceFor(old)?.fdcId, 171688);
    expect(old.values[Nutrient.vitaminD], isNull);
  });

  testWidgets('detail totals open on demand and show reported coverage', (
    tester,
  ) async {
    final meals = [
      NutritionMeal(
        id: 'food',
        name: 'Breakfast',
        eatenAt: day,
        portions: [
          NutritionPortion(food: apple, amount: 100, unit: NutritionUnit.grams),
          NutritionPortion(
            food: _food(const NutritionValues(energyKcal: 0)),
            amount: 100,
            unit: NutritionUnit.grams,
          ),
        ],
      ),
    ];
    await _mount(tester, day: day, meals: meals, onChanged: (_) {});
    expect(find.text('Vitamin D'), findsNothing);
    await _tap(tester, 'More nutrients');
    expect(find.text('Unknown · 1 of 2 reported'), findsWidgets);
    expect(find.text('0 µg'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blank calorie field stays unknown and entered zero survives', (
    tester,
  ) async {
    NutritionData? data;
    await _mount(tester, day: day, onChanged: (value) => data = value);
    await _tap(tester, 'Foods');
    await _tap(tester, 'New food');
    expect(_field(tester, 'Energy (kcal)').controller!.text, isEmpty);
    await _enter(tester, 'Food name', 'Home label');
    await _tap(tester, 'More nutrients');
    expect(_field(tester, 'Vitamin D (µg)').controller!.text, isEmpty);
    await _enter(tester, 'Vitamin D (µg)', '0');
    await _tap(tester, 'Save food');
    expect(data?.foods.single.values.energyKcal, isNull);
    expect(data?.foods.single.values[Nutrient.vitaminD], 0);
    expect(data?.foods.single.values[Nutrient.iron], isNull);
    expect(tester.takeException(), isNull);
  });
}

NutritionFood _food(NutritionValues values) => NutritionFood(
  id: 'other',
  name: 'Packaged food',
  referenceAmount: 100,
  referenceUnit: NutritionUnit.grams,
  values: values,
);

Future<void> _mount(
  WidgetTester tester, {
  required DateTime day,
  List<NutritionMeal> meals = const [],
  required ValueChanged<NutritionData> onChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: easyTheme(),
      home: NutritionPage(
        foods: [],
        meals: meals,
        day: day,
        onChanged: onChanged,
      ),
    ),
  );
}

TextField _field(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.widgetWithText(TextField, label));

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextField, label);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final item = find.text(label);
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item.hitTestable());
  await tester.pumpAndSettle();
}
