import 'package:material_ui/material_ui.dart';

import '../ai/ai_runtime_settings.dart' show formatPoundsMicros;
import '../ai/vision/meal_vision.dart';
import '../ui_theme.dart';
import 'nutrition_model.dart';

enum MealVisionMatchIssue {
  foodMissing,
  foodAmbiguous,
  portionUnknown,
  incompatibleFood,
  invalidPortion,
}

class MealVisionMatch {
  const MealVisionMatch({required this.candidate, this.portion, this.issue});

  final MealVisionCandidate candidate;
  final NutritionPortion? portion;
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
        foods[normalizeMealVisionLabel(candidate.label)] ?? const [],
      ),
  ]);
}

MealVisionMatch _match(
  MealVisionCandidate candidate,
  List<NutritionFood> matches,
) {
  MealVisionMatch issue(MealVisionMatchIssue value) =>
      MealVisionMatch(candidate: candidate, issue: value);
  if (matches.isEmpty) return issue(MealVisionMatchIssue.foodMissing);
  if (matches.length != 1) return issue(MealVisionMatchIssue.foodAmbiguous);
  final grams = candidate.grams;
  if (grams == null) return issue(MealVisionMatchIssue.portionUnknown);
  if (!grams.valid) return issue(MealVisionMatchIssue.invalidPortion);
  final food = matches.single;
  if (!food.referenceUnit.isCompatibleWith(NutritionUnit.grams)) {
    return issue(MealVisionMatchIssue.incompatibleFood);
  }
  try {
    return MealVisionMatch(
      candidate: candidate,
      portion: NutritionPortion(
        food: food,
        amount: (grams.minimum + grams.maximum) / 2,
        unit: NutritionUnit.grams,
        minimumAmount: grams.minimum,
        maximumAmount: grams.maximum,
        estimated: true,
      ),
    );
  } on FormatException {
    return issue(MealVisionMatchIssue.invalidPortion);
  }
}

Map<Nutrient, NutrientTotal> mealVisionNutritionTotals(
  Iterable<MealVisionMatch> matches,
) {
  final items = matches.toList();
  final partial = items.any((item) => item.portion == null);
  final totals = nutritionTotals([for (final item in items) ?item.portion]);
  return Map.unmodifiable({
    for (final item in totals.entries)
      item.key: NutrientTotal(
        amount: item.value.amount,
        minimum: item.value.minimum,
        maximum: item.value.maximum,
        partial: partial || item.value.partial,
        estimated: item.value.estimated,
      ),
  });
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
) => showDialog<List<NutritionPortion>>(
  context: context,
  builder: (_) =>
      _MealSuggestionDialog(matches: matchMealVisionFoods(review, foods)),
);

class _MealSuggestionDialog extends StatefulWidget {
  const _MealSuggestionDialog({required this.matches});

  final List<MealVisionMatch> matches;

  @override
  State<_MealSuggestionDialog> createState() => _MealSuggestionDialogState();
}

class _MealSuggestionDialogState extends State<_MealSuggestionDialog> {
  final _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    final selected = [
      for (var index = 0; index < widget.matches.length; index++)
        if (_selected.contains(index)) widget.matches[index],
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
            _candidateRow(index, widget.matches[index]),
          if (selected.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Selected nutrition', style: sectionHeadingStyle),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                for (final nutrient in Nutrient.values)
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
    final amount = switch (interval) {
      null => 'Portion unknown',
      final range when range.valid => 'Estimated ${_grams(range)}',
      _ => 'Portion needs review',
    };
    final issue = switch (match.issue) {
      MealVisionMatchIssue.foodMissing => 'Choose a saved food manually',
      MealVisionMatchIssue.foodAmbiguous => 'Multiple foods share this name',
      MealVisionMatchIssue.incompatibleFood =>
        'Saved food uses a different unit',
      MealVisionMatchIssue.invalidPortion => 'Portion needs review',
      MealVisionMatchIssue.portionUnknown || null => null,
    };
    final description = issue == null || issue == amount
        ? amount
        : '$amount\n$issue';
    if (match.portion == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(candidate.label),
        subtitle: Text(description),
      );
    }
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _selected.contains(index),
      title: Text(match.portion!.food.name),
      subtitle: Text(description),
      onChanged: (checked) => setState(() {
        if (checked == true) {
          _selected.add(index);
        } else {
          _selected.remove(index);
        }
      }),
    );
  }
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
