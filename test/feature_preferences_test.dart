import 'package:easy/preferences/feature_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'presets and individual toggles round trip without losing unknown features',
    () {
      final saved = FeaturePreferences.fromJson({
        'version': 1,
        'enabled': ['futureModule', 'nutrition', 'workouts'],
      });
      expect(saved.allows(EasyFeature.nutrition), isTrue);
      final minimal = saved.withPreset(EasyPreset.minimal);
      expect(minimal.enabled, isEmpty);
      final reenabled = minimal.withValue(EasyFeature.nutrition, true);
      expect(reenabled.toJson()['enabled'], ['futureModule', 'nutrition']);
      expect(FeaturePreferences.fromJson(reenabled.toJson()).enabled, {
        EasyFeature.nutrition,
      });
    },
  );
}
