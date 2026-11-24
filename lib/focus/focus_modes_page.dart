import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart';
import 'focus_mode.dart';

class FocusModesPage extends StatefulWidget {
  const FocusModesPage({
    required this.modes,
    required this.categories,
    required this.onChanged,
    super.key,
  });

  final List<FocusMode> modes;
  final Map<String, String> categories;
  final ValueChanged<List<FocusMode>> onChanged;

  @override
  State<FocusModesPage> createState() => _FocusModesPageState();
}

class _FocusModesPageState extends State<FocusModesPage> {
  late List<FocusMode> _modes = List.unmodifiable(widget.modes);

  @override
  void didUpdateWidget(covariant FocusModesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.modes != oldWidget.modes) {
      _modes = List.unmodifiable(widget.modes);
    }
  }

  Future<void> _edit([FocusMode? mode]) async {
    final change = await Navigator.of(context).push<_ModeChange>(
      MaterialPageRoute(
        builder: (context) => _ModeEditor(
          mode: mode,
          categories: Map.unmodifiable(widget.categories),
        ),
      ),
    );
    if (!mounted || change == null) return;

    final current = _modes.indexWhere((item) => item.id == change.id);
    if (mode != null && current < 0) return;

    final updated = _modes.toList();
    if (current >= 0) updated.removeAt(current);
    if (change.replacement case final replacement?) {
      updated.insert(current >= 0 ? current : updated.length, replacement);
    }
    final snapshot = List<FocusMode>.unmodifiable(updated);
    setState(() => _modes = snapshot);
    widget.onChanged(snapshot);
  }

  @override
  Widget build(BuildContext context) => _ModePage(
    title: 'Focus modes',
    action: FilledButton.icon(
      onPressed: _edit,
      icon: const Icon(Icons.add_rounded, size: 19),
      label: const Text('New mode'),
    ),
    builder: (context, padding) => ListView(
      padding: padding,
      children: [
        if (_modes.isEmpty)
          const Text('No focus modes yet.', style: contentMetadataStyle)
        else
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
                for (final (index, mode) in _modes.indexed) ...[
                  if (index > 0) const Divider(indent: 48, endIndent: 12),
                  ListTile(
                    leading: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(mode.color),
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 17),
                    ),
                    title: Text(mode.name, style: contentTitleStyle),
                    subtitle: mode.sections.isEmpty
                        ? null
                        : Text(
                            mode.sections.map((item) => item.label).join(' · '),
                            style: contentMetadataStyle,
                          ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: muted,
                      size: 19,
                    ),
                    contentPadding: const EdgeInsetsDirectional.fromSTEB(
                      16,
                      2,
                      12,
                      2,
                    ),
                    minLeadingWidth: 17,
                    minTileHeight: 57,
                    focusColor: softAccent,
                    onTap: () => _edit(mode),
                  ),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}

typedef _ModeChange = ({String id, FocusMode? replacement});

const _focusColors = <int, String>{
  0xff426651: 'Moss',
  0xff4e6c9b: 'Blue',
  0xff775d96: 'Violet',
  0xff8a6235: 'Amber',
  0xffb24f43: 'Red',
  0xff44734f: 'Fern',
  0xff4d6267: 'Slate',
  0xff884a65: 'Rose',
};

class _ModeEditor extends StatefulWidget {
  const _ModeEditor({required this.mode, required this.categories});

  final FocusMode? mode;
  final Map<String, String> categories;

  @override
  State<_ModeEditor> createState() => _ModeEditorState();
}

class _ModeEditorState extends State<_ModeEditor> {
  final _form = GlobalKey<FormState>();
  final _nameField = GlobalKey();
  late String _name = widget.mode?.name ?? '';
  late int _color = widget.mode?.color ?? accent.toARGB32();
  late bool _showAllCategories = widget.mode?.categories == null;
  late final Set<String> _categories = {...?widget.mode?.categories};
  late final Set<FocusSection> _sections = {
    ...widget.mode?.sections ?? {FocusSection.schedule, FocusSection.tasks},
  };
  late String? _preferredCategory = widget.mode?.preferredCategory;
  bool _dirty = false;

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _save() {
    if (!_form.currentState!.validate()) {
      if (_nameField.currentContext case final field?) {
        Scrollable.ensureVisible(field);
      }
      return;
    }
    final id =
        widget.mode?.id ?? 'mode-${DateTime.now().microsecondsSinceEpoch}';
    final replacement = FocusMode(
      id: id,
      name: _name.trim(),
      color: _color,
      categories: _showAllCategories ? null : _categories,
      sections: _sections,
      preferredCategory: _preferredCategory,
    );
    Navigator.pop<_ModeChange>(context, (id: id, replacement: replacement));
  }

  Future<void> _delete() async {
    final mode = widget.mode!;
    final confirmed = await _confirm(
      title: 'Delete ${mode.name}?',
      message: 'Remove this view from the mode menu.',
      action: 'Delete mode',
      destructive: true,
    );
    if (confirmed && mounted) {
      Navigator.pop<_ModeChange>(context, (id: mode.id, replacement: null));
    }
  }

  Future<bool> _confirm({
    required String title,
    required String action,
    String? message,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    final categories = {
      ...widget.categories,
      for (final category in {
        ...?widget.mode?.categories,
        ?widget.mode?.preferredCategory,
      })
        if (!widget.categories.containsKey(category)) category: category,
    };
    return PopScope<_ModeChange>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop &&
            _dirty &&
            await _confirm(title: 'Discard changes?', action: 'Discard') &&
            context.mounted) {
          Navigator.pop(context);
        }
      },
      child: _ModePage(
        title: widget.mode == null ? 'New focus mode' : 'Edit focus mode',
        action: FilledButton(onPressed: _save, child: const Text('Save mode')),
        builder: (context, padding) => Form(
          key: _form,
          child: SingleChildScrollView(
            padding: padding,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: _nameField,
                  initialValue: _name,
                  decoration: _field('Mode name'),
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a mode name.'
                      : null,
                  onChanged: (name) {
                    _name = name;
                    _markDirty();
                  },
                ),
                const SizedBox(height: 24),
                const _SectionTitle('Accent color'),
                _ColorChoices(
                  selected: _color,
                  originalColor: widget.mode?.color,
                  onChanged: (color) => setState(() {
                    _color = color;
                    _dirty = true;
                  }),
                ),
                const SizedBox(height: 24),
                const _SectionTitle('Categories shown'),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All categories', style: contentTitleStyle),
                  value: _showAllCategories,
                  onChanged: (value) => setState(() {
                    _showAllCategories = value;
                    _dirty = true;
                  }),
                ),
                if (!_showAllCategories)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final category in categories.entries)
                        _ModeFilter(
                          label: category.value,
                          selected: _categories.contains(category.key),
                          onChanged: (selected) => setState(() {
                            if (selected) {
                              _categories.add(category.key);
                            } else {
                              _categories.remove(category.key);
                            }
                            _dirty = true;
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: 23),
                const _SectionTitle('Tools'),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final section in FocusSection.values)
                      _ModeFilter(
                        label: section.label,
                        selected: _sections.contains(section),
                        onChanged: (selected) => setState(() {
                          if (selected) {
                            _sections.add(section);
                          } else {
                            _sections.remove(section);
                          }
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                const _SectionTitle('Capture'),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _preferredCategory,
                  decoration: _field('Preferred category'),
                  hint: const Text('No preference'),
                  items: [
                    const DropdownMenuItem(child: Text('No preference')),
                    for (final category in categories.entries)
                      DropdownMenuItem(
                        value: category.key,
                        child: Text(category.value),
                      ),
                  ],
                  onChanged: (category) => setState(() {
                    _preferredCategory = category;
                    _dirty = true;
                  }),
                ),
                const Padding(
                  padding: EdgeInsetsDirectional.only(start: 2, top: 6),
                  child: Text(
                    'Default category for new captures.',
                    style: contentMetadataStyle,
                  ),
                ),
                if (widget.mode != null) ...[
                  const SizedBox(height: 17),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: _delete,
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      child: const Text('Delete mode'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _field(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: muted),
    floatingLabelBehavior: FloatingLabelBehavior.always,
    filled: true,
    fillColor: raisedPaper,
    border: const OutlineInputBorder(borderRadius: _fieldRadius),
    enabledBorder: const OutlineInputBorder(
      borderRadius: _fieldRadius,
      borderSide: BorderSide(color: line),
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: _fieldRadius,
      borderSide: BorderSide(color: accent, width: 1.5),
    ),
  );
}

const _fieldRadius = BorderRadius.all(Radius.circular(11));

class _ModeFilter extends StatelessWidget {
  const _ModeFilter({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    selectedColor: softAccent,
    checkmarkColor: accent,
    shape: contentControlShape,
    side: BorderSide(color: selected ? accent.withValues(alpha: .38) : line),
    onSelected: onChanged,
  );
}

class _ColorChoices extends StatelessWidget {
  const _ColorChoices({
    required this.selected,
    required this.onChanged,
    this.originalColor,
  });

  final int selected;
  final int? originalColor;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = {
      ..._focusColors,
      if (originalColor case final color? when !_focusColors.containsKey(color))
        color: 'Custom color',
      if (!_focusColors.containsKey(selected)) selected: 'Custom color',
    };
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        for (final color in colors.entries)
          IconButton(
            tooltip: color.value,
            isSelected: color.key == selected,
            onPressed: () => onChanged(color.key),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(44),
              backgroundColor: Color(color.key),
              foregroundColor: Color(color.key).computeLuminance() > .179
                  ? Colors.black
                  : Colors.white,
            ),
            icon: const SizedBox.square(dimension: 19),
            selectedIcon: const Icon(Icons.check_rounded, size: 19),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      header: true,
      child: Text(label, style: sectionHeadingStyle),
    ),
  );
}

class _ModePage extends StatelessWidget {
  const _ModePage({
    required this.title,
    required this.action,
    required this.builder,
  });

  final String title;
  final Widget action;
  final Widget Function(BuildContext, EdgeInsetsGeometry) builder;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final inset = width < 360 ? 16.0 : (width < 720 ? 22.0 : 32.0);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        titleTextStyle: contentTitleStyle.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 2,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: builder(
                    context,
                    EdgeInsetsDirectional.fromSTEB(inset, 14, inset, 26),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(inset, 8, inset, 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: SizedBox(
                      width: width < 720 ? double.infinity : null,
                      child: action,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
