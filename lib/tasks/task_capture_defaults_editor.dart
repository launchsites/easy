import 'package:material_ui/material_ui.dart';

import '../categories/category_palette.dart';
import '../categories/workspace_categories.dart';
import 'task_capture_defaults.dart';

Future<TaskCaptureDefaults?> showTaskCaptureDefaultsEditor(
  BuildContext context, {
  required TaskCaptureDefaults defaults,
  WorkspaceCategories? categories,
}) {
  final catalog = categories ?? WorkspaceCategoryPalette.of(context);
  return showDialog<TaskCaptureDefaults>(
    context: context,
    builder: (_) =>
        _TaskCaptureDefaultsEditor(defaults: defaults, categories: catalog),
  );
}

class _TaskCaptureDefaultsEditor extends StatefulWidget {
  const _TaskCaptureDefaultsEditor({
    required this.defaults,
    required this.categories,
  });

  final TaskCaptureDefaults defaults;
  final WorkspaceCategories categories;

  @override
  State<_TaskCaptureDefaultsEditor> createState() =>
      _TaskCaptureDefaultsEditorState();
}

class _TaskCaptureDefaultsEditorState
    extends State<_TaskCaptureDefaultsEditor> {
  late TaskCapturePlacement _placement = widget.defaults.placement;
  late String? _categoryId = widget.defaults.categoryId;

  Future<void> _chooseCategory() async {
    final choice = await showWorkspaceCategoryPicker(
      context,
      categories: widget.categories,
      selectedId: _categoryId,
    );
    if (mounted && choice != null) setState(() => _categoryId = choice);
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.categories;
    return AlertDialog(
      title: const Text('Task capture defaults'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Place new tasks in'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              children: [
                for (final placement in const [
                  TaskCapturePlacement.inbox,
                  TaskCapturePlacement.today,
                  TaskCapturePlacement.tomorrow,
                ])
                  ChoiceChip(
                    label: Text(placement.label),
                    selected: placement == _placement,
                    onSelected: (_) => setState(() => _placement = placement),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Default category'),
              subtitle: Text(
                _categoryId == null
                    ? 'Use focus mode'
                    : categories.pathLabelFor(_categoryId),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _chooseCategory,
            ),
            if (_categoryId != null)
              TextButton(
                onPressed: () => setState(() => _categoryId = null),
                child: const Text('Use focus mode'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            TaskCaptureDefaults(placement: _placement, categoryId: _categoryId),
          ),
          child: const Text('Save defaults'),
        ),
      ],
    );
  }
}
