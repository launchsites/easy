import 'dart:async';
import 'dart:typed_data';

import 'package:easy/capture/capture_archive.dart';
import 'package:easy/capture/hold_capture_button.dart';
import 'package:easy/capture/voice_capture_sheet.dart';
import 'package:easy/capture/voice_recording.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounded voice samples produce a standard mono PCM wave', () {
    final samples = VoiceSamples(byteLimit: VoiceSamples.minimumBytes + 2);
    expect(samples.toWav, throwsStateError);
    samples.add(Uint8List(6401));
    samples.add(Uint8List.fromList([7, 8, 9, 10]));
    expect(samples.isFull, isTrue);
    expect(samples.duration.inMilliseconds, 200);
    final wav = samples.toWav();
    final header = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), 6402);
    expect(wav.last, 7);
  });

  testWidgets(
    'recording begins only after permission and saves received audio',
    (tester) async {
      final recorder = _FakeRecorder();
      var saved = 0;
      await _mount(tester, recorder, (bytes) => saved = bytes.length);
      expect(recorder.permissionRequests, 0);
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      expect(recorder.permissionRequests, 1);
      expect(recorder.starts, 1);
      recorder.audio.add(Uint8List(8000));
      await tester.pump();
      await tester.tap(find.text('Stop and save'));
      await tester.pumpAndSettle();
      expect(recorder.stops, 1);
      expect(
        saved,
        8044,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(', '),
      );
      expect(find.text('Voice capture'), findsNothing);
    },
  );

  testWidgets('early release never starts the microphone after a prompt', (
    tester,
  ) async {
    final recorder = _FakeRecorder()..permission = Completer<bool>();
    final action = ValueNotifier(HeldVoiceAction.holding);
    addTearDown(action.dispose);
    await _mount(
      tester,
      recorder,
      (_) => fail('voice should not be saved'),
      action,
    );
    await tester.tap(find.text('Record'));
    await tester.pump();
    action.value = HeldVoiceAction.save;
    recorder.permission!.complete(true);
    await tester.pumpAndSettle();
    expect(recorder.starts, 0);
    expect(find.text('Voice capture'), findsNothing);
  });

  testWidgets('suspending the app saves an interrupted recording once', (
    tester,
  ) async {
    final recorder = _FakeRecorder();
    var saves = 0;
    await _mount(tester, recorder, (_) => saves++);
    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();
    recorder.audio.add(Uint8List(8000));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(recorder.stops, 1);
    expect(
      saves,
      1,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(', '),
    );
  });

  testWidgets('a denied microphone leaves a recoverable close action', (
    tester,
  ) async {
    final recorder = _FakeRecorder()
      ..permission = Completer<bool>()
      ..permission!.complete(false);
    await _mount(tester, recorder, (_) => fail('voice should not be saved'));
    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();
    expect(recorder.starts, 0);
    expect(find.textContaining('Allow microphone access'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Voice capture'), findsNothing);
  });

  testWidgets('long press chooses release, cancel and lock without a tap', (
    tester,
  ) async {
    var taps = 0;
    final outcomes = <HeldVoiceAction>[];
    Completer<void>? closeVoice;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoldCaptureButton(
              onTap: () => taps++,
              onHeldRecord: (action) async {
                closeVoice = Completer<void>();
                action.addListener(() => outcomes.add(action.value));
                await closeVoice!.future;
              },
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byTooltip('Add item'));
    var gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveBy(const Offset(-75, 0));
    await gesture.up();
    await tester.pump();
    expect(outcomes, [HeldVoiceAction.cancelOnRelease, HeldVoiceAction.cancel]);
    closeVoice!.complete();
    await tester.pump();

    gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveBy(const Offset(0, -78));
    await gesture.up();
    await tester.pump();
    expect(outcomes.last, HeldVoiceAction.lock);
    closeVoice!.complete();
    await tester.pump();

    gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.up();
    await tester.pump();
    expect(outcomes.last, HeldVoiceAction.save);
    closeVoice!.complete();
    await tester.pump();
    expect(taps, 0);
    await tester.tapAt(center);
    expect(taps, 1);
  });
}

Future<void> _mount(
  WidgetTester tester,
  _FakeRecorder recorder,
  void Function(Uint8List) save, [
  ValueNotifier<HeldVoiceAction>? action,
]) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<CaptureArchiveEntry>(
            context: context,
            builder: (_) => Dialog(
              child: VoiceCaptureSheet(
                heldAction: action,
                openRecorder: () => recorder,
                onSave: (bytes, time) async {
                  save(bytes);
                  return CaptureArchiveEntry(
                    id: 'voice',
                    text: '',
                    capturedAt: time,
                  );
                },
              ),
            ),
          ),
          child: const Text('Record'),
        ),
      ),
    ),
  ),
);

class _FakeRecorder implements VoiceRecorder {
  final audio = StreamController<Uint8List>();
  Completer<bool>? permission;
  var permissionRequests = 0;
  var starts = 0;
  var stops = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return await (permission?.future ?? Future.value(true));
  }

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    unawaited(audio.close());
  }

  @override
  Future<void> cancel() async {
    unawaited(audio.close());
  }

  @override
  Future<void> dispose() async {
    if (!audio.isClosed) unawaited(audio.close());
  }
}
