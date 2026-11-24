import 'package:material_ui/material_ui.dart';

import '../ai/ai_runtime_settings.dart' show formatPoundsMicros;
import '../ai/vision/meal_vision.dart';
import '../ui_theme.dart';
import 'nutrition_model.dart';
import 'nutrition_page.dart' show showNutritionPortionEditor;
import 'reference_food_catalog.dart';

enum MealVisionMatchIssue {
  foodMissing,
  foodAmbiguous,
  portionUnknown,
  incompatibleFood,
  invalidPortion,
}

class MealVisionMatch {
  const MealVisionMatch({
    required this.candidate,
    this.portion,
    this.identifiedFood,
    this.issue,
  });

  final MealVisionCandidate candidate;
  final NutritionPortion? portion;
  final NutritionFood? identifiedFood;
  final MealVisionMatchIssue? issue;
}

List<MealVisionMatch> matchMealVisionFoods(
  MealVisionReview review,
  Iterable<NutritionFood> catalog,
) {
  final foods = <String, List<NutritionFood>>{};
  for (final food in catalog) {
    (foods[normalizeMealVisionLabel(food.name)] ??= []).add(food);
  }
  return List.unmodifiable([
    for (final candidate in review.candidates)
      _match(
        candidate,
        foods[normalizeMealVisionLabel(candidate.label)] ??
            referenceFoodCatalog
                .exactMatches(candidate.label)
                .map((food) => food.toNutritionFood())
                .toList(),
      ),
  ]);
}

MealVisionMatch _match(
  MealVisionCandidate candidate,
  List<NutritionFood> matches,
) {
  MealVisionMatch issue(MealVisionMatchIssue value, [NutritionFood? food]) =>
      MealVisionMatch(candidate: candidate, identifiedFood: food, issue: value);
  if (matches.isEmpty) return issue(MealVisionMatchIssue.foodMissing);
  if (matches.length != 1) return issue(MealVisionMatchIssue.foodAmbiguous);
  final food = matches.single;
  final grams = candidate.grams;
  if (grams == null) return issue(MealVisionMatchIssue.portionUnknown, food);
  if (!grams.valid) return issue(MealVisionMatchIssue.invalidPortion, food);
  if (!food.referenceUnit.isCompatibleWith(NutritionUnit.grams)) {
    return issue(MealVisionMatchIssue.incompatibleFood, food);
  }
  try {
    return MealVisionMatch(
      candidate: candidate,
      identifiedFood: food,
      portion: NutritionPortion(
        food: food,
        amount: (grams.minimum + grams.maximum) / 2,
        unit: NutritionUnit.grams,
        minimumAmount: grams.minimum,
        maximumAmount: grams.maximum,
        estimated: true,
        estimateSource: 'Photo estimate',
      ),
    );
  } on FormatException {
    return issue(MealVisionMatchIssue.invalidPortion, food);
  }
}

Map<Nutrient, NutrientTotal> mealVisionNutritionTotals(
  Iterable<MealVisionMatch> matches,
) {
  final items = matches.toList();
  final portions = [for (final item in items) ?item.portion];
  return Map.unmodifiable(
    nutritionTotals(
      portions,
      unresolvedPortions: items.length - portions.length,
    ),
  );
}

Future<bool> showMealVisionTransmissionDialog(
  BuildContext context,
  MealVisionTransmission preview,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Send meal photo?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: Image.memory(
                preview.image.bytes,
                fit: BoxFit.contain,
                semanticLabel: 'Image prepared for this request',
              ),
            ),
            const SizedBox(height: 10),
            Text('${preview.image.width} × ${preview.image.height} PNG'),
            SelectableText(preview.endpoint.toString()),
            Text(preview.model, style: const TextStyle(color: muted)),
            if (preview.reserveMicros case final reserve?)
              Text('Reserve ${formatPoundsMicros(reserve)}'),
            const SizedBox(height: 8),
            const Text('Fields sent', style: sectionHeadingStyle),
            const Text('This image and a temporary request ID'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    ) ??
    false;

Future<List<NutritionPortion>?> showMealVisionReview(
  BuildContext context,
  MealVisionReview review,
  Iterable<NutritionFood> foods,
) {
  final saved = List<NutritionFood>.unmodifiable(foods);
  return showDialog<List<NutritionPortion>>(
    context: context,
    builder: (_) => _MealSuggestionDialog(
      matches: matchMealVisionFoods(review, saved),
      savedFoods: saved,
    ),
  );
}

class _MealSuggestionDialog extends StatefulWidget {
  const _MealSuggestionDialog({
    required this.matches,
    required this.savedFoods,
  });

  final List<MealVisionMatch> matches;
  final List<NutritionFood> savedFoods;

  @override
  State<_MealSuggestionDialog> createState() => _MealSuggestionDialogState();
}

class _MealSuggestionDialogState extends State<_MealSuggestionDialog> {
  final _selected = <int>{};
  final _overrides = <int, NutritionPortion>{};

  MealVisionMatch _matchAt(int index) {
    final match = widget.matches[index];
    final override = _overrides[index];
    if (override == null) return match;
    return MealVisionMatch(
      candidate: match.candidate,
      identifiedFood: override.food,
      portion: override,
    );
  }

  Future<void> _editMatch(int index) async {
    final match = _matchAt(index);
    final range = match.candidate.grams;
    final result = await showNutritionPortionEditor(
      context,
      foods: widget.savedFoods,
      existing: match.portion,
      identifiedFood: match.identifiedFood,
      initialSearch: match.candidate.label,
      photoRange: range == null || !range.valid
          ? null
          : (minimum: range.minimum, maximum: range.maximum),
    );
    if (result == null || !mounted) return;
    setState(() {
      _overrides[index] = result;
      _selected.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = [
      for (var index = 0; index < widget.matches.length; index++)
        if (_selected.contains(index)) _matchAt(index),
    ];
    final totals = mealVisionNutritionTotals(selected);
    return AlertDialog(
      scrollable: true,
      title: const Text('Review photo suggestions'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.matches.isEmpty) const Text('No foods were identified.'),
          for (var index = 0; index < widget.matches.length; index++)
            _candidateRow(index, _matchAt(index)),
          if (selected.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Selected nutrition', style: sectionHeadingStyle),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                for (final nutrient in Nutrient.primary)
                  Text(
                    '${nutrient.label} ${_total(totals[nutrient]!, nutrient)}',
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, [
                  for (final match in selected) match.portion!,
                ]),
          child: const Text('Use selected'),
        ),
      ],
    );
  }

  Widget _candidateRow(int index, MealVisionMatch match) {
    final candidate = match.candidate;
    final interval = candidate.grams;
    final portion = match.portion;
    final amount = portion != null
        ? _portionAmount(portion)
        : switch (interval) {
            null => 'Portion unknown',
            final range when range.valid => 'Estimated ${_grams(range)}',
            _ => 'Portion needs review',
          };
    final issue = switch (match.issue) {
      MealVisionMatchIssue.foodMissing => 'Choose a food',
      MealVisionMatchIssue.foodAmbiguous => 'Choose the preparation',
      MealVisionMatchIssue.incompatibleFood =>
        'Saved food uses a different unit',
      MealVisionMatchIssue.invalidPortion => 'Portion needs review',
      MealVisionMatchIssue.portionUnknown || null => null,
    };
    final description = issue == null || issue == amount
        ? amount
        : '$amount\n$issue';
    if (portion == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(candidate.label),
        subtitle: Text(description),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _editMatch(index),
      );
    }
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _selected.contains(index),
            title: Text(portion.food.name),
            subtitle: Text(description),
            onChanged: (checked) => setState(() {
              if (checked == true) {
                _selected.add(index);
              } else {
                _selected.remove(index);
              }
            }),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit ${portion.food.name}',
          onPressed: () => _editMatch(index),
        ),
      ],
    );
  }
}

String _portionAmount(NutritionPortion portion) {
  final min = portion.minimumAmount;
  final max = portion.maximumAmount;
  final amount = min == null || max == null || min == max
      ? portion.unit.format(portion.amount)
      : '${formatNutritionNumber(min)}–${portion.unit.format(max)}';
  return portion.estimated ? 'Estimated $amount' : amount;
}

String _grams(MealGramInterval range) => range.minimum == range.maximum
    ? '${formatNutritionNumber(range.minimum)} g'
    : '${formatNutritionNumber(range.minimum)}–${formatNutritionNumber(range.maximum)} g';

String _total(NutrientTotal total, Nutrient nutrient) {
  if (total.amount == null) return 'unknown';
  final min = total.minimum;
  final max = total.maximum;
  final value = min != null && max != null && min != max
      ? '${formatNutritionNumber(min)}–${formatNutritionNumber(max)}'
      : formatNutritionNumber(total.amount!);
  return '$value ${nutrient.unit}';
}
