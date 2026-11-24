import 'dart:typed_data';

import 'src/transcriber_stub.dart'
    if (dart.library.io) 'src/transcriber_native.dart'
    as platform;

class VoiceTranscriptionConfig {
  VoiceTranscriptionConfig({required this.executable, required this.model}) {
    if (executable.trim().isEmpty ||
        model.trim().isEmpty ||
        executable.length > 4096 ||
        model.length > 4096 ||
        executable.contains('\x00') ||
        model.contains('\x00')) {
      throw const FormatException('Choose a local runtime and model.');
    }
  }

  factory VoiceTranscriptionConfig.fromJson(Map<String, dynamic> json) =>
      VoiceTranscriptionConfig(
        executable: json['executable'] as String,
        model: json['model'] as String,
      );

  final String executable;
  final String model;

  Map<String, Object> toJson() => {'executable': executable, 'model': model};
}

class LocalTranscriber {
  static bool get supported => platform.supported;
  final _native = platform.Transcriber();

  Future<String> transcribe(VoiceTranscriptionConfig config, Uint8List wave) =>
      _native.transcribe(config.executable, config.model, wave);

  void cancel() => _native.cancel();
}

/// whisper.cpp emits a transcription array with text for each timed segment.
String parseWhisperOutput(Object? output) {
  if (output is! Map<String, dynamic> || output['transcription'] is! List) {
    throw const FormatException('Unsupported local transcription result.');
  }
  final segments = output['transcription'] as List;
  final text = StringBuffer();
  for (final segment in segments) {
    if (segment is! Map<String, dynamic> || segment['text'] is! String) {
      throw const FormatException('Invalid local transcription segment.');
    }
    final value = (segment['text'] as String).trim();
    if (value.isEmpty) continue;
    if (text.isNotEmpty) text.write(' ');
    text.write(value);
    if (text.length > 12000) {
      throw const FormatException('The transcript exceeds 12,000 characters.');
    }
  }
  if (text.isEmpty) throw const FormatException('No speech was transcribed.');
  return text.toString();
}
