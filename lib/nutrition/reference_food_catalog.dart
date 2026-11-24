import 'dart:math' as math;

import 'nutrition_model.dart';

part 'reference_sr_legacy_data.dart';

/// A read-only offline catalog kept apart from workspace-defined foods.
final referenceFoodCatalog = ReferenceFoodCatalog._(_srLegacyFoods);

enum ReferenceFoodGroup {
  fruit('Fruit'),
  vegetable('Vegetables'),
  protein('Meat, fish, eggs and beans'),
  grain('Grains and breads'),
  dairy('Dairy'),
  pantry('Pantry'),
  drink('Drinks');

  const ReferenceFoodGroup(this.label);
  final String label;
}

enum ReferenceNutrient {
  energy(1008, 'Energy', Nutrient.energy),
  protein(1003, 'Protein', Nutrient.protein),
  carbohydrates(1005, 'Carbohydrate by difference', Nutrient.carbohydrates),
  fat(1004, 'Total fat', Nutrient.fat),
  fibre(1079, 'Dietary fibre', Nutrient.fibre),
  totalSugars(2000, 'Total sugars', Nutrient.totalSugars),
  calcium(1087, 'Calcium', Nutrient.calcium),
  iron(1089, 'Iron', Nutrient.iron),
  magnesium(1090, 'Magnesium', Nutrient.magnesium),
  potassium(1092, 'Potassium', Nutrient.potassium),
  sodium(1093, 'Sodium', Nutrient.sodium),
  vitaminC(1162, 'Vitamin C', Nutrient.vitaminC),
  vitaminD(1114, 'Vitamin D', Nutrient.vitaminD),
  folate(1177, 'Total folate', Nutrient.folate),
  vitaminB12(1178, 'Vitamin B12', Nutrient.vitaminB12);

  const ReferenceNutrient(this.fdcNutrientId, this.label, this.nutrient);
  final int fdcNutrientId;
  final String label;
  final Nutrient nutrient;
  String get unit => nutrient.unit;
}

class ReferenceNutrientValue {
  const ReferenceNutrientValue(
    this.per100Grams,
    this.fdcNutrientRowId,
    this.dataPoints,
    this.derivationCode,
  );

  final double per100Grams;
  final int fdcNutrientRowId;
  final int? dataPoints;
  final String? derivationCode;
}

class ReferenceFoodMeasure {
  const ReferenceFoodMeasure(
    this.fdcPortionId,
    this.amount,
    this.gramWeight,
    this.officialUnit,
    this.officialDescription,
    this.officialModifier,
    this.dataPoints,
  );

  final int fdcPortionId;
  final double amount;
  final double gramWeight;
  final String officialUnit;
  final String? officialDescription;
  final String? officialModifier;
  final int? dataPoints;

  String get label {
    final description =
        officialDescription ??
        [
          if (officialUnit != 'undetermined') officialUnit,
          ?officialModifier,
        ].join(' ');
    return '${formatNutritionNumber(amount)} $description'.trim();
  }
}

class ReferenceFood {
  const ReferenceFood._({
    required this.fdcId,
    required this.ndbNumber,
    required this.name,
    required this.officialDescription,
    required this.group,
    required this.aliases,
    required this.composition,
    required this.measures,
  });

  static const dataset = 'USDA FoodData Central · SR Legacy (2018-04)';
  static const referenceGrams = 100.0;

  final int fdcId;
  final String ndbNumber;
  final String name;
  final String officialDescription;
  final ReferenceFoodGroup group;
  final List<String> aliases;

  /// A missing nutrient stays absent. A published zero is present here.
  final Map<ReferenceNutrient, ReferenceNutrientValue> composition;

  /// Published examples. The user still chooses or weighs their own portion.
  final List<ReferenceFoodMeasure> measures;

  String get id => 'usda:sr-legacy:$fdcId';
  Uri get sourceUrl =>
      Uri.https('fdc.nal.usda.gov', '/food-details/$fdcId/nutrients');

  /// The multiplier is the number of copies of this published measure.
  /// A measure-derived weight is always recorded as estimated.
  NutritionPortion estimatedPortion(int fdcPortionId, {double multiplier = 1}) {
    final measure = measures
        .where((item) => item.fdcPortionId == fdcPortionId)
        .firstOrNull;
    if (measure == null) {
      throw const FormatException('Choose a published measure for this food.');
    }
    return NutritionPortion(
      food: toNutritionFood(),
      amount: measure.gramWeight * multiplier,
      unit: NutritionUnit.grams,
      estimated: true,
      estimateSource:
          'USDA FDC $fdcId · portion ${measure.fdcPortionId} (${measure.label})',
    );
  }

  NutritionFood toNutritionFood() {
    double? amount(ReferenceNutrient nutrient) =>
        composition[nutrient]?.per100Grams;
    return NutritionFood(
      id: id,
      name: name,
      referenceAmount: referenceGrams,
      referenceUnit: NutritionUnit.grams,
      values: NutritionValues.detailed(
        energyKcal: amount(ReferenceNutrient.energy),
        proteinGrams: amount(ReferenceNutrient.protein),
        carbsGrams: amount(ReferenceNutrient.carbohydrates),
        fatGrams: amount(ReferenceNutrient.fat),
        details: {
          for (final entry in composition.entries)
            if (entry.key.nutrient.isAdditional)
              entry.key.nutrient: entry.value.per100Grams,
        },
      ),
      source: '$dataset · FDC $fdcId · $sourceUrl',
    );
  }
}

class ReferenceFoodCatalog {
  ReferenceFoodCatalog._(this.foods)
    : _byFdcId = {for (final food in foods) food.fdcId: food},
      _labels = {
        for (final food in foods)
          food.fdcId: [
            _normalize(food.name),
            for (final alias in food.aliases) _normalize(alias),
          ],
      } {
    for (final food in foods) {
      final keys = _labels[food.fdcId]!.map(_key).toSet();
      for (final key in keys) {
        (_exact[key] ??= []).add(food);
      }
    }
  }

  final List<ReferenceFood> foods;
  final Map<int, ReferenceFood> _byFdcId;
  final Map<int, List<String>> _labels;
  final _exact = <String, List<ReferenceFood>>{};

  ReferenceFood? byFdcId(int id) => _byFdcId[id];

  /// Resolves a catalog snapshot without inspecting or replacing meal values.
  ReferenceFood? referenceFor(NutritionFood snapshot) {
    const prefix = 'usda:sr-legacy:';
    if (!snapshot.id.startsWith(prefix)) return null;
    final id = int.tryParse(snapshot.id.substring(prefix.length));
    final reference = id == null ? null : byFdcId(id);
    if (reference == null) return null;
    final published = reference.toNutritionFood();
    if (published == snapshot) return reference;
    // Older catalog meals keep their original recorded fields when using a measure.
    return snapshot.values.details.isEmpty &&
            snapshot.id == published.id &&
            snapshot.name == published.name &&
            snapshot.source == published.source &&
            snapshot.referenceUnit == published.referenceUnit &&
            snapshot.referenceAmount == published.referenceAmount &&
            snapshot.estimated == published.estimated &&
            Nutrient.primary.every(
              (item) => snapshot.values[item] == published.values[item],
            )
        ? reference
        : null;
  }

  /// Requires an exact name or alias. A generic label can match several foods.
  List<ReferenceFood> exactMatches(String label) {
    final key = _key(_normalize(label));
    return List.unmodifiable(_exact[key] ?? const <ReferenceFood>[]);
  }

  /// Ranked browse suggestions for an explicit manual choice.
  List<ReferenceFood> search(
    String text, {
    ReferenceFoodGroup? group,
    int limit = 25,
  }) {
    if (limit < 1) return const [];
    final maximum = math.min(limit, 100);
    final query = _normalize(text);
    final eligible = foods.where(
      (food) => group == null || food.group == group,
    );
    if (query.isEmpty) return List.unmodifiable(eligible.take(maximum));
    final terms = query.split(' ');
    final exact =
        _exact[_key(query)]?.map((food) => food.fdcId).toSet() ?? const <int>{};
    final ranked = <(int, ReferenceFood)>[];
    for (final food in eligible) {
      final score = exact.contains(food.fdcId)
          ? 3
          : _browseScore(_labels[food.fdcId]!, query, terms);
      if (score > 0) ranked.add((score, food));
    }
    ranked.sort((a, b) {
      final score = b.$1.compareTo(a.$1);
      return score == 0 ? a.$2.name.compareTo(b.$2.name) : score;
    });
    return List.unmodifiable(ranked.take(maximum).map((entry) => entry.$2));
  }
}

final _separator = RegExp(r'[^\p{L}\p{N}%]+', unicode: true);

String _normalize(String value) =>
    value.toLowerCase().replaceAll(_separator, ' ').trim();

String _key(String normalized) => (normalized.split(' ')..sort()).join(' ');

int _browseScore(List<String> labels, String query, List<String> terms) {
  if (labels.any((label) => label.startsWith(query))) return 2;
  for (final label in labels) {
    final words = label.split(' ');
    if (terms.every((term) => words.any((word) => word.startsWith(term)))) {
      return 1;
    }
  }
  return 0;
}
