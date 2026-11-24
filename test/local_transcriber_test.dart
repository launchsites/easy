import 'dart:io';
import 'dart:typed_data';

import 'package:easy/capture/local_transcriber.dart';
import 'package:easy/capture/voice_recording.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joins bounded Whisper segments into a reviewable transcript', () {
    expect(
      parseWhisperOutput({
        'result': {'language': 'en'},
        'transcription': [
          {'text': ' Reserve a study room '},
          {'text': ' '},
          {'text': 'tomorrow at ten.'},
        ],
      }),
      'Reserve a study room tomorrow at ten.',
    );
    expect(
      () => parseWhisperOutput({'transcription': []}),
      throwsFormatException,
    );
    expect(
      () => parseWhisperOutput({
        'transcription': [
          {'text': 'x' * 12001},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => parseWhisperOutput({
        'transcription': ['wrong'],
      }),
      throwsFormatException,
    );
  });

  test(
    'runs a local executable with file arguments and cleans scratch input',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'easy-whisper-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final tool = File.fromUri(directory.uri.resolve('trusted tool'));
      final model = File.fromUri(
        directory.uri.resolve('weights with spaces.bin'),
      );
      await model.writeAsBytes([1, 2, 3]);
      await tool.writeAsString(r'''#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) wave="$2"; shift ;;
    --model) model="$2"; shift ;;
    --output-file) output="$2"; shift ;;
  esac
  shift
done
test -f "$wave"
test -f "$model"
printf '{"transcription":[{"text":" Review this first. "}]}\n' > "$output.json"
''');
      expect((await Process.run('/bin/chmod', ['700', tool.path])).exitCode, 0);
      final config = VoiceTranscriptionConfig(
        executable: tool.path,
        model: model.path,
      );
      final samples = VoiceSamples()..add(Uint8List(7000));
      final transcript = await LocalTranscriber().transcribe(
        config,
        samples.toWav(),
      );
      expect(transcript, 'Review this first.');
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );
}
