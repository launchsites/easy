import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'focus_suggestion.dart';

export 'focus_suggestion.dart';

/// The opt-in and opaque dismissals belong to this device's preferences.
class FocusSuggestionSettingsStore {
  FocusSuggestionSettingsStore(this._preferences);

  static const _key = 'easy.device.focus-suggestions.v1';
  final SharedPreferencesAsync _preferences;
  Future<void> _writes = Future.value();

  Future<FocusSuggestionPreferences> load() async {
    await _writes;
    try {
      final saved = await _preferences.getString(_key);
      if (saved == null || saved.length > 4500) {
        return FocusSuggestionPreferences();
      }
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, Object?>) return FocusSuggestionPreferences();
      return FocusSuggestionPreferences.fromJson(decoded);
    } catch (_) {
      return FocusSuggestionPreferences();
    }
  }

  Future<void> save(FocusSuggestionPreferences preferences) {
    final write = _writes.then(
      (_) => _preferences.setString(_key, jsonEncode(preferences.toJson())),
    );
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}

class FocusSuggestionAction extends StatelessWidget {
  const FocusSuggestionAction({
    required this.suggestion,
    required this.onAccept,
    required this.onDismiss,
    super.key,
  });

  final FocusSuggestion suggestion;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: TextButton.icon(
                onPressed: onAccept,
                icon: const Icon(Icons.adjust_rounded, size: 18),
                label: Text(
                  'Switch to ${suggestion.mode.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss focus suggestion',
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
