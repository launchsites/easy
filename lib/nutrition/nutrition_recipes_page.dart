part of 'nutrition_page.dart';

class _RecipeLibrary extends StatefulWidget {
  const _RecipeLibrary({
    required this.recipes,
    required this.foods,
    required this.onEdited,
    required this.onFoodSaved,
  });

  final List<NutritionRecipe> recipes;
  final List<NutritionFood> foods;
  final ValueChanged<_RecordEdit<NutritionRecipe>> onEdited;
  final ValueChanged<NutritionFood> onFoodSaved;

  @override
  State<_RecipeLibrary> createState() => _RecipeLibraryState();
}

class _RecipeLibraryState extends State<_RecipeLibrary> {
  late var _recipes = widget.recipes;
  late var _foods = widget.foods;

  Future<void> _edit([NutritionRecipe? recipe]) async {
    final edit = await _push<_RecordEdit<NutritionRecipe>>(
      context,
      _RecipeEditor(
        recipe: recipe,
        foods: _foods,
        onFoodSaved: (food) {
          _foods = _updated(_foods, (
            record: food,
            removed: false,
          ), (item) => item.id);
          widget.onFoodSaved(food);
        },
      ),
    );
    if (!mounted || edit == null) return;
    setState(() => _recipes = _updated(_recipes, edit, (item) => item.id));
    widget.onEdited(edit);
  }

  @override
  Widget build(BuildContext context) {
    final recipes = _recipes.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return _NutritionScreen(
      title: 'Saved recipes',
      footer: FilledButton(onPressed: _edit, child: const Text('New recipe')),
      children: [
        if (recipes.isEmpty)
          const Text('No saved recipes.', style: contentMetadataStyle),
        for (final recipe in recipes) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(recipe.name, style: contentTitleStyle),
            subtitle: Text(_recipeYield(recipe), style: contentMetadataStyle),
            trailing: IconButton(
              tooltip: 'Edit ${recipe.name}',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(recipe),
            ),
            onTap: () => Navigator.pop(context, recipe),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

class _RecipeEditor extends StatefulWidget {
  const _RecipeEditor({
    this.recipe,
    this.initialName,
    this.initialIngredients = const [],
    required this.foods,
    required this.onFoodSaved,
  });

  final NutritionRecipe? recipe;
  final String? initialName;
  final List<NutritionPortion> initialIngredients;
  final List<NutritionFood> foods;
  final ValueChanged<NutritionFood> onFoodSaved;

  @override
  State<_RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends State<_RecipeEditor> {
  late final _name = TextEditingController(
    text: widget.recipe?.name ?? widget.initialName,
  );
  late final _servings = TextEditingController(
    text: _inputNumber(widget.recipe?.servings ?? 1),
  );
  late final _weight = TextEditingController(
    text: _inputNumber(widget.recipe?.finishedWeightGrams),
  );
  late final _ingredients = [
    ...widget.recipe?.ingredients ?? widget.initialIngredients,
  ];
  late final _foods = [...widget.foods];
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _servings.dispose();
    _weight.dispose();
    super.dispose();
  }

  Future<NutritionFood?> _newFood() async {
    final edit = await _push<_RecordEdit<NutritionFood>>(
      context,
      const _FoodEditor(),
    );
    if (!mounted || edit == null) return null;
    _foods.add(edit.record);
    widget.onFoodSaved(edit.record);
    return edit.record;
  }

  Future<void> _editIngredient([int? index]) async {
    final portion = await showNutritionPortionEditor(
      context,
      foods: _foods,
      existing: index == null ? null : _ingredients[index],
      onNewFood: _newFood,
    );
    if (!mounted || portion == null) return;
    setState(() {
      if (index == null) {
        _ingredients.add(portion);
      } else {
        _ingredients[index] = portion;
      }
      _error = null;
    });
  }

  void _save() {
    try {
      final recipe = NutritionRecipe(
        id: widget.recipe?.id ?? newNutritionId(),
        name: _name.text.trim(),
        servings: _numberField(_servings, 'servings')!,
        finishedWeightGrams: _numberField(
          _weight,
          'finished weight',
          optional: true,
        ),
        ingredients: _ingredients,
      );
      Navigator.pop(context, (record: recipe, removed: false));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _removeRecipe(NutritionRecipe recipe) async {
    if (await _confirm(context, 'Remove saved recipe?') && mounted) {
      Navigator.pop(context, (record: recipe, removed: true));
    }
  }

  @override
  Widget build(BuildContext context) => _NutritionScreen(
    title: widget.recipe == null ? 'New recipe' : 'Edit recipe',
    error: _error,
    footer: FilledButton(onPressed: _save, child: const Text('Save recipe')),
    children: [
      _Input(label: 'Recipe name', controller: _name),
      const SizedBox(height: 9),
      _Input(label: 'Servings in batch', controller: _servings, numeric: true),
      const SizedBox(height: 9),
      _Input(
        label: 'Finished batch weight (g), optional',
        controller: _weight,
        numeric: true,
      ),
      const SizedBox(height: 20),
      const _Heading('Ingredients'),
      ..._portionRows(
        _ingredients,
        parentLabel: 'recipe',
        onEdit: _editIngredient,
        onRemove: (index) => setState(() => _ingredients.removeAt(index)),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: _editIngredient,
          icon: const Icon(Icons.add_rounded, size: 19),
          label: const Text('Add ingredient'),
        ),
      ),
      if (widget.recipe case final recipe?)
        _RemoveAction(
          label: 'Remove recipe',
          onPressed: () => _removeRecipe(recipe),
        ),
    ],
  );
}

enum _RecipeBasis { servings, weight }

class _RecipePortionDialog extends StatefulWidget {
  const _RecipePortionDialog({required this.recipe});

  final NutritionRecipe recipe;

  @override
  State<_RecipePortionDialog> createState() => _RecipePortionDialogState();
}

class _RecipePortionDialogState extends State<_RecipePortionDialog> {
  final _amount = TextEditingController(text: '1');
  var _basis = _RecipeBasis.servings;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _review() {
    try {
      final amount = _numberField(_amount, 'portion')!;
      final portions = switch (_basis) {
        _RecipeBasis.servings => widget.recipe.portionsForServings(amount),
        _RecipeBasis.weight => widget.recipe.portionsForWeight(amount),
      };
      Navigator.pop(context, portions);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.recipe.name),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Batch · ${_recipeYield(widget.recipe)}',
          style: contentMetadataStyle,
        ),
        const SizedBox(height: 12),
        if (widget.recipe.finishedWeightGrams != null) ...[
          DropdownButtonFormField<_RecipeBasis>(
            initialValue: _basis,
            isExpanded: true,
            decoration: _decoration('Measure by'),
            items: const [
              DropdownMenuItem(
                value: _RecipeBasis.servings,
                child: Text('Servings', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: _RecipeBasis.weight,
                child: Text('Finished weight', overflow: TextOverflow.ellipsis),
              ),
            ],
            onChanged: (basis) {
              if (basis == null || basis == _basis) return;
              setState(() {
                _basis = basis;
                _amount.text = basis == _RecipeBasis.servings ? '1' : '';
                _error = null;
              });
            },
          ),
          const SizedBox(height: 9),
        ],
        _Input(
          label: _basis == _RecipeBasis.servings
              ? 'Servings eaten'
              : 'Weight eaten (g)',
          controller: _amount,
          numeric: true,
        ),
        if (_error case final message?) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _review, child: const Text('Review meal')),
    ],
  );
}

String _recipeYield(NutritionRecipe recipe) => [
  NutritionUnit.servings.format(recipe.servings),
  if (recipe.finishedWeightGrams case final weight?)
    '${NutritionUnit.grams.format(weight)} finished',
].join(' · ');

Iterable<Widget> _portionRows(
  List<NutritionPortion> portions, {
  required String parentLabel,
  required ValueChanged<int> onEdit,
  required ValueChanged<int> onRemove,
}) sync* {
  for (final (index, portion) in portions.indexed) {
    yield ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(portion.food.name, style: contentTitleStyle),
      subtitle: Text(
        '${portion.unit.format(portion.amount)}${portion.estimated || portion.minimumAmount != null ? ' · Estimated' : ''}',
        style: contentMetadataStyle,
      ),
      onTap: () => onEdit(index),
      trailing: IconButton(
        tooltip: 'Remove ${portion.food.name} from $parentLabel',
        icon: const Icon(Icons.close_rounded, color: muted, size: 20),
        onPressed: () => onRemove(index),
      ),
    );
    yield const Divider();
  }
}
