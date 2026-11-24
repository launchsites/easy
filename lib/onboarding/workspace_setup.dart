import 'package:material_ui/material_ui.dart';

import '../appearance/appearance.dart';
import '../focus/focus_mode.dart';
import '../preferences/feature_preferences.dart';
import '../ui_theme.dart';

enum WorkspaceStartingContent { empty, samples }

/// A setup result. The caller owns local persistence and first-run detection.
class WorkspaceSetupChoice {
  const WorkspaceSetupChoice({required this.preset, required this.content});

  static const skipped = WorkspaceSetupChoice(
    preset: EasyPreset.minimal,
    content: WorkspaceStartingContent.empty,
  );

  final EasyPreset preset;
  final WorkspaceStartingContent content;

  FeaturePreferences get preferences => FeaturePreferences.preset(preset);

  List<FocusMode> get focusModes => List.unmodifiable(standardFocusModes());
}

class WorkspaceSetupPage extends StatefulWidget {
  const WorkspaceSetupPage({
    required this.appName,
    required this.onChosen,
    this.initialPreset = EasyPreset.minimal,
    super.key,
  });

  final String appName;
  final EasyPreset initialPreset;
  final Future<void> Function(WorkspaceSetupChoice) onChosen;

  @override
  State<WorkspaceSetupPage> createState() => _WorkspaceSetupPageState();
}

class _WorkspaceSetupPageState extends State<WorkspaceSetupPage> {
  late EasyPreset _preset = widget.initialPreset;
  bool _opening = false;
  bool _failed = false;

  Future<void> _choose(WorkspaceSetupChoice choice) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _failed = false;
    });
    try {
      await widget.onChosen(choice);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _start(WorkspaceStartingContent content) =>
      _choose(WorkspaceSetupChoice(preset: _preset, content: content));

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, viewport) {
          final wide = viewport.maxWidth >= 760;
          return ColoredBox(
            color: wide
                ? WorkspaceChrome.of(context).background
                : colors.surface,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  key: const ValueKey('workspace-setup-scroll'),
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 40 : 19,
                    vertical: wide ? 36 : 9,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 590),
                    child: Material(
                      color: colors.surface,
                      elevation: wide ? 12 : 0,
                      shadowColor: Colors.black38,
                      shape: wide
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26),
                              side: BorderSide(color: colors.outlineVariant),
                            )
                          : null,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 34 : 0,
                          wide ? 20 : 0,
                          wide ? 34 : 0,
                          wide ? 33 : 18,
                        ),
                        child: _content(context, wide: wide),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: _opening
                ? null
                : () => _choose(WorkspaceSetupChoice.skipped),
            style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
            child: const Text('Skip', semanticsLabel: 'Skip setup'),
          ),
        ),
        Semantics(
          header: true,
          child: Text(
            'Set up ${widget.appName}',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: colors.onSurface,
              fontSize: wide ? 42 : 36,
              letterSpacing: -1.8,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          'Your workspace starts on this device.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        RadioGroup<EasyPreset>(
          groupValue: _preset,
          onChanged: (preset) {
            if (preset == null || _opening) return;
            setState(() => _preset = preset);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (final preset in EasyPreset.values)
                _PresetTile(
                  preset: preset,
                  selected: preset == _preset,
                  enabled: !_opening,
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _actions(wide: wide),
        if (_opening) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(semanticsLabel: 'Opening workspace'),
        ],
        if (_failed) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              'Setup could not be saved. Try again.',
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ),
        ],
      ],
    );
  }

  Widget _actions({required bool wide}) {
    final actions = [
      FilledButton(
        onPressed: _opening
            ? null
            : () => _start(WorkspaceStartingContent.empty),
        child: const Text('Use my workspace', textAlign: TextAlign.center),
      ),
      OutlinedButton(
        onPressed: _opening
            ? null
            : () => _start(WorkspaceStartingContent.samples),
        child: const Text('Explore with samples', textAlign: TextAlign.center),
      ),
    ];
    return wide
        ? Wrap(spacing: 10, runSpacing: 10, children: actions)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: actions,
          );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.enabled,
  });

  final EasyPreset preset;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, description) = switch (preset) {
      EasyPreset.minimal => (
        Icons.dashboard_outlined,
        'Calendar, tasks and notes',
      ),
      EasyPreset.planner => (
        Icons.calendar_month_outlined,
        'Adds planning, activity and reviews',
      ),
      EasyPreset.complete => (
        Icons.layers_outlined,
        'Adds workouts, nutrition, health and optional AI tools',
      ),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: contentSurfaceRadius,
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
      ),
    );
    final showIcon = MediaQuery.textScalerOf(context).scale(15) < 24;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: RadioListTile<EasyPreset>(
        value: preset,
        enabled: enabled,
        controlAffinity: ListTileControlAffinity.trailing,
        contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 6, 8, 6),
        minTileHeight: 68,
        horizontalTitleGap: 10,
        minLeadingWidth: 32,
        secondary: showIcon
            ? Icon(icon, color: colors.primary, size: 22)
            : null,
        title: Text(
          preset.label,
          style: theme.textTheme.titleMedium?.copyWith(
            color: selected ? colors.onPrimaryContainer : colors.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          description,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected
                ? colors.onPrimaryContainer
                : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
