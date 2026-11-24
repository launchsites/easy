import 'dart:typed_data';

const supported = false;

class Transcriber {
  Future<String> transcribe(String executable, String model, Uint8List wave) =>
      Future.error(UnsupportedError('Local transcription is unavailable.'));

  void cancel() {}
}
