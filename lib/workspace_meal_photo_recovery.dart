part of 'main.dart';

extension _WorkspaceMealPhotoRecovery on _WorkspaceState {
  bool get _canRecoverMealPhoto =>
      mounted &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _allows(EasyFeature.nutrition) &&
      _allows(EasyFeature.captureMedia);

  Future<void> _recoverMealPhoto() {
    if (!_canRecoverMealPhoto) return Future.value();
    return _mealPhotoRecoveryRun ??= _restoreMealPhoto().whenComplete(() {
      _mealPhotoRecoveryRun = null;
    });
  }

  Future<void> _restoreMealPhoto() async {
    final recovery = _mealPhotoRecovery ??= AndroidMealPhotoRecovery(
      openAttachments: _openAttachments,
      commitDraft: _saveRecoveredMealPhoto,
    );
    try {
      final meal = await recovery.recover();
      if (!mounted) return;
      if (meal != null && _canRecoverMealPhoto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Meal photo recovered.'),
            action: SnackBarAction(
              label: 'Review',
              onPressed: () => _openNutrition(day: meal.eatenAt.toLocal()),
            ),
          ),
        );
      }
    } on Object {
      if (mounted && _canRecoverMealPhoto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'The previous meal photo could not be recovered.',
            ),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: _recoverMealPhoto,
            ),
          ),
        );
      }
    }
  }

  Future<bool> _saveRecoveredMealPhoto(NutritionMeal meal) async {
    if (!_canRecoverMealPhoto) throw StateError('The meal log is unavailable.');
    final workspace = _data;
    final nutrition = _nutritionData();
    final existing = nutrition.meals
        .where((item) => item.id == meal.id)
        .firstOrNull;
    if (existing != null) {
      if (existing.photo?.id != meal.photo?.id) {
        throw StateError('The recovered draft changed.');
      }
      return false;
    }
    final changed = nutrition.copyWith(meals: [...nutrition.meals, meal]);
    await _commitReviewedData(
      workspace,
      workspace.withSection(_nutritionKey, changed.toJson()),
      operationId: meal.id,
    );
    return true;
  }
}
