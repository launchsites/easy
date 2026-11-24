import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_device_state.dart';
import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _maximum = 9216;
const _key = 'synthetic-allowance-test-key';
const _cap = 1000000;
const _gateTimeout = Duration(seconds: 5);
final _day = DateTime.utc(2026, 11, 24);

void main() {
  late AiDeviceState firstStore;
  late AiDeviceState secondStore;

  setUp(() async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    final directory = await Directory.systemTemp.createTemp('easy-allowance-');
    addTearDown(() => directory.delete(recursive: true));
    Future<AiDeviceState> open() => AiDeviceState.open(
      preferences: SharedPreferencesAsync(),
      databasePath: directory.uri.resolve('ai.sqlite3').toFilePath(),
    );
    firstStore = await open();
    addTearDown(firstStore.close);
    secondStore = await open();
    addTearDown(secondStore.close);
  });

  test(
    'writers sharing one allowance revision dispatch after SQLite approval',
    () async {
      final bothAtReservation = Completer<void>();
      final input = _captureSource();
      var arrivals = 0;
      var race = false;
      var sends = 0;
      Future<int?> reserve(
        AiDeviceState store,
        int revision,
        String value,
      ) async {
        if (race && _ledgerFrom(value).report().reservedMicros == _maximum) {
          if (++arrivals == 2) bothAtReservation.complete();
          await bothAtReservation.future.timeout(_gateTimeout);
        }
        return store.compareAndSwap(revision, value);
      }

      Future<http.StreamedResponse> send(http.BaseRequest request) async {
        sends++;
        expect((await _ledger(firstStore)).report().reservedMicros, _maximum);
        return _reply(input);
      }

      final first = _runtime(
        firstStore,
        send,
        compareAndSwap: (r, v) => reserve(firstStore, r, v),
      );
      final second = _runtime(
        secondStore,
        send,
        compareAndSwap: (r, v) => reserve(secondStore, r, v),
      );
      expect(
        await first.saveSettings(_paid(cap: _maximum), apiKey: _key),
        AiSettingsSaveStatus.saved,
      );
      expect(await second.load(), isTrue);
      race = true;
      final outcomes = await Future.wait([
        _capture(first, input),
        _capture(second, input),
      ]);
      expect(arrivals, 2);
      expect(sends, 1);
      expect(
        outcomes.where((outcome) => outcome.status == AiRunStatus.ready),
        hasLength(1),
      );
      final saved = (await _ledger(secondStore)).report();
      expect(saved.chargedMicros, 4);
      expect(saved.reservedMicros, 0);
    },
  );

  test('opening a second runtime leaves a fresh reservation available to its owner', () async {
    final input = _captureSource();
    final response = _GatedReply(input);
    final first = _runtime(firstStore, response.send);
    expect(
      await first.saveSettings(_paid(), apiKey: _key),
      AiSettingsSaveStatus.saved,
    );
    final running = _capture(first, input);
    try {
      await response.sent.future.timeout(_gateTimeout);
      final second = _runtime(secondStore, _unexpected);
      expect(await second.load(), isTrue);
      expect(second.budget.reservedMicros, _maximum);
      expect(second.budget.unknownUsageCalls, 0);
    } finally {
      response.release();
    }
    expect((await running).status, AiRunStatus.ready);
    final saved = (await _ledger(secondStore)).report();
    expect(saved.chargedMicros, 4);
    expect(saved.unknownUsageCalls, 0);
  });

  test('independent paid reservations can settle in reverse order', () async {
    final firstInput = _captureSource(id: 'first-capture');
    final secondInput = _captureSource(id: 'second-capture');
    final firstReply = _GatedReply(firstInput);
    final secondReply = _GatedReply(secondInput, inputTokens: 5);
    final first = _runtime(firstStore, firstReply.send);
    final second = _runtime(secondStore, secondReply.send);
    expect(
      await first.saveSettings(_paid(), apiKey: _key),
      AiSettingsSaveStatus.saved,
    );

    final firstResult = _capture(first, firstInput);
    try {
      await firstReply.sent.future.timeout(_gateTimeout);
      expect(await second.load(), isTrue);
      final secondResult = _capture(second, secondInput);
      try {
        await secondReply.sent.future.timeout(_gateTimeout);
        final reserved = await _ledger(firstStore);
        expect(
          reserved.reservations.map((entry) => entry.id).toSet(),
          hasLength(2),
        );
        expect(reserved.report().reservedMicros, 2 * _maximum);
      } finally {
        secondReply.release();
      }
      expect((await secondResult).status, AiRunStatus.ready);
      final savedSecond = (await _ledger(firstStore)).report();
      expect(savedSecond.reservedMicros, _maximum);
      expect(savedSecond.chargedMicros, 7);
    } finally {
      firstReply.release();
    }
    expect((await firstResult).status, AiRunStatus.ready);
    final saved = (await _ledger(secondStore)).report();
    expect(saved.chargedMicros, 11);
    expect(saved.reservedMicros, 0);
    expect(saved.knownInputTokens, 7);
    expect(saved.knownOutputTokens, 2);
    expect(saved.unknownUsageCalls, 0);
  });

  test('a changed provider policy withholds an on-wire review and saves verified usage', () async {
    final input = _captureSource();
    final response = _GatedReply(input);
    final first = _runtime(firstStore, response.send);
    final second = _runtime(secondStore, _unexpected);
    expect(
      await first.saveSettings(_paid(), apiKey: _key),
      AiSettingsSaveStatus.saved,
    );
    final running = _capture(first, input);
    try {
      await response.sent.future.timeout(_gateTimeout);
      expect(await second.load(), isTrue);
      expect(
        await second.saveSettings(const AiRuntimeSettings()),
        AiSettingsSaveStatus.saved,
      );
    } finally {
      response.release();
    }
    final result = await running;
    expect(result.value, isNull);
    expect(result.status, isNot(AiRunStatus.ready));
    final saved = (await _ledger(secondStore)).report();
    expect((await _settings(secondStore)).route, AiRoute.offline);
    expect(saved.monthlyCapMicros, 0);
    expect(saved.chargedMicros, 4);
    expect(saved.unknownUsageCalls, 0);
  });

  test(
    'automatic dispatch verifies current policy after its attempt reservation',
    () async {
      final credentialRead = Completer<void>();
      final continueRead = Completer<void>();
      var reads = 0;
      var sends = 0;
      final first = _runtime(
        firstStore,
        (_) async {
          sends++;
          return _reply(_captureSource());
        },
        readCredential: (_) async {
          if (++reads == 2) {
            credentialRead.complete();
            await continueRead.future;
          }
          return _key;
        },
      );
      expect(
        await first.saveSettings(
          _paid(automatic: true),
          apiKey: _key,
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.saved,
      );
      final running = first.runAutomaticEstimate(
        candidate: AiEnrichmentCandidate(
          taskId: 'fixture-task',
          title: 'Draft a synthetic project brief',
          sourceRevision: 1,
          contextRevision: 2,
        ),
        currentRevision: (_) => (sourceRevision: 1, contextRevision: 2),
      );
      try {
        await credentialRead.future.timeout(_gateTimeout);
        expect((await _ledger(secondStore)).report().reservedMicros, _maximum);
        final second = _runtime(secondStore, _unexpected);
        expect(await second.load(), isTrue);
        expect(
          await second.saveSettings(const AiRuntimeSettings()),
          AiSettingsSaveStatus.saved,
        );
      } finally {
        continueRead.complete();
      }
      await running;
      expect(sends, 0);
      expect((await _settings(secondStore)).route, AiRoute.offline);
      final saved = (await _ledger(secondStore)).report();
      expect(saved.committedMicros, 0);
      expect(saved.unknownUsageCalls, 0);
    },
  );

  test(
    'failed transport retains the reservation through a lower remembered limit',
    () async {
      var sends = 0;
      final first = _runtime(firstStore, (_) async {
        sends++;
        throw StateError('Synthetic transport unavailable.');
      });
      final input = _captureSource();
      expect(
        await first.saveSettings(_paid(cap: _maximum), apiKey: _key),
        AiSettingsSaveStatus.saved,
      );
      expect((await _capture(first, input)).status, AiRunStatus.fallback);
      expect((await _capture(first, input)).status, AiRunStatus.fallback);
      expect(sends, 1);
      final second = _runtime(secondStore, _unexpected);
      expect(await second.load(), isTrue);
      expect(second.budget.chargedMicros, _maximum);
      expect(second.budget.unknownUsageCalls, 1);
      expect(
        await second.saveSettings(_paid(cap: _maximum - 1)),
        AiSettingsSaveStatus.saved,
      );
      expect(second.budget.remainingMicros, 0);
      expect(second.budget.discretionaryMicros, 0);
      expect(second.budget.chargedMicros, _maximum);
    },
  );
}

AiRuntime _runtime(
  AiDeviceState store,
  Future<http.StreamedResponse> Function(http.BaseRequest) send, {
  Future<String?> Function(String reference)? readCredential,
  AiRuntimeCompareAndSwap? compareAndSwap,
}) {
  final runtime = AiRuntime(
    read: store.read,
    compareAndSwap: compareAndSwap ?? store.compareAndSwap,
    vault: AiCallbackCredentialVault(
      readSecret: readCredential ?? (_) async => _key,
      writeSecret: (_, _) async {},
      deleteSecret: (_) async {},
    ),
    transport: _MockHttp(send),
    clock: () => _day,
  );
  addTearDown(runtime.dispose);
  return runtime;
}

class _MockHttp extends http.BaseClient {
  _MockHttp(this.sendRequest);

  final Future<http.StreamedResponse> Function(http.BaseRequest) sendRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      sendRequest(request);
}

class _GatedReply {
  _GatedReply(this.input, {this.inputTokens = 2});

  final CaptureInput input;
  final int inputTokens;
  final sent = Completer<void>();
  final _continue = Completer<void>();

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.complete();
    await _continue.future;
    return _reply(input, inputTokens: inputTokens);
  }

  void release() => _continue.complete();
}

Future<http.StreamedResponse> _unexpected(http.BaseRequest request) async =>
    fail('The mock transport should never be called.');

AiRuntimeSettings _paid({int cap = _cap, bool automatic = false}) =>
    AiRuntimeSettings(
      route: AiRoute.api,
      apiBaseUrl: 'https://fixture.invalid/v1',
      apiModel: 'fixture-model',
      monthlyCapMicros: cap,
      inputMicrosPerMillion: 1000000,
      outputMicrosPerMillion: 2000000,
      allowEstimates: automatic,
      automaticEstimates: automatic,
    );

CaptureInput _captureSource({String id = 'fixture-capture'}) => CaptureInput(
  id: id,
  revision: 1,
  text: 'Task: Send the synthetic brief',
  context: CaptureContext(anchor: _day),
);

Future<AiRuntimeOutcome<CaptureReview>> _capture(
  AiRuntime runtime,
  CaptureInput input,
) => runtime.runCapture(
  input: input,
  currentRevision: (id) => id == input.id
      ? (
          sourceRevision: input.revision,
          contextRevision: input.context.revision,
        )
      : null,
  authorize: (_) async => true,
);

Future<AiBudgetLedger> _ledger(AiDeviceState store) async =>
    _ledgerFrom((await store.read())!.value);

AiBudgetLedger _ledgerFrom(String value) => AiBudgetLedger.decode(
  jsonEncode((jsonDecode(value) as Map)['budget']),
  clock: () => _day,
);

Future<AiRuntimeSettings> _settings(AiDeviceState store) async =>
    AiRuntimeSettings.fromJson(
      (jsonDecode((await store.read())!.value) as Map)['settings']
          as Map<String, dynamic>,
    );

http.StreamedResponse _reply(CaptureInput input, {int inputTokens = 2}) {
  final content = jsonEncode({
    'version': 1,
    'captureId': input.id,
    'sourceRevision': input.revision,
    'contextRevision': input.context.revision,
    'proposals': [
      {
        'kind': 'task',
        'span': {'start': 0, 'end': input.text.length},
        'fields': {'title': 'Send the synthetic brief'},
      },
    ],
  });
  return http.StreamedResponse(
    Stream.value(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
          'usage': {'prompt_tokens': inputTokens, 'completion_tokens': 1},
        }),
      ),
    ),
    200,
  );
}
