import 'package:material_ui/material_ui.dart';

import '../gym_mode_ui.dart' show MobileModeFrame;
import '../storage/attachment_store.dart' show AttachmentRef;
import '../ui_theme.dart';
import 'nutrition_model.dart';
import 'reference_food_catalog.dart';

typedef ReviewMealPhoto = Future<List<NutritionPortion>?> Function(
  BuildContext context,
  NutritionMeal meal,
  List<NutritionFood> foods,
);

Future<NutritionPortion?> showNutritionPortionEditor(
  BuildContext context, {
  required List<NutritionFood> foods,
  NutritionPortion? existing,
  NutritionFood? identifiedFood,
  String initialSearch = '',
  ({double minimum, double maximum})? photoRange,
  Future<NutritionFood?> Function()? onNewFood,
}) => _push<NutritionPortion>(
  context,
  _PortionEditor(
    existing: existing,
    foods: foods,
    identifiedFood: identifiedFood,
    initialSearch: initialSearch,
    photoRange: photoRange,
    onNewFood: onNewFood,
  ),
);

class NutritionPage extends StatefulWidget {
  const NutritionPage({
    required this.foods,
    required this.meals,
    required this.onChanged,
    this.day,
    this.clock,
    this.onAttachPhoto,
    this.onViewPhoto,
    this.onReviewPhoto,
    this.onCancelPhotoReview,
    super.key,
  });

  final List<NutritionFood> foods;
  final List<NutritionMeal> meals;
  final ValueChanged<NutritionData> onChanged;
  final DateTime? day;
  final DateTime Function()? clock;
  final Future<AttachmentRef?> Function()? onAttachPhoto;
  final Future<void> Function(AttachmentRef)? onViewPhoto;
  final ReviewMealPhoto? onReviewPhoto;
  final VoidCallback? onCancelPhotoReview;

  @override
  State<NutritionPage> createState() => _NutritionPageState();
}

typedef _RecordEdit<T> = ({T record, bool removed});

class _NutritionPageState extends State<NutritionPage> {
  late DateTime _day;
  late NutritionData _data;
  var _attaching = false;

  DateTime get _now => (widget.clock ?? DateTime.now)().toLocal();

  @override
  void initState() {
    super.initState();
    _day = DateUtils.dateOnly((widget.day ?? _now).toLocal());
    _data = NutritionData(foods: widget.foods, meals: widget.meals);
  }

  @override
  void didUpdateWidget(covariant NutritionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.foods != oldWidget.foods || widget.meals != oldWidget.meals) {
      _data = NutritionData(foods: widget.foods, meals: widget.meals);
    }
  }

  void _publish(NutritionData data) {
    setState(() => _data = data);
    widget.onChanged(data);
  }

  void _saveFoods(List<NutritionFood> foods) =>
      _publish(NutritionData(foods: foods, meals: _data.meals));

  void _applyMeal(_RecordEdit<NutritionMeal> edit) {
    _publish(
      NutritionData(
        foods: _data.foods,
        meals: _updated(_data.meals, edit, (meal) => meal.id),
      ),
    );
  }

  void _moveDay(int offset) => setState(() {
    _day = DateUtils.addDaysToDate(_day, offset);
  });

  Future<void> _jumpToDay() async {
    final date = await _pickDate(context, _day, 'Choose meal log date');
    if (mounted && date != null) setState(() => _day = date);
  }

  DateTime _defaultMealTime() {
    final now = _now;
    return DateTime(_day.year, _day.month, _day.day, now.hour, now.minute);
  }

  Future<void> _editMeal([NutritionMeal? meal]) async {
    final edit = await _push<_RecordEdit<NutritionMeal>>(
      context,
      _MealEditor(
        meal: meal,
        date: _defaultMealTime(),
        foods: _data.foods,
        onFoodSaved: (food) => _saveFoods(
          _updated(_data.foods, (
            record: food,
            removed: false,
          ), (item) => item.id),
        ),
        onViewPhoto: widget.onViewPhoto,
        onReviewPhoto: widget.onReviewPhoto,
        onCancelPhotoReview: widget.onCancelPhotoReview,
      ),
    );
    if (!mounted || edit == null) return;
    _applyMeal(edit);
    if (!edit.removed) {
      setState(() => _day = DateUtils.dateOnly(edit.record.eatenAt.toLocal()));
    }
  }

  Future<void> _attachPhoto() async {
    final attach = widget.onAttachPhoto;
    if (attach == null || _attaching) return;
    final date = _defaultMealTime();
    setState(() => _attaching = true);
    try {
      final photo = await attach();
      if (!mounted || photo == null) return;
      final draft = NutritionMeal(
        id: newNutritionId(),
        name: 'Meal photo',
        eatenAt: date,
        photo: photo,
        draft: true,
      );
      _applyMeal((record: draft, removed: false));
      await _editMeal(draft);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not attach this photo.')),
        );
      }
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meals = _data.mealsFor(_day);
    final localizations = MaterialLocalizations.of(context);
    return _NutritionScreen(
      title: 'Nutrition',
      appBarActions: [
        TextButton(
          onPressed: () => _push<void>(
            context,
            _FoodLibrary(foods: _data.foods, onChanged: _saveFoods),
          ),
          child: const Text('Foods', semanticsLabel: 'Saved foods'),
        ),
        const SizedBox(width: 8),
      ],
      footer: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _editMeal,
            icon: const Icon(Icons.add_rounded, size: 19),
            label: const Text('Add meal'),
          ),
          if (widget.onAttachPhoto != null)
            OutlinedButton.icon(
              onPressed: _attaching ? null : _attachPhoto,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: const Text(
                'Attach photo',
                semanticsLabel: 'Attach meal photo',
              ),
            ),
        ],
      ),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: () => _moveDay(-1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: TextButton(
                onPressed: _jumpToDay,
                child: Text(
                  localizations.formatFullDate(_day),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: () => _moveDay(1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (meals.any((meal) => !meal.draft)) ...[
          _DailyTotals(totals: _data.totalsFor(_day)),
          const SizedBox(height: 25),
        ],
        const _Heading('Meals'),
        if (meals.isEmpty)
          const Text('No meals logged.', style: contentMetadataStyle),
        for (final meal in meals) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              meal.photo == null
                  ? Icons.restaurant_outlined
                  : Icons.photo_outlined,
              color: accent,
              size: 21,
            ),
            trailing: const Icon(Icons.chevron_right_rounded, color: muted),
            title: Text(meal.name, style: contentTitleStyle),
            subtitle: Text(
              _mealSubtitle(context, meal),
              style: contentMetadataStyle,
            ),
            onTap: () => _editMeal(meal),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

String _mealSubtitle(BuildContext context, NutritionMeal meal) {
  final time = _timeLabel(context, meal.eatenAt.toLocal());
  if (meal.draft) return '$time · Draft';
  final energy = nutritionTotals(meal.portions)[Nutrient.energy]!;
  final text = _totalText(Nutrient.energy, energy);
  return '$time · $text';
}

String _totalText(Nutrient nutrient, NutrientTotal total) {
  if (total.amount == null) return 'Unknown';
  final decimals = nutrient == Nutrient.energy ? 0 : 1;
  String formatted(double value) =>
      formatNutritionNumber(value, decimals: decimals);
  final minimum = total.minimum;
  final maximum = total.maximum;
  final quantity = minimum != null && maximum != null
      ? '${formatted(minimum)}–${formatted(maximum)}'
      : '${total.estimated ? '≈' : ''}${formatted(total.amount!)}';
  return '$quantity ${nutrient.unit}${total.partial ? ' · Partial' : ''}';
}

class _DailyTotals extends StatelessWidget {
  const _DailyTotals({required this.totals});

  final Map<Nutrient, NutrientTotal> totals;

  @override
  Widget build(BuildContext context) => Material(
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Heading('Daily totals'),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 450 ? 4 : 2;
              final width =
                  (constraints.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 12,
                children: [
                  for (final nutrient in Nutrient.values)
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(nutrient.label, style: contentMetadataStyle),
                          const SizedBox(height: 3),
                          Text(
                            _totalText(nutrient, totals[nutrient]!),
                            style: contentTitleStyle,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _FoodLibrary extends StatefulWidget {
  const _FoodLibrary({required this.foods, required this.onChanged});

  final List<NutritionFood> foods;
  final ValueChanged<List<NutritionFood>> onChanged;

  @override
  State<_FoodLibrary> createState() => _FoodLibraryState();
}

class _FoodLibraryState extends State<_FoodLibrary> {
  late List<NutritionFood> _foods = widget.foods;

  Future<void> _edit([NutritionFood? food]) async {
    final edit = await _push<_RecordEdit<NutritionFood>>(
      context,
      _FoodEditor(food: food),
    );
    if (!mounted || edit == null) return;
    setState(() => _foods = _updated(_foods, edit, (food) => food.id));
    widget.onChanged(_foods);
  }

  @override
  Widget build(BuildContext context) {
    final foods = _foods.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return _NutritionScreen(
      title: 'Saved foods',
      footer: FilledButton(onPressed: _edit, child: const Text('New food')),
      children: [
        if (foods.isEmpty)
          const Text('No foods saved.', style: contentMetadataStyle),
        for (final food in foods) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(food.name, style: contentTitleStyle),
            subtitle: Text(
              'Per ${food.referenceUnit.format(food.referenceAmount)}${food.source == null ? '' : ' · ${food.source}'}',
              style: contentMetadataStyle,
            ),
            trailing: const Icon(Icons.chevron_right_rounded, color: muted),
            onTap: () => _edit(food),
          ),
          const Divider(),
        ],
      ],
    );
  }
}

class _FoodEditor extends StatefulWidget {
  const _FoodEditor({this.food});

  final NutritionFood? food;

  @override
  State<_FoodEditor> createState() => _FoodEditorState();
}

class _FoodEditorState extends State<_FoodEditor> {
  late final _name = TextEditingController(text: widget.food?.name);
  late final _amount = TextEditingController(
    text: _inputNumber(widget.food?.referenceAmount ?? 100),
  );
  late final _source = TextEditingController(text: widget.food?.source);
  late final _values = {
    for (final nutrient in Nutrient.values)
      nutrient: TextEditingController(
        text: _inputNumber(widget.food?.values[nutrient]),
      ),
  };
  late NutritionUnit _unit = widget.food?.referenceUnit ?? NutritionUnit.grams;
  late bool _estimated = widget.food?.estimated ?? false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [_name, _amount, _source, ..._values.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      final source = _source.text.trim();
      double? value(Nutrient nutrient) =>
          _numberField(_values[nutrient]!, nutrient.label, optional: true);
      final food = NutritionFood(
        id: widget.food?.id ?? newNutritionId(),
        name: _name.text.trim(),
        referenceAmount: _numberField(_amount, 'reference amount')!,
        referenceUnit: _unit,
        source: source.isEmpty ? null : source,
        estimated: _estimated,
        values: NutritionValues(
          energyKcal: value(Nutrient.energy),
          proteinGrams: value(Nutrient.protein),
          carbsGrams: value(Nutrient.carbohydrates),
          fatGrams: value(Nutrient.fat),
        ),
      );
      Navigator.pop<_RecordEdit<NutritionFood>>(context, (
        record: food,
        removed: false,
      ));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _remove(NutritionFood food) async {
    if (await _confirm(context, 'Remove saved food?') && mounted) {
      Navigator.pop<_RecordEdit<NutritionFood>>(context, (
        record: food,
        removed: true,
      ));
    }
  }

  void _changeReferenceUnit(NutritionUnit unit) => setState(() {
    final amount = _parseInput(_amount.text);
    if (amount != null && _unit.isCompatibleWith(unit)) {
      _amount.text = _inputNumber(_unit.convert(amount, unit));
    }
    _unit = unit;
    _error = null;
  });

  @override
  Widget build(BuildContext context) => _NutritionScreen(
    title: widget.food == null ? 'New food' : 'Edit food',
    error: _error,
    footer: FilledButton(onPressed: _save, child: const Text('Save food')),
    children: [
      _Input(label: 'Food name', controller: _name),
      const SizedBox(height: 15),
      const _Heading('Nutrition per quantity'),
      _QuantityEditor(
        controller: _amount,
        label: 'Reference amount',
        unit: _unit,
        units: NutritionUnit.values,
        onUnitChanged: _changeReferenceUnit,
      ),
      const SizedBox(height: 10),
      for (final nutrient in Nutrient.values) ...[
        _Input(
          label: '${nutrient.label} (${nutrient.unit})',
          controller: _values[nutrient]!,
          numeric: true,
        ),
        const SizedBox(height: 9),
      ],
      _Input(label: 'Source (optional)', controller: _source),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Estimated nutrition'),
        value: _estimated,
        onChanged: (value) => setState(() => _estimated = value),
      ),
      if (widget.food case final food?)
        _RemoveAction(
          label: 'Remove saved food',
          onPressed: () => _remove(food),
        ),
    ],
  );
}

class _MealEditor extends StatefulWidget {
  const _MealEditor({
    required this.meal,
    required this.date,
    required this.foods,
    required this.onFoodSaved,
    required this.onViewPhoto,
    required this.onReviewPhoto,
    required this.onCancelPhotoReview,
  });

  final NutritionMeal? meal;
  final DateTime date;
  final List<NutritionFood> foods;
  final ValueChanged<NutritionFood> onFoodSaved;
  final Future<void> Function(AttachmentRef)? onViewPhoto;
  final ReviewMealPhoto? onReviewPhoto;
  final VoidCallback? onCancelPhotoReview;

  @override
  State<_MealEditor> createState() => _MealEditorState();
}

class _MealEditorState extends State<_MealEditor> {
  late final _name = TextEditingController(text: widget.meal?.name);
  late final _portions = [...?widget.meal?.portions];
  late final _foods = [...widget.foods];
  late DateTime _eatenAt = widget.meal?.eatenAt.toLocal() ?? widget.date;
  String? _error;
  var _reviewingPhoto = false;

  Future<void> _reviewPhoto() async {
    final meal = widget.meal;
    final review = widget.onReviewPhoto;
    if (meal?.photo == null || review == null || _reviewingPhoto) return;
    setState(() {
      _reviewingPhoto = true;
      _error = null;
    });
    try {
      final portions = await review(context, meal!, _foods);
      if (!mounted || portions == null) return;
      setState(() {
        final existing = _portions.map((portion) => portion.food.id).toSet();
        _portions.addAll(
          portions.where((portion) => existing.add(portion.food.id)),
        );
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'The photo is saved. Suggestions could not be loaded.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewingPhoto = false);
    }
  }

  @override
  void dispose() {
    if (_reviewingPhoto) widget.onCancelPhotoReview?.call();
    _name.dispose();
    super.dispose();
  }

  Future<void> _changeDate() async {
    final date = await _pickDate(context, _eatenAt, 'Choose meal date');
    if (!mounted || date == null) return;
    setState(
      () => _eatenAt = DateTime(
        date.year,
        date.month,
        date.day,
        _eatenAt.hour,
        _eatenAt.minute,
      ),
    );
  }

  Future<void> _changeTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_eatenAt),
    );
    if (!mounted || time == null) return;
    setState(
      () => _eatenAt = DateTime(
        _eatenAt.year,
        _eatenAt.month,
        _eatenAt.day,
        time.hour,
        time.minute,
      ),
    );
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

  Future<void> _editPortion([int? index]) async {
    final portion = await showNutritionPortionEditor(
      context,
      existing: index == null ? null : _portions[index],
      foods: _foods,
      onNewFood: _newFood,
    );
    if (!mounted || portion == null) return;
    setState(() {
      if (index == null) {
        _portions.add(portion);
      } else {
        _portions[index] = portion;
      }
      _error = null;
    });
  }

  void _save() {
    try {
      final name = _name.text.trim();
      final meal = NutritionMeal(
        id: widget.meal?.id ?? newNutritionId(),
        name: name.isEmpty ? 'Meal' : name,
        eatenAt: _eatenAt,
        portions: _portions,
        photo: widget.meal?.photo,
      );
      Navigator.pop<_RecordEdit<NutritionMeal>>(context, (
        record: meal,
        removed: false,
      ));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _remove(NutritionMeal meal) async {
    if (await _confirm(context, 'Remove this meal?') && mounted) {
      Navigator.pop<_RecordEdit<NutritionMeal>>(context, (
        record: meal,
        removed: true,
      ));
    }
  }

  Future<void> _viewPhoto(AttachmentRef photo) async {
    try {
      await widget.onViewPhoto!(photo);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this photo.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final foodName = widget.meal?.draft == true ? 'Meal draft' : 'Edit meal';
    return _NutritionScreen(
      title: widget.meal == null ? 'New meal' : foodName,
      error: _error,
      footer: FilledButton(
        onPressed: _reviewingPhoto ? null : _save,
        child: const Text('Save meal'),
      ),
      children: [
        _Input(label: 'Meal name', controller: _name),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _changeDate,
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                MaterialLocalizations.of(context).formatMediumDate(_eatenAt),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _changeTime,
              icon: const Icon(Icons.access_time_rounded, size: 16),
              label: Text(_timeLabel(context, _eatenAt)),
            ),
          ],
        ),
        if (widget.meal?.photo case final photo?)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_outlined, color: accent),
            title: const Text('Meal photo attached', style: contentTitleStyle),
            onTap: widget.onViewPhoto == null ? null : () => _viewPhoto(photo),
            trailing: widget.onViewPhoto == null
                ? null
                : const Icon(Icons.chevron_right_rounded, color: muted),
          ),
        if (widget.meal?.photo != null && widget.onReviewPhoto != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _reviewingPhoto
                  ? widget.onCancelPhotoReview
                  : _reviewPhoto,
              icon: Icon(
                _reviewingPhoto
                    ? Icons.close_rounded
                    : Icons.auto_awesome_outlined,
                size: 18,
              ),
              label: Text(
                _reviewingPhoto ? 'Cancel request' : 'Suggest foods from photo',
              ),
            ),
          ),
        const SizedBox(height: 20),
        const _Heading('Foods'),
        for (final (index, portion) in _portions.indexed) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(portion.food.name, style: contentTitleStyle),
            subtitle: Text(
              '${portion.unit.format(portion.amount)}${portion.estimated || portion.minimumAmount != null ? ' · Estimated' : ''}',
              style: contentMetadataStyle,
            ),
            onTap: () => _editPortion(index),
            trailing: IconButton(
              tooltip: 'Remove ${portion.food.name} from meal',
              icon: const Icon(Icons.close_rounded, color: muted, size: 20),
              onPressed: () => setState(() => _portions.removeAt(index)),
            ),
          ),
          const Divider(),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _editPortion,
            icon: const Icon(Icons.add_rounded, size: 19),
            label: const Text('Add food'),
          ),
        ),
        if (widget.meal case final meal?)
          _RemoveAction(label: 'Remove meal', onPressed: () => _remove(meal)),
      ],
    );
  }
}

class _PortionEditor extends StatefulWidget {
  const _PortionEditor({
    required this.existing,
    required this.foods,
    required this.identifiedFood,
    required this.initialSearch,
    required this.photoRange,
    required this.onNewFood,
  });

  final NutritionPortion? existing;
  final List<NutritionFood> foods;
  final NutritionFood? identifiedFood;
  final String initialSearch;
  final ({double minimum, double maximum})? photoRange;
  final Future<NutritionFood?> Function()? onNewFood;

  @override
  State<_PortionEditor> createState() => _PortionEditorState();
}

class _PortionEditorState extends State<_PortionEditor> {
  late NutritionFood? _food =
      widget.existing?.food ??
      widget.identifiedFood ??
      (widget.onNewFood != null && widget.foods.length == 1
          ? widget.foods.single
          : null);
  late NutritionUnit _unit =
      widget.existing?.unit ?? _food?.referenceUnit ?? NutritionUnit.grams;
  late final _search = TextEditingController(text: widget.initialSearch);
  late final _amount = TextEditingController(
    text: _inputNumber(
      widget.existing?.amount ??
          (widget.onNewFood == null ? null : _food?.referenceAmount),
    ),
  );
  late final _minimum = TextEditingController(
    text: _inputNumber(widget.existing?.minimumAmount),
  );
  late final _maximum = TextEditingController(
    text: _inputNumber(widget.existing?.maximumAmount),
  );
  late bool _estimated =
      widget.existing?.estimated == true ||
      widget.existing?.minimumAmount != null;
  late String? _estimateSource = widget.existing?.estimateSource;
  late bool _choosing = _food == null;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _amount.dispose();
    _minimum.dispose();
    _maximum.dispose();
    super.dispose();
  }

  void _selectFood(NutritionFood food) => setState(() {
    if (_food != food) {
      _food = food;
      _unit = food.referenceUnit;
      final range = _unit.isCompatibleWith(NutritionUnit.grams)
          ? widget.photoRange
          : null;
      _estimated = range != null;
      _estimateSource = range == null ? null : 'Photo estimate';
      _minimum.clear();
      _maximum.clear();
      if (range != null) {
        _unit = NutritionUnit.grams;
        _minimum.text = _inputNumber(range.minimum);
        _maximum.text = _inputNumber(range.maximum);
        _amount.text = _inputNumber((range.minimum + range.maximum) / 2);
      } else {
        final fromCatalog = referenceFoodCatalog.referenceFor(food) != null;
        _amount.text = _inputNumber(
          fromCatalog || widget.onNewFood == null ? null : food.referenceAmount,
        );
      }
    }
    _choosing = false;
    _error = null;
  });

  void _useMeasure(ReferenceFood food, int measureId) {
    final portion = food.estimatedPortion(measureId);
    setState(() {
      _unit = NutritionUnit.grams;
      _amount.text = _inputNumber(portion.amount);
      _minimum.clear();
      _maximum.clear();
      _estimated = true;
      _estimateSource = portion.estimateSource;
      _error = null;
    });
  }

  void _editAmount(String _) {
    if (_estimateSource == null) return;
    setState(() {
      _estimateSource = null;
      _minimum.clear();
      _maximum.clear();
    });
  }

  void _changeUnit(NutritionUnit unit) => setState(() {
    for (final controller in [_amount, _minimum, _maximum]) {
      final value = _parseInput(controller.text);
      if (value != null) {
        controller.text = _inputNumber(_unit.convert(value, unit));
      }
    }
    _unit = unit;
    _error = null;
  });

  Future<void> _newFood() async {
    final food = await widget.onNewFood?.call();
    if (mounted && food != null) _selectFood(food);
  }

  void _save() {
    final food = _food;
    if (food == null) return;
    try {
      final portion = NutritionPortion(
        food: food,
        amount: _numberField(_amount, 'amount')!,
        unit: _unit,
        estimated: _estimated,
        minimumAmount: _estimated
            ? _numberField(_minimum, 'minimum amount', optional: true)
            : null,
        maximumAmount: _estimated
            ? _numberField(_maximum, 'maximum amount', optional: true)
            : null,
        estimateSource: _estimated ? _estimateSource : null,
      );
      Navigator.pop(context, portion);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final food = _food;
    final choosing = _choosing || food == null;
    final reference = food == null
        ? null
        : referenceFoodCatalog.referenceFor(food);
    final historical =
        food != null &&
        widget.existing?.food == food &&
        widget.foods.any((current) => current.id == food.id && current != food);
    return _NutritionScreen(
      title: widget.existing == null ? 'Add food' : 'Edit portion',
      error: _error,
      footer: choosing
          ? const SizedBox.shrink()
          : FilledButton(onPressed: _save, child: const Text('Save portion')),
      children: choosing
          ? _choices()
          : [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  historical ? '${food.name} (original)' : food.name,
                  style: contentTitleStyle,
                ),
                subtitle: Text(
                  'Per ${food.referenceUnit.format(food.referenceAmount)}'
                  '${reference != null
                      ? ' · USDA FDC ${reference.fdcId}'
                      : food.source == null
                      ? ''
                      : ' · ${food.source}'}',
                  style: contentMetadataStyle,
                ),
                trailing: const Icon(Icons.expand_more_rounded),
                onTap: () => setState(() {
                  _search.clear();
                  _choosing = true;
                }),
              ),
              _QuantityEditor(
                controller: _amount,
                label: 'Amount eaten',
                unit: _unit,
                units: NutritionUnit.values.where(
                  food.referenceUnit.isCompatibleWith,
                ),
                onUnitChanged: _changeUnit,
                onAmountChanged: _editAmount,
              ),
              if (reference != null && reference.measures.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PopupMenuButton<int>(
                    tooltip: 'Published measures',
                    onSelected: (measure) => _useMeasure(reference, measure),
                    itemBuilder: (_) => [
                      for (final measure in reference.measures)
                        PopupMenuItem(
                          value: measure.fdcPortionId,
                          child: Text(
                            '${measure.label} · ${NutritionUnit.grams.format(measure.gramWeight)}',
                          ),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Published measures'),
                    ),
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Estimated portion'),
                value: _estimated,
                onChanged: (value) => setState(() {
                  _estimated = value;
                  if (!value) _estimateSource = null;
                }),
              ),
              if (_estimated) ...[
                if (_estimateSource case final source?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(source, style: contentMetadataStyle),
                  ),
                _Input(
                  label: 'Minimum (${_unit.symbol}), optional',
                  controller: _minimum,
                  numeric: true,
                ),
                const SizedBox(height: 9),
                _Input(
                  label: 'Maximum (${_unit.symbol}), optional',
                  controller: _maximum,
                  numeric: true,
                ),
              ],
            ],
    );
  }

  List<Widget> _choices() {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final query = normalize(_search.text);
    final saved = widget.foods
        .where((food) => normalize(food.name).contains(query))
        .take(18)
        .toList();
    final references = referenceFoodCatalog.search(query, limit: 20);
    return [
      TextField(
        controller: _search,
        decoration: _decoration('Search foods')
            .copyWith(prefixIcon: const Icon(Icons.search_rounded)),
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
      ),
      if (_food != null)
        _RemoveAction(
          label: 'Keep current food',
          onPressed: () => setState(() => _choosing = false),
          destructive: false,
        ),
      if (widget.onNewFood != null)
        _RemoveAction(
          label: 'New saved food',
          onPressed: _newFood,
          destructive: false,
        ),
      if (saved.isNotEmpty) ...[
        const _Heading('Saved foods'),
        for (final food in saved) _foodOption(food),
      ],
      if (references.isNotEmpty) ...[
        const _Heading('USDA food reference'),
        for (final reference in references)
          _foodOption(reference.toNutritionFood()),
      ],
      if (saved.isEmpty && references.isEmpty)
        const Text('No foods match.', style: contentMetadataStyle),
    ];
  }

  Widget _foodOption(NutritionFood food) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(food.name, style: contentTitleStyle),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => _selectFood(food),
  );
}

class _QuantityEditor extends StatelessWidget {
  const _QuantityEditor({
    required this.controller,
    required this.label,
    required this.unit,
    required this.units,
    required this.onUnitChanged,
    this.onAmountChanged,
  });

  final TextEditingController controller;
  final String label;
  final NutritionUnit unit;
  final Iterable<NutritionUnit> units;
  final ValueChanged<NutritionUnit> onUnitChanged;
  final ValueChanged<String>? onAmountChanged;

  @override
  Widget build(BuildContext context) {
    final amount = _Input(
      label: label,
      controller: controller,
      numeric: true,
      onChanged: onAmountChanged,
    );
    final selectUnit = DropdownButtonFormField<NutritionUnit>(
      key: ValueKey(unit),
      decoration: _decoration('Unit'),
      initialValue: unit,
      isExpanded: true,
      items: [
        for (final item in units)
          DropdownMenuItem(
            value: item,
            child: Text(item.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        if (value != null) onUnitChanged(value);
      },
    );
    if (MediaQuery.textScalerOf(context).scale(14) > 19) {
      return Column(children: [amount, const SizedBox(height: 9), selectUnit]);
    }
    return Row(
      children: [
        Expanded(child: amount),
        const SizedBox(width: 9),
        Expanded(child: selectUnit),
      ],
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({
    required this.label,
    required this.controller,
    this.numeric = false,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final bool numeric;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: _decoration(label),
    onChanged: onChanged,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    textCapitalization: numeric
        ? TextCapitalization.none
        : TextCapitalization.sentences,
    textInputAction: TextInputAction.next,
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      header: true,
      child: Text(title, style: sectionHeadingStyle),
    ),
  );
}

class _RemoveAction extends StatelessWidget {
  const _RemoveAction({
    required this.label,
    required this.onPressed,
    this.destructive = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton(
      onPressed: onPressed,
      style: destructive
          ? TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            )
          : null,
      child: Text(label),
    ),
  );
}

class _NutritionScreen extends StatelessWidget {
  const _NutritionScreen({
    required this.title,
    required this.children,
    required this.footer,
    this.appBarActions = const [],
    this.error,
  });

  final String title;
  final List<Widget> children;
  final Widget footer;
  final List<Widget> appBarActions;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      actions: appBarActions,
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final controls = Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (error case final message?) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  footer,
                ],
              );
              final short =
                  constraints.maxHeight <
                  MediaQuery.textScalerOf(context).scale(155);
              final list = ListView(
                padding: const EdgeInsets.fromLTRB(20, 13, 20, 18),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  ...children,
                  if (short) ...[const SizedBox(height: 13), controls],
                ],
              );
              if (short) return list;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 13),
                    child: controls,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

List<T> _updated<T>(
  List<T> records,
  _RecordEdit<T> edit,
  String Function(T) id,
) {
  final result = records.toList();
  final index = result.indexWhere((record) => id(record) == id(edit.record));
  if (edit.removed) {
    if (index >= 0) result.removeAt(index);
  } else if (index == -1) {
    result.add(edit.record);
  } else {
    result[index] = edit.record;
  }
  return result;
}

Future<T?> _push<T>(BuildContext context, Widget child) => Navigator.of(context)
    .push<T>(
      MaterialPageRoute(
        builder: (_) => MobileModeFrame(mode: 'health', child: child),
      ),
    );

Future<DateTime?> _pickDate(
  BuildContext context,
  DateTime initial,
  String label,
) => showDatePicker(
  context: context,
  initialDate: initial,
  firstDate: DateTime(initial.year < 1900 ? initial.year : 1900),
  lastDate: DateTime(initial.year > 2200 ? initial.year : 2200, 12, 31),
  helpText: label,
);

String _timeLabel(BuildContext context, DateTime date) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

Future<bool> _confirm(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    ) ??
    false;

InputDecoration _decoration(String label) => InputDecoration(
  labelText: label,
  filled: true,
  fillColor: raisedPaper,
  enabledBorder: const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(9)),
    borderSide: BorderSide(color: line),
  ),
  border: const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(9)),
  ),
);

String _inputNumber(double? value) =>
    value?.toString().replaceFirst(RegExp(r'\.0$'), '') ?? '';

double? _parseInput(String input) {
  final value = double.tryParse(input.trim().replaceAll(',', '.'));
  return value != null && value.isFinite ? value : null;
}

double? _numberField(
  TextEditingController controller,
  String label, {
  bool optional = false,
}) {
  final text = controller.text.trim();
  if (optional && text.isEmpty) return null;
  final value = _parseInput(text);
  if (value == null) {
    throw FormatException('Enter a number for ${label.toLowerCase()}.');
  }
  return value;
}
