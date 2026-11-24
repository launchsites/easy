class CaptureArchiveEntry {
  const CaptureArchiveEntry({
    required this.id,
    required this.text,
    required this.capturedAt,
    this.revision = 1,
    this.applied = false,
  });

  final String id;
  final String text;
  final DateTime capturedAt;
  final int revision;
  final bool applied;

  CaptureArchiveEntry revised(String text) => CaptureArchiveEntry(
    id: id,
    text: text,
    capturedAt: capturedAt,
    revision: revision + 1,
  );

  CaptureArchiveEntry markApplied() => CaptureArchiveEntry(
    id: id,
    text: text,
    capturedAt: capturedAt,
    revision: revision,
    applied: true,
  );

  factory CaptureArchiveEntry.fromJson(Map<String, dynamic> json) =>
      CaptureArchiveEntry(
        id: json['id'] as String,
        text: json['text'] as String,
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        revision: json['revision'] as int? ?? 1,
        applied: json['applied'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'capturedAt': capturedAt.toIso8601String(),
    'revision': revision,
    'applied': applied,
  };
}
