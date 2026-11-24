import 'dart:async';
import 'dart:typed_data';

import 'package:easy/capture/capture_archive.dart';
import 'package:easy/capture/held_voice_capture.dart';
import 'package:easy/capture/hold_capture_button.dart';
import 'package:easy/capture/voice_capture_sheet.dart';
import 'package:easy/capture/voice_recording.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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

  testWidgets('held capture retains the pointer through overlay insertion', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    expect(find.text('Release to save · slide up to lock'), findsOneWidget);
    expect(capture.recorder.starts, 1);
    expect(capture.result.isCompleted, isFalse);
    await capture.feedAudio();
    await pointer.up();
    await tester.pumpAndSettle();
    expect(capture.savedBytes, [8044]);
    expect((await capture.result.future)?.id, 'held');
    expect(capture.recorder.stops, 1);
    expect(capture.recorder.cancels, 0);
    expect(capture.recorder.disposals, 1);
    expect(find.text('Voice capture'), findsNothing);
    expect(find.text('Workspace'), findsOneWidget);
  });

  testWidgets('held capture discards when released in the cancel area', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    await capture.feedAudio();
    await pointer.moveBy(const Offset(-90, 0));
    await tester.pump();
    expect(find.text('Release to cancel'), findsOneWidget);
    await pointer.up();
    await tester.pumpAndSettle();
    expect(await capture.result.future, isNull);
    expect(capture.savedBytes, isEmpty);
    expect(capture.recorder.cancels, 1);
    expect(capture.recorder.disposals, 1);
  });

  testWidgets(
    'locked capture ignores outside taps and supports explicit stop',
    (tester) async {
      final capture = await _HeldCapture.mount(tester);
      final pointer = await capture.hold();
      await pointer.moveBy(const Offset(0, -85));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(find.text('Recording'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('Workspace')));
      await tester.pumpAndSettle();
      expect(capture.workspaceTaps, 0);
      expect(capture.result.isCompleted, isFalse);
      await capture.feedAudio();
      await tester.tap(find.text('Stop and save'));
      await tester.pumpAndSettle();
      expect(capture.savedBytes, [8044]);
      expect(capture.recorder.stops, 1);
    },
  );

  for (final systemBack in [false, true]) {
    testWidgets(
      'locked capture responds to ${systemBack ? 'Back' : 'Escape'}',
      (tester) async {
        final capture = await _HeldCapture.mount(tester);
        final pointer = await capture.hold();
        await pointer.moveBy(const Offset(0, -85));
        await pointer.up();
        await tester.pumpAndSettle();
        await capture.feedAudio();
        Iterable<String> visibleLabels() => tester.semantics
            .simulatedAccessibilityTraversal()
            .map((node) => node.label);
        expect(visibleLabels(), isNot(contains('Workspace')));
        expect(visibleLabels(), contains('Cancel'));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus!.context!
              .findAncestorWidgetOfExactType<VoiceCaptureSheet>(),
          isNotNull,
        );
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await tester.pumpAndSettle();
        expect(await capture.result.future, isNull);
        expect(capture.savedBytes, isEmpty);
        expect(capture.recorder.cancels, 1);
        expect(find.text('Voice capture'), findsNothing);
        expect(visibleLabels(), contains('Workspace'));
      },
    );
  }

  testWidgets('interruption while held saves once before pointer release', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    await capture.feedAudio();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pointer.up();
    await tester.pumpAndSettle();
    expect(capture.savedBytes, [8044]);
    expect(capture.recorder.stops, 1);
    expect((await capture.result.future)?.id, 'held');
  });

  testWidgets('cancel closes during permission without opening a stream', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final permission = capture.recorder.permission = Completer<bool>();
    final pointer = await capture.hold();
    expect(capture.recorder.permissionRequests, 1);
    await pointer.moveBy(const Offset(-85, 0));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(await capture.result.future, isNull);
    expect(find.text('Voice capture'), findsNothing);
    permission.complete(true);
    await tester.pumpAndSettle();
    expect(capture.recorder.starts, 0);
    expect(capture.recorder.disposals, 1);
  });

  testWidgets('removing the capture button discards an unlocked hold', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    await capture.feedAudio();
    await capture.hideButton();
    expect(find.text('Voice capture'), findsNothing);
    expect(await capture.result.future, isNull);
    expect(capture.savedBytes, isEmpty);
    expect(capture.recorder.cancels, 1);
    await pointer.up();
    await tester.pumpAndSettle();
  });

  testWidgets('locked recording survives removal of the capture button', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    await pointer.moveBy(const Offset(0, -85));
    await pointer.up();
    await tester.pumpAndSettle();
    await capture.hideButton();
    expect(find.text('Recording'), findsOneWidget);
    expect(capture.result.isCompleted, isFalse);
    await capture.feedAudio();
    await tester.tap(find.text('Stop and save'));
    await tester.pumpAndSettle();
    expect(capture.savedBytes, [8044]);
    expect(capture.recorder.stops, 1);
  });

  testWidgets('removing the button preserves a recording awaiting retry', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester)
      ..rejectSaves = true;
    final pointer = await capture.hold();
    await capture.feedAudio();
    await pointer.up();
    await tester.pumpAndSettle();
    await capture.hideButton();
    expect(capture.result.isCompleted, isFalse);
    expect(capture.recorder.cancels, 0);
    capture.rejectSaves = false;
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(capture.savedBytes, [8044]);
  });

  testWidgets('a stalled recording reaches the five-minute limit', (
    tester,
  ) async {
    final capture = await _HeldCapture.mount(tester);
    final pointer = await capture.hold();
    await capture.feedAudio();
    await tester.pump(VoiceSamples.maximumDuration);
    await tester.pumpAndSettle();
    await pointer.up();
    expect(capture.savedBytes, [8044]);
    expect(capture.recorder.stops, 1);
    expect((await capture.result.future)?.id, 'held');
  });
}

class _HeldCapture {
  _HeldCapture(this.tester);

  final WidgetTester tester;
  final recorder = _FakeRecorder();
  final result = Completer<CaptureArchiveEntry?>();
  final savedBytes = <int>[];
  final overlay = HeldVoiceCaptureOverlay();
  final buttonVisible = ValueNotifier(true);
  var workspaceTaps = 0;
  var rejectSaves = false;

  static Future<_HeldCapture> mount(WidgetTester tester) async {
    final capture = _HeldCapture(tester);
    addTearDown(capture.overlay.dispose);
    addTearDown(capture.buttonVisible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => capture.workspaceTaps++,
                child: const Text('Workspace'),
              ),
            ),
            floatingActionButton: ValueListenableBuilder<bool>(
              valueListenable: capture.buttonVisible,
              builder: (_, visible, _) {
                if (!visible) return const SizedBox.shrink();
                return HoldCaptureButton(
                  onTap: () => fail('the held gesture must not tap'),
                  onHeldRecord: (action) async => capture.result.complete(
                    await capture.overlay.show(
                      context,
                      action: action,
                      openRecorder: () => capture.recorder,
                      onSave: (bytes, time) async {
                        if (capture.rejectSaves) {
                          throw StateError('Fixture save failure');
                        }
                        capture.savedBytes.add(bytes.length);
                        return CaptureArchiveEntry(
                          id: 'held',
                          text: '',
                          capturedAt: time,
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    return capture;
  }

  Future<TestGesture> hold() async {
    final pointer = await tester.startGesture(
      tester.getCenter(find.byTooltip('Add item')),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pumpAndSettle();
    return pointer;
  }

  Future<void> feedAudio() async {
    recorder.audio.add(Uint8List(8000));
    await tester.pump();
  }

  Future<void> hideButton() async {
    buttonVisible.value = false;
    await tester.pumpAndSettle();
  }
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
  var cancels = 0;
  var disposals = 0;

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
    cancels++;
    unawaited(audio.close());
  }

  @override
  Future<void> dispose() async {
    disposals++;
    if (!audio.isClosed) unawaited(audio.close());
  }
}
