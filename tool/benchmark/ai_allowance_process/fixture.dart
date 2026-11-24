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
final _day = DateTime.utc(2026, 11, 24);

void peerFixture({required bool isFirst}) {
  test(
    'native process ${isFirst ? 'A' : 'B'} verifies paid state and dispatch',
    () async {
      final path = Platform.environment['EASY_ALLOWANCE_PROCESS_FIXTURE'];
      if (path == null || !Directory(path).isAbsolute) {
        throw StateError('Provide an absolute disposable fixture directory.');
      }
      final directory = Directory(path);
      if (!await directory.exists() ||
          (isFirst && !await directory.list().isEmpty)) {
        throw StateError('Expected a fresh fixture directory.');
      }
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final checkPolicy =
          Platform.environment['EASY_ALLOWANCE_POLICY_ACK'] == '1';
      final files = _Markers(directory);
      var now = DateTime.utc(2026, 11, 30, 23, 59, 59, 999);
      final november = AiBudgetMonth.of(now);
      final december = DateTime.utc(2026, 12);
      final input = _captureSource();
      if (!isFirst) await files.read('a-started');
      final store = await AiDeviceState.open(
        preferences: SharedPreferencesAsync(),
        databasePath: directory.uri.resolve('allowance.sqlite3').toFilePath(),
      );
      addTearDown(store.close);

      Future<AiBudgetLedger> ledger() async => AiBudgetLedger.decode(
        jsonEncode((jsonDecode((await store.read())!.value) as Map)['budget']),
        clock: () => now,
      );

      if (isFirst) {
        var gate = _Acknowledgement.none;
        var sends = 0;
        final first = _runtime(
          store,
          (_) async {
            sends++;
            if (gate != _Acknowledgement.none) {
              fail('An obsolete reservation entered transport.');
            }
            await files.write('a-on-wire', {'pid': pid});
            final second = await files.read('b-settled');
            expect(second['pid'], isNot(pid));
            expect(second['charge'], 7);
            return _reply(input);
          },
          clock: () => now,
          compareAndSwap: (rev, data) async {
            final saved = await store.compareAndSwap(rev, data);
            if (saved != null &&
                gate != _Acknowledgement.none &&
                _ledgerFrom(data).reservations.last.isActive) {
              if (gate == _Acknowledgement.midnight) {
                await files.write('a-before-midnight', {'pid': pid});
                await files.read('b-roll');
                now = december;
              } else {
                await files.write('a-policy-reserved', {'pid': pid});
                await files.read('b-policy-disabled');
              }
            }
            return saved;
          },
        );
        expect(
          await first.saveSettings(_paid(), apiKey: _key),
          AiSettingsSaveStatus.saved,
        );
        await files.write('a-started', {'pid': pid});
        expect((await _capture(first, input)).status, AiRunStatus.ready);
        expect((await ledger()).report().chargedMicros, 11);
        expect(
          await first.saveSettings(_paid(cap: _maximum + 11)),
          AiSettingsSaveStatus.saved,
        );
        gate = _Acknowledgement.midnight;
        expect((await _capture(first, input)).status, AiRunStatus.fallback);
        expect(sends, 1);
        final saved = await ledger();
        expect(saved.report(month: november).chargedMicros, 11);
        expect(saved.report(month: november).reservedMicros, 0);
        expect(saved.reservations.last.usageBasis, AiUsageBasis.notDispatched);
        await files.write('a-after-midnight', {'pid': pid});
        final last = await files.read('b-december');
        expect(last['charge'], _maximum);
        expect(last['pid'], isNot(pid));
        if (checkPolicy) {
          expect(await first.load(refresh: true), isTrue);
          expect(
            await first.saveSettings(_paid(cap: 2 * _maximum)),
            AiSettingsSaveStatus.saved,
          );
          gate = _Acknowledgement.policy;
          await _capture(first, input);
          expect(sends, 1);
          final afterPolicy = (await ledger()).report();
          expect(afterPolicy.monthlyCapMicros, 0);
          expect(afterPolicy.chargedMicros, _maximum);
          expect(afterPolicy.reservedMicros, 0);
          await files.write('a-policy-preserved', {'pid': pid});
          await files.read('b-policy-verified');
        }
        await files.write('verified', {
          'distinct_os_processes': true,
          'reverse_order_actual_micros': 11,
          'no_dispatch_for_previous_month_reservation': true,
          'first_new_month_dispatch_reserved_micros': _maximum,
          'new_month_dispatches_after_exact_charge': 0,
          if (checkPolicy) 'dispatches_after_policy_disabled_during_ack': 0,
          if (checkPolicy)
            'unused_reservation_released_after_policy_change': true,
        });
      } else {
        final prior = await files.read('a-on-wire');
        expect(prior['pid'], isNot(pid));
        var sends = 0;
        final second = _runtime(store, (_) async {
          sends++;
          final reserved = (await ledger()).report();
          expect(reserved.reservedMicros, _maximum * 2);
          return _reply(input, inputTokens: 5);
        }, clock: () => now);
        expect((await _capture(second, input)).status, AiRunStatus.ready);
        expect(sends, 1);
        final interim = (await ledger()).report();
        expect(interim.chargedMicros, 7);
        expect(interim.reservedMicros, _maximum);
        await files.write('b-settled', {
          'pid': pid,
          'charge': interim.chargedMicros,
        });

        await files.read('a-before-midnight');
        expect((await ledger()).report().reservedMicros, _maximum);
        await files.write('b-roll', {'pid': pid});
        await files.read('a-after-midnight');
        now = december;
        final reopened = _runtime(store, (_) async {
          sends++;
          expect((await ledger()).report().reservedMicros, _maximum);
          return _reply(input, inputTokens: 8192, outputTokens: 512);
        }, clock: () => now);
        expect((await _capture(reopened, input)).status, AiRunStatus.ready);
        expect((await _capture(reopened, input)).status, AiRunStatus.fallback);
        expect(sends, 2);
        final finalLedger = await ledger();
        expect(finalLedger.report().chargedMicros, _maximum);
        expect(finalLedger.report().remainingMicros, 11);
        expect(finalLedger.report(month: november).chargedMicros, 11);
        await files.write('b-december', {
          'pid': pid,
          'charge': finalLedger.report().chargedMicros,
        });
        if (checkPolicy) {
          await files.read('a-policy-reserved');
          expect((await ledger()).report().reservedMicros, _maximum);
          expect(await reopened.load(refresh: true), isTrue);
          expect(
            await reopened.saveSettings(const AiRuntimeSettings()),
            AiSettingsSaveStatus.saved,
          );
          await files.write('b-policy-disabled', {'pid': pid});
          await files.read('a-policy-preserved');
          final afterPolicy = (await ledger()).report();
          expect(afterPolicy.chargedMicros, _maximum);
          expect(afterPolicy.reservedMicros, 0);
          await files.write('b-policy-verified', {'pid': pid});
        }
      }
    },
  );
}

enum _Acknowledgement { none, midnight, policy }

class _Markers {
  _Markers(this.directory);
  final Directory directory;

  Future<void> write(String name, Map<String, Object> value) async {
    final temporary = File('${directory.path}/$name.partial');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename('${directory.path}/$name.json');
  }

  Future<Map<String, dynamic>> read(String name) async {
    final file = File('${directory.path}/$name.json');
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 20)) {
      if (await file.exists()) {
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    throw StateError('Timed out waiting for worker phase $name.');
  }
}

AiRuntime _runtime(
  AiDeviceState store,
  Future<http.StreamedResponse> Function(http.BaseRequest) send, {
  Future<String?> Function(String reference)? readCredential,
  AiRuntimeCompareAndSwap? compareAndSwap,
  DateTime Function()? clock,
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
    clock: clock ?? () => _day,
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

AiBudgetLedger _ledgerFrom(String value) => AiBudgetLedger.decode(
  jsonEncode((jsonDecode(value) as Map)['budget']),
  clock: () => _day,
);

http.StreamedResponse _reply(
  CaptureInput input, {
  int inputTokens = 2,
  int outputTokens = 1,
}) {
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
          'usage': {
            'prompt_tokens': inputTokens,
            'completion_tokens': outputTokens,
          },
        }),
      ),
    ),
    200,
  );
}
