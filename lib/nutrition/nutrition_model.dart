import 'dart:convert';

import '../storage/attachment_store.dart';

enum NutritionUnit {
  grams('g', 'Grams', _UnitKind.mass, 1),
  kilograms('kg', 'Kilograms', _UnitKind.mass, 1000),
  millilitres('mL', 'Millilitres', _UnitKind.volume, 1),
  litres('L', 'Litres', _UnitKind.volume, 1000),
  servings('servings', 'Servings', _UnitKind.servings, 1);

  const NutritionUnit(this.symbol, this.label, this._kind, this._scale);

  final String symbol;
  final String label;
  final _UnitKind _kind;
  final double _scale;

  bool isCompatibleWith(NutritionUnit other) => _kind == other._kind;

  double convert(double amount, NutritionUnit to) {
    if (!isCompatibleWith(to)) {
      throw const FormatException('These units measure different quantities.');
    }
    return _base(amount) / to._scale;
  }

  double _base(double amount) => amount * _scale;

  String format(double amount) =>
      '${formatNutritionNumber(amount)} ${this == servings && amount == 1 ? 'serving' : symbol}';
}

enum _UnitKind { mass, volume, servings }

enum Nutrient {
  energy('Energy', 'kcal'),
  protein('Protein', 'g'),
  carbohydrates('Carbs', 'g'),
  fat('Fat', 'g');

  const Nutrient(this.label, this.unit);

  final String label;
  final String unit;
}

class NutritionValues {
  const NutritionValues({
    this.energyKcal,
    this.proteinGrams,
    this.carbsGrams,
    this.fatGrams,
  });

  factory NutritionValues.fromJson(Map<String, dynamic> json) =>
      NutritionValues(
        energyKcal: _number(json['energyKcal']),
        proteinGrams: _number(json['proteinGrams']),
        carbsGrams: _number(json['carbsGrams']),
        fatGrams: _number(json['fatGrams']),
      );

  final double? energyKcal;
  final double? proteinGrams;
  final double? carbsGrams;
  final double? fatGrams;

  double? operator [](Nutrient nutrient) => switch (nutrient) {
    Nutrient.energy => energyKcal,
    Nutrient.protein => proteinGrams,
    Nutrient.carbohydrates => carbsGrams,
    Nutrient.fat => fatGrams,
  };

  Map<String, Object?> toJson() => {
    'energyKcal': energyKcal,
    'proteinGrams': proteinGrams,
    'carbsGrams': carbsGrams,
    'fatGrams': fatGrams,
  };
}

class NutritionFood {
  NutritionFood({
    required this.id,
    required this.name,
    required this.referenceAmount,
    required this.referenceUnit,
    this.values = const NutritionValues(),
    this.source,
    this.estimated = false,
  }) {
    _requiredText(id, 'Food ID');
    _requiredText(name, 'Food name');
    _checkAmount(referenceAmount, referenceUnit);
    for (final nutrient in Nutrient.values) {
      final value = values[nutrient];
      if (value != null && (!value.isFinite || value < 0)) {
        throw const FormatException(
          'Nutrition values must be nonnegative numbers.',
        );
      }
    }

    final base = referenceUnit._base(referenceAmount);
    final energy = values.energyKcal ?? 0;
    final macros =
        (values.proteinGrams ?? 0) +
        (values.carbsGrams ?? 0) +
        (values.fatGrams ?? 0);
    final bounds = switch (referenceUnit._kind) {
      _UnitKind.mass => (energy: base * 10, macros: base * 1.05),
      _UnitKind.volume => (energy: base * 30, macros: base * 3),
      _UnitKind.servings => (energy: base * 20000, macros: base * 5000),
    };
    if (energy > bounds.energy || macros > bounds.macros) {
      throw const FormatException(
        'Check the nutrition values and reference quantity.',
      );
    }
    _checkMealTotals(energy, macros);
  }

  factory NutritionFood.fromJson(Map<String, dynamic> json) => NutritionFood(
    id: json['id'] as String,
    name: json['name'] as String,
    referenceAmount: _number(json['referenceAmount'])!,
    referenceUnit: NutritionUnit.values.byName(json['referenceUnit'] as String),
    values: NutritionValues.fromJson(json['values'] as Map<String, dynamic>),
    source: json['source'] as String?,
    estimated: json['estimated'] as bool? ?? false,
  );

  final String id;
  final String name;
  final double referenceAmount;
  final NutritionUnit referenceUnit;
  final NutritionValues values;
  final String? source;
  final bool estimated;

  @override
  bool operator ==(Object other) =>
      other is NutritionFood &&
      id == other.id &&
      name == other.name &&
      referenceAmount == other.referenceAmount &&
      referenceUnit == other.referenceUnit &&
      source == other.source &&
      estimated == other.estimated &&
      Nutrient.values.every((nutrient) => values[nutrient] == other.values[nutrient]);

  @override
  int get hashCode => Object.hash(
    id, name, referenceAmount, referenceUnit, source, estimated,
    Object.hashAll(Nutrient.values.map((nutrient) => values[nutrient])),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'referenceAmount': referenceAmount,
    'referenceUnit': referenceUnit.name,
    'values': values.toJson(),
    if (source != null) 'source': source,
    if (estimated) 'estimated': true,
  };
}

class NutritionPortion {
  NutritionPortion({
    required this.food,
    required this.amount,
    required this.unit,
    this.estimated = false,
    this.minimumAmount,
    this.maximumAmount,
  }) {
    if (!unit.isCompatibleWith(food.referenceUnit)) {
      throw const FormatException('Use a unit compatible with the food label.');
    }
    _checkAmount(amount, unit);
    final minimum = minimumAmount;
    final maximum = maximumAmount;
    if (minimum != null || maximum != null) {
      if (minimum == null || maximum == null) {
        throw const FormatException('Enter both ends of the portion range.');
      }
      _checkAmount(minimum, unit, allowZero: true);
      _checkAmount(maximum, unit);
      if (minimum > amount || maximum < amount) {
        throw const FormatException(
          'The portion range must include the entered amount.',
        );
      }
    }
    final scale = _scale(maximum ?? amount);
    final values = food.values;
    _checkMealTotals(
      (values.energyKcal ?? 0) * scale,
      ((values.proteinGrams ?? 0) +
              (values.carbsGrams ?? 0) +
              (values.fatGrams ?? 0)) *
          scale,
    );
  }

  factory NutritionPortion.fromJson(Map<String, dynamic> json) =>
      NutritionPortion(
        food: NutritionFood.fromJson(json['food'] as Map<String, dynamic>),
        amount: _number(json['amount'])!,
        unit: NutritionUnit.values.byName(json['unit'] as String),
        estimated: json['estimated'] as bool? ?? false,
        minimumAmount: _number(json['minimumAmount']),
        maximumAmount: _number(json['maximumAmount']),
      );

  // Keep a snapshot so editing a saved food doesn't rewrite the meal history.
  final NutritionFood food;
  final double amount;
  final NutritionUnit unit;
  final bool estimated;
  final double? minimumAmount;
  final double? maximumAmount;

  double _scale(double quantity) =>
      unit._base(quantity) / food.referenceUnit._base(food.referenceAmount);

  Map<String, Object?> toJson() => {
    'food': food.toJson(),
    'amount': amount,
    'unit': unit.name,
    if (estimated) 'estimated': true,
    if (minimumAmount != null) 'minimumAmount': minimumAmount,
    if (maximumAmount != null) 'maximumAmount': maximumAmount,
  };
}

class NutritionMeal {
  NutritionMeal({
    required this.id,
    required this.name,
    required this.eatenAt,
    List<NutritionPortion> portions = const [],
    this.photo,
    this.draft = false,
  }) : portions = List.unmodifiable(portions) {
    _requiredText(id, 'Meal ID');
    _requiredText(name, 'Meal name');
    if (photo != null && photo!.format.kind != AttachmentKind.photo) {
      throw const FormatException('This attachment is not a meal photo.');
    }
    if (!draft && this.portions.isEmpty) {
      throw const FormatException('Add at least one food to save this meal.');
    }
    var maxEnergy = 0.0;
    var maxMacros = 0.0;
    for (final portion in this.portions) {
      final factor = portion._scale(portion.maximumAmount ?? portion.amount);
      final values = portion.food.values;
      maxEnergy += (values.energyKcal ?? 0) * factor;
      maxMacros +=
          ((values.proteinGrams ?? 0) +
              (values.carbsGrams ?? 0) +
              (values.fatGrams ?? 0)) *
          factor;
    }
    _checkMealTotals(maxEnergy, maxMacros);
  }

  factory NutritionMeal.fromJson(Map<String, dynamic> json) => NutritionMeal(
    id: json['id'] as String,
    name: json['name'] as String,
    eatenAt: DateTime.parse(json['eatenAt'] as String),
    portions: _objects(json['portions'])
        .map(NutritionPortion.fromJson)
        .toList(),
    photo: json['photo'] == null
        ? null
        : AttachmentRef.fromJson(json['photo'] as Map<String, dynamic>),
    draft: json['draft'] as bool? ?? false,
  );

  final String id;
  final String name;
  final DateTime eatenAt;
  final List<NutritionPortion> portions;
  final AttachmentRef? photo;
  final bool draft;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'eatenAt': eatenAt.toUtc().toIso8601String(),
    'portions': [for (final portion in portions) portion.toJson()],
    if (photo != null) 'photo': photo!.toJson(),
    if (draft) 'draft': true,
  };
}

class NutritionData {
  NutritionData({
    List<NutritionFood> foods = const [],
    List<NutritionMeal> meals = const [],
  }) : foods = List.unmodifiable(foods),
       meals = List.unmodifiable(meals) {
    if ({for (final food in foods) food.id}.length != foods.length ||
        {for (final meal in meals) meal.id}.length != meals.length) {
      throw const FormatException('Duplicate nutrition record.');
    }
  }

  factory NutritionData.decode(String encoded) =>
      NutritionData.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

  factory NutritionData.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported nutrition version.');
    }
    return NutritionData(
      foods: _objects(json['foods']).map(NutritionFood.fromJson).toList(),
      meals: _objects(json['meals']).map(NutritionMeal.fromJson).toList(),
    );
  }

  final List<NutritionFood> foods;
  final List<NutritionMeal> meals;

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {
    'version': 1,
    'foods': [for (final food in foods) food.toJson()],
    'meals': [for (final meal in meals) meal.toJson()],
  };

  List<NutritionMeal> mealsFor(DateTime day) => [
    for (final meal in meals)
      if (_sameLocalDay(meal.eatenAt, day)) meal,
  ]..sort((a, b) => a.eatenAt.compareTo(b.eatenAt));

  Map<Nutrient, NutrientTotal> totalsFor(DateTime day) => nutritionTotals([
    for (final meal in mealsFor(day))
      if (!meal.draft) ...meal.portions,
  ]);
}

class NutrientTotal {
  const NutrientTotal({
    this.amount,
    this.minimum,
    this.maximum,
    this.partial = false,
    this.estimated = false,
  });

  final double? amount;
  final double? minimum;
  final double? maximum;
  final bool partial;
  final bool estimated;
}

Map<Nutrient, NutrientTotal> nutritionTotals(
  Iterable<NutritionPortion> portions,
) {
  final records = portions.toList();
  return {
    for (final nutrient in Nutrient.values)
      nutrient: _sumNutrient(records, nutrient),
  };
}

NutrientTotal _sumNutrient(List<NutritionPortion> portions, Nutrient nutrient) {
  var known = 0;
  var amount = 0.0;
  var minimum = 0.0;
  var maximum = 0.0;
  var estimated = false;
  var ranged = false;
  var unquantified = false;
  for (final portion in portions) {
    final value = portion.food.values[nutrient];
    if (value == null) continue;
    known++;
    amount += value * portion._scale(portion.amount);
    minimum += value * portion._scale(portion.minimumAmount ?? portion.amount);
    maximum += value * portion._scale(portion.maximumAmount ?? portion.amount);
    final portionHasRange = portion.minimumAmount != null;
    ranged |= portionHasRange;
    unquantified |=
        portion.food.estimated || (portion.estimated && !portionHasRange);
    estimated |= portion.food.estimated || portion.estimated || portionHasRange;
  }
  return NutrientTotal(
    amount: known == 0 ? null : amount,
    partial: known < portions.length,
    estimated: estimated,
    minimum: ranged && !unquantified ? minimum : null,
    maximum: ranged && !unquantified ? maximum : null,
  );
}

String formatNutritionNumber(double value, {int decimals = 2}) {
  final fixed = value.toStringAsFixed(decimals);
  return decimals == 0 ? fixed : fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

var _serial = 0;

String newNutritionId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_serial++}';

bool _sameLocalDay(DateTime a, DateTime b) {
  final first = a.toLocal();
  final second = b.toLocal();
  return first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;
}

void _requiredText(String text, String label) {
  if (text.trim().isEmpty) throw FormatException('$label is required.');
}

void _checkAmount(double amount, NutritionUnit unit, {bool allowZero = false}) {
  final base = unit._base(amount);
  final limit = unit == NutritionUnit.servings ? 1000 : 1000000;
  if (!base.isFinite || base < 0 || (!allowZero && base == 0) || base > limit) {
    throw const FormatException('Check the quantity and unit.');
  }
}

void _checkMealTotals(double energy, double macros) {
  if (!energy.isFinite ||
      !macros.isFinite ||
      energy > 100000 ||
      macros > 20000) {
    throw const FormatException('Check the portion size and nutrition values.');
  }
}

double? _number(Object? value) =>
    value == null ? null : (value as num).toDouble();

Iterable<Map<String, dynamic>> _objects(Object? list) =>
    (list as List<dynamic>).cast<Map<String, dynamic>>();
