import '../storage/attachment_store.dart';

class CaptureArchiveEntry {
  const CaptureArchiveEntry({
    required this.id,
    required this.text,
    required this.capturedAt,
    this.revision = 1,
    this.applied = false,
    this.audio,
  });

  final String id;
  final String text;
  final DateTime capturedAt;
  final int revision;
  final bool applied;
  final AttachmentRef? audio;

  CaptureArchiveEntry revised(String text) => CaptureArchiveEntry(
    id: id,
    text: text,
    capturedAt: capturedAt,
    revision: revision + 1,
    audio: audio,
  );

  CaptureArchiveEntry markApplied() => CaptureArchiveEntry(
    id: id,
    text: text,
    capturedAt: capturedAt,
    revision: revision,
    applied: true,
    audio: audio,
  );

  factory CaptureArchiveEntry.fromJson(Map<String, dynamic> json) {
    final audio = json['audio'];
    final ref = audio == null
        ? null
        : AttachmentRef.fromJson(audio as Map<String, dynamic>);
    if (ref != null && ref.format.kind != AttachmentKind.audio) {
      throw const FormatException(
        'A voice capture requires an audio attachment.',
      );
    }
    return CaptureArchiveEntry(
      id: json['id'] as String,
      text: json['text'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      revision: json['revision'] as int? ?? 1,
      applied: json['applied'] as bool? ?? false,
      audio: ref,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'capturedAt': capturedAt.toIso8601String(),
    'revision': revision,
    'applied': applied,
    if (audio != null) 'audio': audio!.toJson(),
  };
}
