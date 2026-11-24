import 'package:material_ui/material_ui.dart';

import 'ui_theme.dart';

@immutable
class SettingsSection {
  SettingsSection({required this.title, required Iterable<SettingsItem> items})
    : items = List.unmodifiable(items);

  final String title;
  final List<SettingsItem> items;
}

@immutable
class SettingsItem {
  const SettingsItem({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    required VoidCallback this.onTap,
  }) : selected = null,
       onChanged = null;

  const SettingsItem.toggle({
    required this.icon,
    required this.title,
    this.subtitle,
    required bool this.selected,
    required ValueChanged<bool> this.onChanged,
  }) : value = null,
       onTap = null;

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final bool? selected;
  final ValueChanged<bool>? onChanged;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.sections, super.key});

  final List<SettingsSection> sections;

  @override
  Widget build(BuildContext context) {
    final shownSections = sections.where((section) => section.items.isNotEmpty);
    final canGoBack = Navigator.canPop(context);
    return Scaffold(
      backgroundColor: paper,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 360;
            final wide = constraints.maxWidth >= 720;
            final gutter = compact ? 16.0 : (wide ? 32.0 : 24.0);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        canGoBack ? gutter - 8 : gutter,
                        wide ? 18 : 7,
                        gutter,
                        wide ? 14 : 10,
                      ),
                      child: Row(
                        children: [
                          if (canGoBack) ...[
                            const BackButton(),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                'Settings',
                                style: workspaceHeadingStyle(true).copyWith(
                                  fontSize: wide ? 32 : 25,
                                  letterSpacing: wide ? -1.3 : -.8,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        key: const PageStorageKey('settings'),
                        padding: EdgeInsetsDirectional.fromSTEB(
                          gutter,
                          12,
                          gutter,
                          30,
                        ),
                        children: [
                          for (final (index, section)
                              in shownSections.indexed) ...[
                            if (index > 0) const SizedBox(height: 25),
                            _SettingsGroup(section: section),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 2, bottom: 10),
        child: Semantics(
          header: true,
          child: Text(section.title, style: sectionHeadingStyle),
        ),
      ),
      Material(
        color: raisedPaper,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: contentSurfaceRadius,
          side: BorderSide(color: line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (index, item) in section.items.indexed) ...[
              if (index > 0) const Divider(indent: 57, endIndent: 13),
              _SettingsRow(item: item),
            ],
          ],
        ),
      ),
    ],
  );
}

class _SettingsRow extends StatefulWidget {
  const _SettingsRow({required this.item});

  final SettingsItem item;

  @override
  State<_SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<_SettingsRow> {
  static const _insets = EdgeInsetsDirectional.fromSTEB(13, 4, 12, 4);
  bool _focused = false;

  void _focusChanged(bool focused) => setState(() => _focused = focused);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final leading = Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        color: softAccent,
        borderRadius: BorderRadius.all(Radius.circular(9)),
      ),
      child: Icon(item.icon, color: accent, size: 17),
    );
    final title = Text(item.title, style: contentTitleStyle);
    final subtitle = item.subtitle?.trim();
    final value = item.value?.trim();

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(
            color: _focused ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: switch (item.selected) {
        final selected? => SwitchListTile.adaptive(
          value: selected,
          onChanged: item.onChanged,
          secondary: leading,
          title: title,
          subtitle: subtitle == null || subtitle.isEmpty
              ? null
              : Text(subtitle, style: contentMetadataStyle),
          contentPadding: _insets,
          minTileHeight: 60,
          horizontalTitleGap: 10,
          controlAffinity: ListTileControlAffinity.trailing,
          onFocusChange: _focusChanged,
        ),
        null => LayoutBuilder(
          builder: (context, constraints) {
            final hasValue = value != null && value.isNotEmpty;
            final trailingValue =
                hasValue &&
                value.length <= 32 &&
                constraints.maxWidth >= 440 &&
                MediaQuery.textScalerOf(context).scale(13) <= 17;
            final valueText = hasValue
                ? Text(
                    value,
                    style: contentMetadataStyle.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null;
            final supportingText = [
              if (subtitle != null && subtitle.isNotEmpty)
                Text(subtitle, style: contentMetadataStyle),
              if (valueText != null && !trailingValue) valueText,
            ];
            return ListTile(
              leading: leading,
              title: title,
              subtitle: supportingText.isEmpty
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 2,
                      children: supportingText,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (trailingValue) ...[
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .36,
                      ),
                      child: valueText,
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: muted,
                    size: 19,
                  ),
                ],
              ),
              contentPadding: _insets,
              minTileHeight: 60,
              horizontalTitleGap: 10,
              onTap: item.onTap,
              onFocusChange: _focusChanged,
              focusColor: softAccent,
            );
          },
        ),
      },
    );
  }
}
