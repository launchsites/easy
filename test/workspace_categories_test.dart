import 'dart:convert';

import 'package:easy/categories/category_palette.dart';
import 'package:easy/categories/workspace_categories.dart';
import 'package:easy/categories/workspace_categories_page.dart';
import 'package:easy/ui_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('legacy record references survive rename, reparent, and archive', () {
    final catalog =
        WorkspaceCategories.defaults(
          legacyIds: ['Work', 'side project', 'SIDE PROJECT', '', 'Other'],
        ).withCategory(
          _category(
            'reports',
            'Reports',
            parent: 'work',
            aliases: ['legacy-reports'],
          ),
        );
    expect(catalog.resolve(' WORK ')?.id, 'work');
    expect(catalog.resolve('SIDE PROJECT')?.id, 'side project');
    expect(catalog.labelFor(''), 'General');
    expect(catalog.labelFor('side project'), 'Side project');
    expect(catalog.pathLabelFor('legacy-reports'), 'Work / Reports');
    expect(catalog.matches('legacy-reports', ['work', 'gym']), true);

    final report = catalog.resolve('reports')!;
    final changed = catalog
        .withCategory(
          report.copyWith(label: 'Client reports', parentId: 'side project'),
        )
        .withArchived('side project');
    expect(changed.labelFor('legacy-reports'), 'Client reports');
    expect(changed.pathLabelFor('reports'), 'Side project / Client reports');
    expect(changed.labels(), isNot(contains('side project')));
    expect(changed.labels(), containsPair('reports', 'Client reports'));
    expect(changed.labels(includeArchived: true), contains('side project'));
    expect(changed.matches('legacy-reports', ['side project', 'gym']), true);
    expect(changed.matches('legacy-reports', ['work']), false);
    expect(catalog.pathLabelFor('reports'), 'Work / Reports');
    expect(
      changed.rows().firstWhere((row) => row.category.id == 'reports').depth,
      1,
    );

    final decoded = WorkspaceCategories.fromJson(
      jsonDecode(jsonEncode(changed.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.toJson(), changed.toJson());
    expect(decoded.resolve('legacy-reports')?.id, 'reports');
    expect(decoded.resolve('side project')?.archived, true);
    expect(() => decoded.categories.clear(), throwsUnsupportedError);
    expect(
      () => decoded.resolve('reports')!.aliases.clear(),
      throwsUnsupportedError,
    );
    expect(
      decoded
          .withArchived('side project', archived: false)
          .resolve('side project')
          ?.archived,
      false,
    );
  });

  test(
    'missing parents, cycles, excess depth, and alias collisions fail closed',
    () {
      final catalog = WorkspaceCategories([
        _category('root', 'Root'),
        _category('child', 'Child', parent: 'root', aliases: ['Old-Child']),
        _category('third', 'Third', parent: 'child'),
        _category('fourth', 'Fourth', parent: 'third'),
        _category('fifth', 'Fifth', parent: 'fourth'),
      ]);
      final root = catalog.resolve('root')!;
      expect(
        () => catalog.withCategory(root.copyWith(parentId: 'root')),
        throwsFormatException,
      );
      expect(
        () => catalog.withCategory(root.copyWith(parentId: 'child')),
        throwsFormatException,
      );
      expect(
        () => catalog.withCategory(root.copyWith(parentId: 'missing')),
        throwsFormatException,
      );
      expect(
        () => catalog.withCategory(_category('deep', 'Deep', parent: 'fifth')),
        throwsFormatException,
      );
      expect(
        () => catalog.withCategory(_category('old-child', 'Duplicate')),
        throwsFormatException,
      );
      expect(
        () => WorkspaceCategory(
          id: 'invalid',
          label: 'Invalid',
          colorArgb: 0x00446688,
        ),
        throwsFormatException,
      );
      expect(catalog.resolve('root')!.parentId, isNull);
      expect(catalog.pathFor('fifth'), hasLength(5));
      expect(
        catalog
            .withCategory(catalog.resolve('fifth')!.copyWith(parentId: null))
            .pathFor('fifth'),
        hasLength(1),
      );
      expect(
        () => WorkspaceCategories.fromJson({
          'version': 1,
          'categories': [_category('x', 'X', parent: 'y').toJson()],
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'adds, colors, moves, and archives a subcategory on a 320px phone',
    (tester) async {
      _phone(tester);
      var catalog = WorkspaceCategories.defaults();
      await tester.pumpWidget(
        MaterialApp(
          theme: easyTheme(),
          home: WorkspaceCategoriesPage(
            categories: catalog,
            onChanged: (value) => catalog = value,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Options for Work'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Add subcategory');
      await _enter(tester, 'Name', 'Invoices');
      await _enter(tester, 'Hex color', '#346C72');
      await _tap(tester, 'Save category');
      final id = catalog.categories
          .singleWhere((category) => category.label == 'Invoices')
          .id;
      expect(catalog.resolve(id)?.parentId, 'work');
      expect(catalog.colorArgbFor(id), 0xff346c72);

      await _tap(tester, 'Invoices');
      await _enter(tester, 'Name', 'Bills');
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      final personal = find
          .widgetWithText(DropdownMenuItem<String>, 'Personal')
          .last;
      await tester.tap(personal);
      await tester.pumpAndSettle();
      await _tap(tester, 'Save category');
      expect(catalog.resolve(id)?.label, 'Bills');
      expect(catalog.resolve(id)?.parentId, 'personal');

      await tester.tap(find.byTooltip('Options for Bills'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Archive category');
      expect(catalog.resolve(id)?.archived, true);
      expect(find.text('Bills'), findsNothing);
      await _tap(tester, 'Show archived');
      expect(find.text('Bills'), findsOneWidget);
      await tester.tap(find.byTooltip('Options for Bills'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Restore category');
      expect(catalog.pathLabelFor(id), 'Personal / Bills');
      expect(catalog.resolve(id)?.archived, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the single category field shows hierarchy and returns stable IDs',
    (tester) async {
      _phone(tester);
      final catalog = WorkspaceCategories([
        _category('work', 'Work'),
        _category(
          'reports',
          'Reports',
          parent: 'work',
          aliases: ['legacy-reports'],
        ),
        _category('hidden', 'Old invoices').copyWith(archived: true),
      ]);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceCategoryPalette(
            categories: catalog,
            child: Scaffold(
              body: WorkspaceCategoryField(
                value: 'legacy-reports',
                onChanged: (id) => selected = id,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Work / Reports'), findsOneWidget);
      await _tap(tester, 'Category');
      expect(find.text('Old invoices'), findsNothing);
      expect(find.text('Reports'), findsOneWidget);
      await _tap(tester, 'Reports');
      expect(selected, 'reports');
      await _tap(tester, 'Category');
      await _tap(tester, 'General');
      expect(selected, '');
    },
  );
}

WorkspaceCategory _category(
  String id,
  String label, {
  String? parent,
  List<String> aliases = const [],
}) => WorkspaceCategory(
  id: id,
  label: label,
  colorArgb: 0xff426651,
  parentId: parent,
  aliases: aliases,
);

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 625);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _tap(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final finder = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}
