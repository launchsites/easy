import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../local_transcriber.dart' show parseWhisperOutput;
import '../voice_recording.dart' show VoiceSamples;

bool get supported =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

class Transcriber {
  var _running = false;
  var _generation = 0;
  Process? _process;

  Future<String> transcribe(
    String executable,
    String model,
    Uint8List wave,
  ) async {
    if (!supported) {
      throw UnsupportedError('Local transcription is unavailable.');
    }
    if (_running) throw StateError('Another recording is being transcribed.');
    if (wave.length <= 44 || wave.length > VoiceSamples.maximumBytes + 44) {
      throw const FormatException('This recording exceeds the supported size.');
    }
    _running = true;
    final generation = ++_generation;
    Directory? scratch;
    try {
      final tool = await _localFile(executable);
      final weights = await _localFile(model);
      if (await File(weights).length() > 4 * 1024 * 1024 * 1024) {
        throw const FormatException('Choose a model under 4 GB.');
      }
      scratch = await Directory.systemTemp.createTemp('easy-voice-');
      final audio = File.fromUri(scratch.uri.resolve('recording.wav'));
      await audio.writeAsBytes(wave, flush: true);
      _checkGeneration(generation);
      final prefix = scratch.uri.resolve('transcript').toFilePath();
      final process = await Process.start(
        tool,
        [
          '--model',
          weights,
          '--file',
          audio.path,
          '--language',
          'auto',
          '--threads',
          Platform.numberOfProcessors.clamp(1, 4).toString(),
          '--processors',
          '1',
          '--no-gpu',
          '--output-json',
          '--output-file',
          prefix,
          '--no-prints',
        ],
        workingDirectory: scratch.path,
        includeParentEnvironment: false,
        runInShell: false,
      );
      _process = process;
      if (generation != _generation) {
        _kill(process);
        await process.exitCode;
        _checkGeneration(generation);
      }
      final drained = Future.wait<void>([
        process.stdout.drain<void>(),
        process.stderr.drain<void>(),
      ]);
      final code = await process.exitCode.timeout(
        const Duration(minutes: 4),
        onTimeout: () async {
          _kill(process);
          await process.exitCode.timeout(
            const Duration(seconds: 2),
            onTimeout: () => -1,
          );
          return -1;
        },
      );
      await drained.timeout(const Duration(seconds: 2));
      _checkGeneration(generation);
      if (code != 0) {
        throw StateError(
          'The local runtime could not transcribe this recording.',
        );
      }
      final file = File('$prefix.json');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > 1024 * 1024) {
        throw const FormatException('Invalid local transcription output.');
      }
      final output = <int>[];
      await for (final bytes in file.openRead()) {
        if (output.length + bytes.length > 1024 * 1024) {
          throw const FormatException(
            'Local transcription output is too large.',
          );
        }
        output.addAll(bytes);
      }
      _checkGeneration(generation);
      return parseWhisperOutput(jsonDecode(utf8.decode(output)));
    } finally {
      final process = _process;
      if (process != null) _kill(process);
      _process = null;
      try {
        if (scratch != null) await scratch.delete(recursive: true);
      } on FileSystemException {
        // Temporary directories can be removed by OS cleanup after a crash.
      }
      _running = false;
    }
  }

  Future<String> _localFile(String path) async {
    final file = File(path);
    if (!file.isAbsolute || !await file.exists()) {
      throw const FormatException(
        'Choose an existing local runtime and model.',
      );
    }
    return file.resolveSymbolicLinks();
  }

  void _checkGeneration(int generation) {
    if (_generation != generation) {
      throw StateError('Local transcription was stopped.');
    }
  }

  void cancel() {
    _generation++;
    final process = _process;
    if (process != null) _kill(process);
  }

  void _kill(Process process) {
    process.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
    );
  }
}
