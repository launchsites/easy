import 'package:material_ui/material_ui.dart';

import 'category_palette.dart';
import 'workspace_categories.dart';

class WorkspaceCategoriesPage extends StatefulWidget {
  const WorkspaceCategoriesPage({
    required this.categories,
    required this.onChanged,
    super.key,
  });

  final WorkspaceCategories categories;
  final ValueChanged<WorkspaceCategories> onChanged;

  @override
  State<WorkspaceCategoriesPage> createState() =>
      _WorkspaceCategoriesPageState();
}

enum _CategoryAction { subcategory, archive, restore }

class _WorkspaceCategoriesPageState extends State<WorkspaceCategoriesPage> {
  late WorkspaceCategories _catalog = widget.categories;
  bool _showArchived = false;

  @override
  void didUpdateWidget(covariant WorkspaceCategoriesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.categories != oldWidget.categories) _catalog = widget.categories;
  }

  void _apply(WorkspaceCategories catalog) {
    if (!mounted || identical(_catalog, catalog)) return;
    setState(() => _catalog = catalog);
    widget.onChanged(catalog);
  }

  Future<void> _edit({WorkspaceCategory? category, String? parentId}) async {
    final result = await showDialog<WorkspaceCategory>(
      context: context,
      builder: (_) => _CategoryEditor(
        catalog: _catalog,
        category: category,
        parentId: parentId,
      ),
    );
    if (!mounted || result == null) return;
    try {
      _apply(_catalog.withCategory(result));
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  void _archive(WorkspaceCategory category, {required bool archived}) {
    _apply(_catalog.withArchived(category.id, archived: archived));
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(archived ? 'Category archived' : 'Category restored'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                _apply(_catalog.withArchived(category.id, archived: !archived)),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _catalog.rows(includeArchived: _showArchived);
    final hasArchived = _catalog.categories.any(
      (category) => category.archived,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: TextButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New category'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: ListView.builder(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 28),
              itemCount: rows.length + (hasArchived ? 1 : 0),
              itemBuilder: (context, index) {
                if (hasArchived && index == 0) {
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () =>
                          setState(() => _showArchived = !_showArchived),
                      child: Text(
                        _showArchived ? 'Hide archived' : 'Show archived',
                      ),
                    ),
                  );
                }
                return _row(context, rows[index - (hasArchived ? 1 : 0)]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, WorkspaceCategoryRow row) {
    final category = row.category;
    final ancestors = _catalog.pathFor(category.id).take(row.depth);
    final hiddenParent =
        !_showArchived && ancestors.any((node) => node.archived);
    final subtitle = category.archived
        ? 'Archived'
        : hiddenParent
        ? _catalog.pathLabelFor(category.parentId)
        : null;
    return ListTile(
      key: ValueKey(category.id),
      contentPadding: EdgeInsetsDirectional.only(
        start: row.depth * 12.0,
        end: 3,
      ),
      leading: WorkspaceCategoryDot(color: Color(category.colorArgb)),
      title: Text(category.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => _edit(category: category),
      trailing: PopupMenuButton<_CategoryAction>(
        tooltip: 'Options for ${category.label}',
        icon: const Icon(Icons.more_horiz_rounded),
        onSelected: (action) {
          switch (action) {
            case _CategoryAction.subcategory:
              _edit(parentId: category.id);
            case _CategoryAction.archive:
              _archive(category, archived: true);
            case _CategoryAction.restore:
              _archive(category, archived: false);
          }
        },
        itemBuilder: (_) => [
          if (!category.archived &&
              row.depth + 1 < WorkspaceCategories.maxDepth)
            const PopupMenuItem(
              value: _CategoryAction.subcategory,
              child: Text('Add subcategory'),
            ),
          if (category.archived)
            const PopupMenuItem(
              value: _CategoryAction.restore,
              child: Text('Restore category'),
            )
          else
            const PopupMenuItem(
              value: _CategoryAction.archive,
              child: Text('Archive category'),
            ),
        ],
      ),
    );
  }
}

const _swatches = <int, String>{
  0xff4e6c9b: 'Blue',
  0xff775d96: 'Violet',
  0xff975b4b: 'Terracotta',
  0xff8a6235: 'Ochre',
  0xff44734f: 'Green',
  0xff545e63: 'Graphite',
};

class _CategoryEditor extends StatefulWidget {
  const _CategoryEditor({required this.catalog, this.category, this.parentId});

  final WorkspaceCategories catalog;
  final WorkspaceCategory? category;
  final String? parentId;

  @override
  State<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<_CategoryEditor> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.category?.label);
  late final _color = TextEditingController(
    text: _hex(widget.category?.colorArgb ?? defaultWorkspaceCategoryColor),
  );
  late String? _parentId = widget.category?.parentId ?? widget.parentId;
  late final String _id = widget.category?.id ?? newWorkspaceCategoryId();
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _color.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final category = WorkspaceCategory(
      id: _id,
      label: _label.text,
      colorArgb: _parseColor(_color.text)!,
      parentId: _parentId,
      aliases: widget.category?.aliases ?? const [],
      archived: widget.category?.archived ?? false,
    );
    try {
      widget.catalog.withCategory(category);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.pop(context, category);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final candidate = _parseColor(_color.text);
    final parents = [
      for (final row in widget.catalog.rows(includeArchived: true))
        if (row.category.id == _parentId ||
            (!row.category.archived &&
                row.depth + 1 < WorkspaceCategories.maxDepth &&
                !widget.catalog
                    .pathFor(row.category.id)
                    .any((node) => node.id == _id)))
          row.category,
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.category != null
            ? 'Edit category'
            : widget.parentId != null
            ? 'New subcategory'
            : 'New category',
      ),
      content: SizedBox(
        width: 350,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextFormField(
                controller: _label,
                autofocus: widget.category == null,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                maxLength: WorkspaceCategory.maxLabelLength,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  counterText: '',
                ),
                validator: (value) => WorkspaceCategory.validLabel(value ?? '')
                    ? null
                    : 'Enter a category name.',
              ),
              DropdownButtonFormField<String>(
                initialValue: _parentId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Parent category'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('None')),
                  for (final category in parents)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(
                        widget.catalog.pathLabelFor(category.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _parentId = value == '' ? null : value;
                  _error = null;
                }),
              ),
              Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final swatch in _swatches.entries)
                    _swatch(
                      swatch.key,
                      swatch.value,
                      selected: candidate == swatch.key,
                    ),
                ],
              ),
              TextFormField(
                controller: _color,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Hex color',
                  hintText: '#426651',
                  suffixIcon: candidate == null
                      ? null
                      : Center(
                          widthFactor: 2,
                          child: WorkspaceCategoryDot(
                            color: Color(candidate),
                            size: 15,
                          ),
                        ),
                ),
                validator: (value) => _parseColor(value ?? '') == null
                    ? 'Enter a six-digit hex color.'
                    : null,
                onChanged: (_) => setState(() {}),
                onFieldSubmitted: (_) => _save(),
              ),
              if (_error case final error?)
                Semantics(
                  liveRegion: true,
                  child: Text(error, style: TextStyle(color: colors.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save category')),
      ],
    );
  }

  Widget _swatch(int argb, String label, {required bool selected}) {
    final color = Color(argb);
    return Semantics(
      selected: selected,
      child: IconButton(
        tooltip: label,
        onPressed: () => setState(() => _color.text = _hex(argb)),
        icon: SizedBox.square(
          dimension: 23,
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: selected
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 16)
                : null,
          ),
        ),
      ),
    );
  }
}

final _hexColor = RegExp(r'^#?[0-9a-fA-F]{6}$');

int? _parseColor(String text) {
  final value = text.trim();
  if (!_hexColor.hasMatch(value)) return null;
  return 0xff000000 | int.parse(value.replaceFirst('#', ''), radix: 16);
}

String _hex(int color) =>
    '#${color.toRadixString(16).substring(2).toUpperCase()}';
