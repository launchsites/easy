enum NoteLinkKind {
  task('Task'),
  event('Event');

  const NoteLinkKind(this.label);

  final String label;
}

class NoteLink {
  const NoteLink({required this.kind, required this.id, this.title});

  factory NoteLink.fromJson(Map<String, dynamic> json) {
    final kind = NoteLinkKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    final id = json['id'];
    if (kind == null || id is! String || id.isEmpty) {
      throw const FormatException('Invalid note link.');
    }
    return NoteLink(kind: kind, id: id, title: json['title'] as String?);
  }

  static NoteLink? fromMarkdown(String? target) {
    if (target == null || !target.startsWith('easy:')) return null;
    final uri = Uri.tryParse(target);
    if (uri == null ||
        uri.hasAuthority ||
        uri.hasAbsolutePath ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    try {
      final segments = uri.pathSegments;
      if (segments.length != 2 || segments[1].isEmpty) return null;
      final kind = NoteLinkKind.values
          .where((kind) => kind.name == segments[0])
          .firstOrNull;
      return kind == null ? null : NoteLink(kind: kind, id: segments[1]);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  final NoteLinkKind kind;
  final String id;
  final String? title;

  Uri get markdownUri => Uri(scheme: 'easy', pathSegments: [kind.name, id]);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'id': id,
    if (title != null) 'title': title,
  };

  @override
  bool operator ==(Object other) =>
      other is NoteLink && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

class NoteTarget {
  const NoteTarget({required this.kind, required this.id, required this.title});

  final NoteLinkKind kind;
  final String id;
  final String title;

  NoteLink get link => NoteLink(kind: kind, id: id, title: title);
}

class NoteItem {
  const NoteItem({
    required this.id,
    required this.title,
    required this.body,
    required this.updated,
    this.category,
    this.noteToSelf = false,
    this.pinned = false,
    this.folder,
    this.tags = const [],
    this.links = const [],
  });

  factory NoteItem.fromJson(Map<String, dynamic> json) => NoteItem(
    id: json['id'] as String,
    title: json['title'] as String,
    body: json['body'] as String,
    updated: DateTime.parse(json['updated'] as String),
    category: json['category'] as String?,
    noteToSelf: json['noteToSelf'] as bool? ?? false,
    pinned: json['pinned'] as bool? ?? false,
    folder: json['folder'] as String?,
    tags: List.unmodifiable(
      (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
    ),
    links: List.unmodifiable([
      for (final link in json['links'] as List<dynamic>? ?? const [])
        NoteLink.fromJson(link as Map<String, dynamic>),
    ]),
  );

  final String id;
  final String title;
  final String body;
  final DateTime updated;
  final String? category;
  final bool noteToSelf;
  final bool pinned;
  final String? folder;
  final List<String> tags;
  final List<NoteLink> links;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'updated': updated.toIso8601String(),
    if (category != null) 'category': category,
    if (noteToSelf) 'noteToSelf': true,
    if (pinned) 'pinned': true,
    if (folder != null) 'folder': folder,
    if (tags.isNotEmpty) 'tags': tags,
    if (links.isNotEmpty) 'links': [for (final link in links) link.toJson()],
  };
}

List<String> noteTags(String text) => List.unmodifiable(
  {
    for (final raw in text.split(','))
      if (raw.trim() case final tag when tag.isNotEmpty) tag.toLowerCase(): tag,
  }.values,
);
