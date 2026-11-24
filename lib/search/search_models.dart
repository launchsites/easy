enum SearchRecordKind {
  task('Task', 'Tasks'),
  event('Event', 'Events'),
  note('Note', 'Notes'),
  activity('Activity', 'Activities'),
  workout('Workout', 'Workouts'),
  meal('Meal', 'Meals');

  const SearchRecordKind(this.label, this.collectionLabel);
  final String label;
  final String collectionLabel;
}

class SearchKey {
  const SearchKey(this.kind, this.id);

  factory SearchKey.fromJson(Map<String, dynamic> json) {
    final kind = SearchRecordKind.values.asNameMap()[json['kind']];
    final id = json['id'];
    if (kind == null || id is! String || id.trim().isEmpty) {
      throw const FormatException('Invalid search record reference.');
    }
    return SearchKey(kind, id);
  }

  final SearchRecordKind kind;
  final String id;

  Map<String, Object> toJson() => {'kind': kind.name, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is SearchKey && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// Supply only records and fields visible under the workspace's enabled features.
class SearchDocument {
  const SearchDocument({
    required this.key,
    required this.title,
    this.body = '',
    this.categoryId,
    this.categoryName,
    this.date,
    this.pinned = false,
  });

  final SearchKey key;
  final String title;
  final String body;
  final String? categoryId;
  final String? categoryName;
  final DateTime? date;
  final bool pinned;
}

class SearchPreferences {
  SearchPreferences({
    Iterable<SearchKey> recent = const [],
    Iterable<SearchKey> favourites = const [],
  }) : recent = List.unmodifiable(recent.toSet().take(maxRecent)),
       favourites = Set.unmodifiable(favourites);

  factory SearchPreferences.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['recent'] is! List ||
        json['favourites'] is! List) {
      throw const FormatException('Invalid search preferences.');
    }
    return SearchPreferences(
      recent: _readKeys(json['recent'] as List),
      favourites: _readKeys(json['favourites'] as List),
    );
  }

  static const maxRecent = 30;
  final List<SearchKey> recent;
  final Set<SearchKey> favourites;

  SearchPreferences opened(SearchKey key) => SearchPreferences(
    recent: [key, ...recent.where((value) => value != key)],
    favourites: favourites,
  );

  SearchPreferences withFavourite(SearchKey key, bool value) =>
      SearchPreferences(
        recent: recent,
        favourites: value ? {...favourites, key} : favourites.difference({key}),
      );

  SearchPreferences withoutRecent() =>
      SearchPreferences(favourites: favourites);

  Map<String, Object> toJson() => {
    'version': 1,
    'recent': [for (final key in recent) key.toJson()],
    'favourites': [for (final key in favourites) key.toJson()],
  };

  static Iterable<SearchKey> _readKeys(List keys) =>
      keys.map((key) => SearchKey.fromJson(key as Map<String, dynamic>));
}

class WorkspaceSearchQuery {
  const WorkspaceSearchQuery(
    this.text, {
    this.kinds,
    this.allowedCategories,
    this.favouritesOnly = false,
  });

  final String text;
  final Set<SearchRecordKind>? kinds;

  /// Null keeps the global view. A restricted scope omits unclassified records.
  final Set<String>? allowedCategories;
  final bool favouritesOnly;
}

class SearchHit {
  const SearchHit({
    required this.document,
    required this.snippet,
    required this.score,
  });

  final SearchDocument document;
  final String snippet;
  final int score;
}
