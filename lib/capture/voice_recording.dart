import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// A foreground-only microphone stream. Samples are accumulated under a fixed
/// size limit before a WAV file is handed to the attachment store.
abstract interface class VoiceRecorder {
  Future<bool> requestPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class PlatformVoiceRecorder implements VoiceRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: VoiceSamples.sampleRate,
      numChannels: 1,
      audioInterruption: AudioInterruptionMode.pause,
      audioRouteChange: AudioRouteChangeMode.pause,
    ),
  );

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

class VoiceSamples {
  VoiceSamples({int byteLimit = maximumBytes}) : _limit = byteLimit {
    if (byteLimit < minimumBytes ||
        byteLimit > maximumBytes ||
        byteLimit.isOdd) {
      throw ArgumentError.value(byteLimit, 'byteLimit');
    }
  }

  static const sampleRate = 16000;
  static const bytesPerSecond = sampleRate * 2;
  static const minimumBytes = bytesPerSecond ~/ 5;
  static const maximumBytes = bytesPerSecond * 60 * 5;

  final int _limit;
  final _pcm = BytesBuilder();

  bool get isFull => _pcm.length >= _limit;
  bool get hasRecording => _pcm.length >= minimumBytes;
  Duration get duration => Duration(
    microseconds:
        _pcm.length * Duration.microsecondsPerSecond ~/ bytesPerSecond,
  );

  void add(Uint8List bytes) {
    final remaining = _limit - _pcm.length;
    if (remaining <= 0) return;
    _pcm.add(
      bytes.length <= remaining
          ? bytes
          : Uint8List.sublistView(bytes, 0, remaining),
    );
  }

  /// Leaves out an incomplete final sample from an interrupted stream.
  Uint8List toWav() {
    if (!hasRecording) throw StateError('No recording was captured.');
    final pcm = _pcm.toBytes();
    final length = pcm.length & ~1;
    final result = Uint8List(44 + length);
    final header = ByteData.sublistView(result, 0, 44);
    result.setRange(0, 4, const [82, 73, 70, 70]); // RIFF
    header.setUint32(4, 36 + length, Endian.little);
    result.setRange(8, 16, const [
      87,
      65,
      86,
      69,
      102,
      109,
      116,
      32,
    ]); // WAVEfmt
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, bytesPerSecond, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    result.setRange(36, 40, const [100, 97, 116, 97]); // data
    header.setUint32(40, length, Endian.little);
    result.setRange(44, result.length, pcm);
    return result;
  }
}
