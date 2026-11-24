import 'package:material_ui/material_ui.dart';

import 'workspace_categories.dart';

class WorkspaceCategoryPalette extends InheritedWidget {
  const WorkspaceCategoryPalette({
    required this.categories,
    required super.child,
    super.key,
  });

  final WorkspaceCategories categories;

  static final _defaultCategories = WorkspaceCategories.defaults();

  static WorkspaceCategories? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WorkspaceCategoryPalette>()
      ?.categories;

  static WorkspaceCategories of(BuildContext context) =>
      maybeOf(context) ?? _defaultCategories;

  static String labelFor(BuildContext context, String? id) =>
      of(context).labelFor(id);

  static Color colorFor(BuildContext context, String? id) =>
      workspaceCategoryColor(context, of(context), id);

  @override
  bool updateShouldNotify(WorkspaceCategoryPalette oldWidget) =>
      categories != oldWidget.categories;
}

Color workspaceCategoryColor(
  BuildContext context,
  WorkspaceCategories categories,
  String? id,
) => switch (categories.colorArgbFor(id)) {
  final int color => Color(color),
  _ => Theme.of(context).colorScheme.primary,
};

class WorkspaceCategoryField extends StatelessWidget {
  const WorkspaceCategoryField({
    required this.value,
    required this.onChanged,
    this.categories,
    this.allowGeneral = true,
    super.key,
  });

  final String? value;
  final ValueChanged<String> onChanged;
  final WorkspaceCategories? categories;
  final bool allowGeneral;

  @override
  Widget build(BuildContext context) {
    final catalog = categories ?? WorkspaceCategoryPalette.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Category'),
      subtitle: Text(catalog.pathLabelFor(value)),
      leading: WorkspaceCategoryDot(
        color: workspaceCategoryColor(context, catalog, value),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final id = await showWorkspaceCategoryPicker(
          context,
          categories: catalog,
          selectedId: value,
          allowGeneral: allowGeneral,
        );
        if (context.mounted && id != null) onChanged(id);
      },
    );
  }
}

/// A selected empty ID means General. Dismissing the picker returns null.
Future<String?> showWorkspaceCategoryPicker(
  BuildContext context, {
  WorkspaceCategories? categories,
  String? selectedId,
  bool allowGeneral = true,
}) {
  final catalog = categories ?? WorkspaceCategoryPalette.of(context);
  return showDialog<String>(
    context: context,
    builder: (_) => _WorkspaceCategoryPicker(
      categories: catalog,
      selectedId: selectedId,
      allowGeneral: allowGeneral,
    ),
  );
}

class _WorkspaceCategoryPicker extends StatefulWidget {
  const _WorkspaceCategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.allowGeneral,
  });

  final WorkspaceCategories categories;
  final String? selectedId;
  final bool allowGeneral;

  @override
  State<_WorkspaceCategoryPicker> createState() =>
      _WorkspaceCategoryPickerState();
}

class _WorkspaceCategoryPickerState extends State<_WorkspaceCategoryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final catalog = widget.categories;
    final currentId = catalog.canonicalId(widget.selectedId);
    final current = catalog.resolve(currentId);
    final rows = catalog.rows();
    final generalVisible = widget.allowGeneral && 'general'.contains(_query);
    final visible = [
      for (final row in rows)
        if (catalog
            .pathLabelFor(row.category.id)
            .toLowerCase()
            .contains(_query))
          row,
    ];
    return AlertDialog(
      title: const Text('Choose category'),
      scrollable: true,
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 10, 16, 3),
      content: SizedBox(
        width: 350,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rows.length > 8)
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Find a category',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (text) =>
                    setState(() => _query = text.trim().toLowerCase()),
              ),
            if (generalVisible)
              _option(
                context,
                '',
                'General',
                selected: currentId == null || currentId.isEmpty,
              ),
            if (current?.archived == true && _query.isEmpty)
              _option(
                context,
                current!.id,
                current.label,
                selected: true,
                subtitle: 'Archived',
              ),
            if (currentId != null &&
                currentId.isNotEmpty &&
                current == null &&
                _query.isEmpty)
              _option(
                context,
                currentId,
                catalog.labelFor(currentId),
                selected: true,
              ),
            for (final row in visible)
              _option(
                context,
                row.category.id,
                row.category.label,
                depth: row.depth,
                selected: currentId == row.category.id,
                subtitle: row.depth > 0
                    ? catalog.pathLabelFor(row.category.parentId)
                    : null,
              ),
            if (visible.isEmpty && _query.isNotEmpty && !generalVisible)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No matching categories.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _option(
    BuildContext context,
    String id,
    String label, {
    required bool selected,
    int depth = 0,
    String? subtitle,
  }) => Semantics(
    selected: selected,
    child: ListTile(
      contentPadding: EdgeInsetsDirectional.only(
        start: 4.0 + depth * 7,
        end: 4,
      ),
      leading: WorkspaceCategoryDot(
        color: workspaceCategoryColor(context, widget.categories, id),
      ),
      title: Text(label),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.pop(context, id),
    ),
  );
}

class WorkspaceCategoryDot extends StatelessWidget {
  const WorkspaceCategoryDot({required this.color, this.size = 11, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}
