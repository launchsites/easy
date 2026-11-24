enum EasyFeature {
  planning('Day planning', 'Preview tasks in free calendar time.'),
  workouts('Workouts', 'Plan and log gym sessions.'),
  nutrition('Nutrition', 'Keep a local food and meal log.'),
  activity(
    'Activity and routines',
    'Track time and run repeatable checklists.',
  ),
  externalCalendars(
    'Apple Calendar',
    'Show calendars you choose from your device.',
  ),
  captureMedia('Media capture', 'Record voice and attach meal photos.'),
  ai('AI assistance', 'Configure an optional local model or API.');

  const EasyFeature(this.label, this.description);

  final String label;
  final String description;
}

enum EasyPreset {
  minimal('Minimal', {}),
  planner('Planner', {EasyFeature.planning, EasyFeature.activity}),
  complete('Full', {
    EasyFeature.planning,
    EasyFeature.workouts,
    EasyFeature.nutrition,
    EasyFeature.activity,
    EasyFeature.externalCalendars,
    EasyFeature.captureMedia,
    EasyFeature.ai,
  });

  const EasyPreset(this.label, this.features);

  final String label;
  final Set<EasyFeature> features;
}

class FeaturePreferences {
  FeaturePreferences({
    Iterable<EasyFeature> enabled = EasyFeature.values,
    Iterable<String> unknown = const [],
  }) : enabled = Set.unmodifiable(enabled),
       _unknown = Set.unmodifiable(unknown);

  FeaturePreferences.preset(EasyPreset preset) : this(enabled: preset.features);

  factory FeaturePreferences.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['enabled'] is! List) {
      throw const FormatException('Unsupported feature configuration.');
    }
    final names = (json['enabled'] as List).cast<String>().toSet();
    final definitions = EasyFeature.values.asNameMap();
    return FeaturePreferences(
      enabled: [for (final name in names) ?definitions[name]],
      unknown: names.where((name) => !definitions.containsKey(name)),
    );
  }

  final Set<EasyFeature> enabled;
  final Set<String> _unknown;

  bool allows(EasyFeature feature) => enabled.contains(feature);

  FeaturePreferences withValue(EasyFeature feature, bool value) =>
      FeaturePreferences(
        enabled: value ? {...enabled, feature} : enabled.difference({feature}),
        unknown: _unknown,
      );

  FeaturePreferences withPreset(EasyPreset preset) =>
      FeaturePreferences(enabled: preset.features, unknown: _unknown);

  Map<String, Object> toJson() => {
    'version': 1,
    'enabled': [...enabled.map((feature) => feature.name), ..._unknown]..sort(),
  };
}
