enum FocusSection {
  schedule('Schedule'),
  tasks('Tasks'),
  workout('Workout'),
  nutrition('Nutrition'),
  routines('Routines'),
  activity('Activity');

  const FocusSection(this.label);
  final String label;
}

/// A display preference over the shared workspace. It never grants access
/// and is independent of the preferred destination for new manual captures.
class FocusMode {
  FocusMode({
    required this.id,
    required this.name,
    required this.color,
    Set<String>? categories,
    Set<FocusSection> sections = const {
      FocusSection.schedule,
      FocusSection.tasks,
    },
    this.preferredCategory,
  }) : categories = categories == null ? null : Set.unmodifiable(categories),
       sections = Set.unmodifiable(sections) {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('A focus mode needs an ID and a name.');
    }
    if (color < 0xff000000 || color > 0xffffffff) {
      throw ArgumentError('A focus color must be an opaque ARGB value.');
    }
  }

  final String id;
  final String name;
  final int color;

  /// Null includes every category. An empty set includes no categorized items.
  final Set<String>? categories;
  final Set<FocusSection> sections;
  final String? preferredCategory;

  bool includes(String? category) =>
      categories == null ||
      (category != null && categories!.contains(category));

  factory FocusMode.fromJson(Map<String, dynamic> json) {
    final values =
        (json['sections'] as List<dynamic>? ?? const ['schedule', 'tasks'])
            .cast<String>();
    return FocusMode(
      id: json['id'] as String,
      name: json['name'] as String,
      color: json['color'] as int,
      categories: (json['categories'] as List<dynamic>?)
          ?.cast<String>()
          .toSet(),
      sections: {
        for (final section in FocusSection.values)
          if (values.contains(section.name)) section,
      },
      preferredCategory: json['preferredCategory'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    if (categories != null) 'categories': categories!.toList()..sort(),
    'sections': (sections.map((section) => section.name).toList()..sort()),
    if (preferredCategory != null) 'preferredCategory': preferredCategory,
  };
}

List<FocusMode> standardFocusModes() => [
  FocusMode(
    id: 'work',
    name: 'Work',
    color: 0xff4e6c9b,
    categories: {'work'},
    preferredCategory: 'work',
  ),
  FocusMode(
    id: 'personal',
    name: 'Personal',
    color: 0xff8a6235,
    categories: {'personal'},
    preferredCategory: 'personal',
  ),
  FocusMode(
    id: 'study',
    name: 'Study',
    color: 0xff775d96,
    categories: {'study'},
    preferredCategory: 'study',
  ),
  FocusMode(
    id: 'gym',
    name: 'Gym',
    color: 0xffb24f43,
    categories: {'gym'},
    sections: {FocusSection.workout},
    preferredCategory: 'gym',
  ),
  FocusMode(
    id: 'health',
    name: 'Health',
    color: 0xff44734f,
    categories: {'health'},
    sections: {
      FocusSection.nutrition,
      FocusSection.schedule,
      FocusSection.tasks,
    },
    preferredCategory: 'health',
  ),
];
