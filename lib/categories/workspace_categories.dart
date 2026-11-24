import 'dart:math';

const _unchanged = Object();
const _generalLabel = 'General';
const defaultWorkspaceCategoryColor = 0xff426651;
final _invalidText = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]');

final class WorkspaceCategory {
  WorkspaceCategory({
    required this.id,
    required String label,
    required this.colorArgb,
    this.parentId,
    Iterable<String> aliases = const [],
    this.archived = false,
  }) : label = label.trim(),
       aliases = List.unmodifiable(aliases.toSet()) {
    if (!_validReference(id) ||
        this.aliases.any((alias) => !_validReference(alias))) {
      throw const FormatException('Use a valid category reference.');
    }
    if (!validLabel(this.label)) {
      throw const FormatException('Enter a category name of 1–80 characters.');
    }
    if (colorArgb < 0xff000000 || colorArgb > 0xffffffff) {
      throw const FormatException('Choose an opaque category color.');
    }
  }

  factory WorkspaceCategory.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final label = json['label'];
    final color = json['colorArgb'];
    final parent = json['parentId'];
    final aliases = json['aliases'] ?? const <String>[];
    final archived = json['archived'] ?? false;
    if (id is! String ||
        label is! String ||
        color is! int ||
        (parent != null && parent is! String) ||
        aliases is! List ||
        aliases.any((alias) => alias is! String) ||
        archived is! bool) {
      throw const FormatException('Invalid category fields.');
    }
    return WorkspaceCategory(
      id: id,
      label: label,
      colorArgb: color,
      parentId: parent as String?,
      aliases: aliases.cast<String>(),
      archived: archived,
    );
  }

  static const maxLabelLength = 80;

  static bool validLabel(String source) {
    final label = source.trim();
    return label.isNotEmpty &&
        label.runes.length <= maxLabelLength &&
        !_invalidText.hasMatch(label);
  }

  final String id;
  final String label;
  final int colorArgb;
  final String? parentId;
  final List<String> aliases;
  final bool archived;

  WorkspaceCategory copyWith({
    String? label,
    int? colorArgb,
    Object? parentId = _unchanged,
    Iterable<String>? aliases,
    bool? archived,
  }) => WorkspaceCategory(
    id: id,
    label: label ?? this.label,
    colorArgb: colorArgb ?? this.colorArgb,
    parentId: identical(parentId, _unchanged)
        ? this.parentId
        : parentId as String?,
    aliases: aliases ?? this.aliases,
    archived: archived ?? this.archived,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'colorArgb': colorArgb,
    'parentId': ?parentId,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (archived) 'archived': true,
  };
}

typedef WorkspaceCategoryRow = ({WorkspaceCategory category, int depth});

/// Record assignments keep their stable references when the tree changes.
final class WorkspaceCategories {
  WorkspaceCategories(Iterable<WorkspaceCategory> categories)
    : categories = List.unmodifiable(categories) {
    final byId = <String, WorkspaceCategory>{};
    final byReference = <String, WorkspaceCategory>{};
    final children = <String?, List<WorkspaceCategory>>{};
    for (final category in this.categories) {
      if (byId.containsKey(category.id)) {
        throw const FormatException('Category IDs must be unique.');
      }
      byId[category.id] = category;
      for (final reference in [category.id, ...category.aliases]) {
        final key = _referenceKey(reference);
        final existing = byReference[key];
        if (existing != null && existing.id != category.id) {
          throw const FormatException(
            'A category reference belongs to two categories.',
          );
        }
        byReference[key] = category;
      }
      (children[category.parentId] ??= []).add(category);
    }
    _byId = Map.unmodifiable(byId);
    _byReference = Map.unmodifiable(byReference);
    _paths = Map.unmodifiable({
      for (final category in this.categories) category.id: _readPath(category),
    });
    _children = Map.unmodifiable({
      for (final group in children.entries)
        group.key: List<WorkspaceCategory>.unmodifiable(
          group.value..sort(_compareCategories),
        ),
    });
  }

  factory WorkspaceCategories.defaults({
    Iterable<String> legacyIds = const [],
  }) => WorkspaceCategories([
    WorkspaceCategory(id: 'work', label: 'Work', colorArgb: 0xff4e6c9b),
    WorkspaceCategory(id: 'personal', label: 'Personal', colorArgb: 0xff8a6235),
    WorkspaceCategory(id: 'study', label: 'Study', colorArgb: 0xff775d96),
    WorkspaceCategory(id: 'gym', label: 'Gym', colorArgb: 0xff975b4b),
    WorkspaceCategory(id: 'health', label: 'Health', colorArgb: 0xff44734f),
  ]).withLegacyIds(legacyIds);

  factory WorkspaceCategories.fromJson(
    Map<String, dynamic> json, {
    Iterable<String> legacyIds = const [],
  }) {
    final raw = json['categories'];
    final version = json['version'];
    if (version is! int || version != 1 || raw is! List) {
      throw const FormatException('Invalid category catalog.');
    }
    return WorkspaceCategories([
      for (final item in raw)
        if (item is Map<String, dynamic>)
          WorkspaceCategory.fromJson(item)
        else
          throw const FormatException('Invalid category entry.'),
    ]).withLegacyIds(legacyIds);
  }

  static const maxDepth = 5;

  final List<WorkspaceCategory> categories;
  late final Map<String, WorkspaceCategory> _byId;
  late final Map<String, WorkspaceCategory> _byReference;
  late final Map<String, List<WorkspaceCategory>> _paths;
  late final Map<String?, List<WorkspaceCategory>> _children;

  WorkspaceCategory? resolve(String? reference) =>
      reference == null ? null : _byReference[_referenceKey(reference)];

  String? canonicalId(String? reference) => resolve(reference)?.id ?? reference;

  String labelFor(String? reference) =>
      resolve(reference)?.label ?? _legacyLabel(reference);

  int? colorArgbFor(String? reference) => resolve(reference)?.colorArgb;

  List<WorkspaceCategory> pathFor(String? reference) =>
      _paths[canonicalId(reference)] ?? const [];

  String pathLabelFor(String? reference) {
    final path = pathFor(reference);
    return path.isEmpty
        ? labelFor(reference)
        : path.map((category) => category.label).join(' / ');
  }

  Map<String, String> labels({bool includeArchived = false}) =>
      Map.unmodifiable({
        for (final category in categories)
          if (includeArchived || !category.archived)
            category.id: category.label,
      });

  bool matches(String? reference, Iterable<String> selected) {
    final ids = selected.map(canonicalId).toSet();
    return ids.contains(canonicalId(reference)) ||
        pathFor(reference).any((ancestor) => ids.contains(ancestor.id));
  }

  List<WorkspaceCategoryRow> rows({bool includeArchived = false}) {
    final rows = <WorkspaceCategoryRow>[];
    void visit(String? parentId, int depth) {
      for (final category
          in _children[parentId] ?? const <WorkspaceCategory>[]) {
        if (includeArchived || !category.archived) {
          rows.add((category: category, depth: depth));
        }
        visit(category.id, depth + 1);
      }
    }

    visit(null, 0);
    return List.unmodifiable(rows);
  }

  WorkspaceCategories withCategory(WorkspaceCategory category) =>
      WorkspaceCategories([
        for (final current in categories)
          if (current.id == category.id) category else current,
        if (!_byId.containsKey(category.id)) category,
      ]);

  WorkspaceCategories withArchived(String id, {bool archived = true}) {
    final category = resolve(id);
    if (category == null || category.archived == archived) return this;
    return withCategory(category.copyWith(archived: archived));
  }

  WorkspaceCategories withLegacyIds(Iterable<String> references) {
    final known = _byReference.keys.toSet();
    final additions = [
      for (final id in references)
        if (_validReference(id) && known.add(_referenceKey(id)))
          WorkspaceCategory(
            id: id,
            label: _legacyLabel(id),
            colorArgb: defaultWorkspaceCategoryColor,
          ),
    ];
    return additions.isEmpty
        ? this
        : WorkspaceCategories([...categories, ...additions]);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'categories': [for (final category in categories) category.toJson()],
  };

  List<WorkspaceCategory> _readPath(WorkspaceCategory category) {
    final visited = <String>{};
    final nodes = <WorkspaceCategory>[];
    var current = category;
    while (true) {
      if (!visited.add(current.id)) {
        throw const FormatException('A category cannot contain itself.');
      }
      nodes.add(current);
      if (nodes.length > maxDepth) {
        throw const FormatException(
          'Categories can be nested up to five levels.',
        );
      }
      final parent = current.parentId;
      if (parent == null) return List.unmodifiable(nodes.reversed);
      final next = _byId[parent];
      if (next == null) {
        throw const FormatException('Choose an existing parent category.');
      }
      current = next;
    }
  }
}

String newWorkspaceCategoryId() {
  final random = Random.secure();
  final suffix = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'category-$suffix';
}

String _referenceKey(String value) => value.trim().toLowerCase();

bool _validReference(String value) =>
    value.trim().isNotEmpty && !_invalidText.hasMatch(value);

String _legacyLabel(String? reference) {
  final text = reference?.replaceAll(_invalidText, ' ').trim() ?? '';
  if (text.isEmpty) return _generalLabel;
  final runes = text.runes;
  final head = String.fromCharCode(runes.first).toUpperCase();
  return String.fromCharCodes(
    head.runes.followedBy(runes.skip(1)).take(WorkspaceCategory.maxLabelLength),
  );
}

int _compareCategories(WorkspaceCategory first, WorkspaceCategory second) {
  final order = first.label.toLowerCase().compareTo(second.label.toLowerCase());
  return order == 0 ? first.id.compareTo(second.id) : order;
}
