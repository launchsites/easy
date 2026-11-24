import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'feature_preferences.dart';

class FeaturePreferencesPage extends StatefulWidget {
  const FeaturePreferencesPage({
    required this.preferences,
    required this.onChanged,
    super.key,
  });

  final FeaturePreferences preferences;
  final Future<void> Function(FeaturePreferences) onChanged;

  @override
  State<FeaturePreferencesPage> createState() => _FeaturePreferencesPageState();
}

class _FeaturePreferencesPageState extends State<FeaturePreferencesPage> {
  late FeaturePreferences _preferences = widget.preferences;
  var _saving = false;

  Future<void> _change(FeaturePreferences next) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(next);
      if (mounted) setState(() => _preferences = next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Feature settings could not be saved.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Features'),
        actions: [
          PopupMenuButton<EasyPreset>(
            tooltip: 'Feature presets',
            enabled: !_saving,
            onSelected: (preset) => _change(_preferences.withPreset(preset)),
            icon: const Icon(Icons.tune_rounded),
            itemBuilder: (_) => [
              for (final preset in EasyPreset.values)
                PopupMenuItem(value: preset, child: Text(preset.label)),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(23, 14, 23, 28),
              children: [
                const Text(
                  'Switch features off any time. Their records stay on this device.',
                  style: contentMetadataStyle,
                ),
                const SizedBox(height: 16),
                for (final feature in EasyFeature.values)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(feature.label),
                    subtitle: Text(feature.description),
                    value: _preferences.allows(feature),
                    onChanged: _saving
                        ? null
                        : (value) =>
                              _change(_preferences.withValue(feature, value)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
