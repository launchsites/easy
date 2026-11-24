import 'dart:convert';
import 'dart:io';

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _pound = 1000000;
const _cap = 40 * _pound;
const _maxInput = 4096;
const _maxOutput = 256;
const _taskRevision = (sourceRevision: 7, contextRevision: 11);
const _endpoint = 'https://budget-fixture.invalid/v1';
const _fixtureCredential = 'budget-fixture-only';

enum _Reply { knownUsage, malformedBody, noReply }

void main() {
  final results = <Map<String, Object?>>[];
  final started = Stopwatch()..start();

  test(
    '£1 per day under a £40 cap leaves bounded foreground automation',
    () async {
      final fixture = await _Fixture.open(quote: 50000);
      addTearDown(fixture.dispose);
      final runtime = fixture.runtime;
      final before = _budget(runtime);
      expect(before, {
        'charged_micros': 24000000,
        'reserved_micros': 0,
        'remaining_micros': 16000000,
        'projected_micros': 30000000,
        'discretionary_micros': 8000000,
        'unknown_usage_calls': 0,
      });

      runtime.setForeground(false);
      expect(await fixture.attempt('background'), AiRunStatus.blocked);
      runtime.setForeground(true);
      final burst = await Future.wait([
        for (var index = 0; index < 32; index++)
          fixture.attempt('burst-$index'),
      ]);
      expect(
        burst.where((status) => status == AiRunStatus.ready),
        hasLength(1),
      );
      expect(fixture.calls, 1);
      expect(runtime.pendingEstimates.single.requiresReview, isTrue);

      await fixture.reopen();
      expect(await fixture.attempt('same-minute-restart'), AiRunStatus.blocked);
      fixture.advance(14);
      expect(await fixture.attempt('fourteen-minutes'), AiRunStatus.blocked);
      fixture.advance(1);
      expect(await fixture.attempt('fifteen-minutes'), AiRunStatus.ready);
      for (var index = 3; index <= 12; index++) {
        fixture.advance(15);
        expect(await fixture.attempt('foreground-$index'), AiRunStatus.ready);
      }
      fixture.advance(15);
      expect(await fixture.attempt('daily-ceiling'), AiRunStatus.blocked);
      expect(fixture.calls, 12);
      expect(fixture.runtime.pendingEstimates, hasLength(12));
      expect(fixture.runtime.budget.remainingMicros, greaterThan(15000000));
      expect(fixture.store!.value, isNot(contains(_fixtureCredential)));
      expect(fixture.store!.value, isNot(contains('Synthetic duration title')));
      final beforeMidnight = _budget(fixture.runtime);
      fixture.now = DateTime.utc(2026, 11, 25, 9);
      expect(await fixture.attempt('following-day'), AiRunStatus.ready);
      expect(fixture.calls, 13);
      results.add({
        'case': 'forty_pounds_one_pound_per_day',
        'starting_budget': before,
        'burst_candidates': burst.length,
        'burst_dispatches': 1,
        'same_minute_after_restart_blocked': true,
        'minimum_gap_minutes': 15,
        'daily_dispatches': 12,
        'next_day_dispatches': 1,
        'after_day_budget': beforeMidnight,
      });
    },
  );

  test(
    'accrued allowance, daily share and projected cap all gate dispatch',
    () async {
      final cases = [
        (name: 'daily_share', history: 24 * _pound, quote: 1600000),
        (name: 'accrued_allowance', history: 31999000, quote: 50000),
        (name: 'projected_cap', history: 32 * _pound, quote: 50000),
        (name: 'projected_over_cap', history: 36 * _pound, quote: 50000),
      ];
      final rows = <Map<String, Object?>>[];
      for (final scenario in cases) {
        final fixture = await _Fixture.open(
          quote: scenario.quote,
          history: scenario.history,
        );
        try {
          expect(fixture.runtime.automaticEstimateOpportunity, isFalse);
          expect(await fixture.attempt(scenario.name), AiRunStatus.blocked);
          expect(fixture.calls, 0);
          expect(fixture.runtime.budget.remainingMicros, greaterThan(0));
          rows.add({
            'reason_fixture': scenario.name,
            'request_ceiling_micros': scenario.quote,
            ..._budget(fixture.runtime),
          });
        } finally {
          fixture.dispose();
        }
      }
      results.add({
        'case': 'headroom_gates',
        'dispatched': 0,
        'profiles': rows,
      });
    },
  );

  test(
    'quote size shifts the minimum gap at each allowance threshold',
    () async {
      final profiles = [
        (quote: 50000, minutes: 15),
        (quote: 100000, minutes: 30),
        (quote: 200000, minutes: 60),
        (quote: 410000, minutes: 120),
      ];
      final rows = <Map<String, int>>[];
      for (final profile in profiles) {
        final fixture = await _Fixture.open(quote: profile.quote);
        try {
          expect(await fixture.attempt('first'), AiRunStatus.ready);
          fixture.advance(profile.minutes - 1);
          expect(await fixture.attempt('early'), AiRunStatus.blocked);
          fixture.advance(1);
          expect(await fixture.attempt('threshold'), AiRunStatus.ready);
          expect(fixture.calls, 2);
          rows.add({
            'request_ceiling_micros': profile.quote,
            'minimum_gap_minutes': profile.minutes,
          });
        } finally {
          fixture.dispose();
        }
      }
      results.add({'case': 'quote_thresholds', 'profiles': rows});
    },
  );

  test(
    'disabled and background routes do not send automatic estimates',
    () async {
      final disabled = await _Fixture.open(quote: 50000, enabled: false);
      final fixture = await _Fixture.open(quote: 50000);
      addTearDown(disabled.dispose);
      addTearDown(fixture.dispose);
      fixture.runtime.setForeground(false);
      expect(await disabled.attempt('disabled'), AiRunStatus.blocked);
      expect(await fixture.attempt('background'), AiRunStatus.blocked);
      expect(disabled.calls + fixture.calls, 0);
      expect(fixture.runtime.budget.chargedMicros, 24000000);
      expect(fixture.runtime.pendingEstimates, isEmpty);
      results.add({'case': 'disabled_or_background', 'dispatched': 0});
    },
  );

  for (final reply in [_Reply.malformedBody, _Reply.noReply]) {
    test(
      'unknown usage settles at the reserved ceiling after ${reply.name}',
      () async {
        final fixture = await _Fixture.open(quote: 50000, reply: reply);
        addTearDown(fixture.dispose);
        final before = fixture.runtime.budget.chargedMicros;
        final started = Stopwatch()..start();
        final outcome = await fixture.attempt('unknown');
        expect(fixture.calls, 1);
        expect(outcome, isNot(AiRunStatus.ready));
        expect(fixture.runtime.pendingEstimates, isEmpty);
        expect(fixture.runtime.budget.chargedMicros - before, fixture.quote);
        expect(fixture.runtime.budget.reservedMicros, 0);
        expect(fixture.runtime.budget.unknownUsageCalls, 1);
        await fixture.reopen();
        expect(fixture.runtime.budget.chargedMicros - before, fixture.quote);
        expect(await fixture.attempt('duplicate'), AiRunStatus.blocked);
        expect(fixture.calls, 1);
        results.add({
          'case': reply.name,
          'dispatched': 1,
          'result': outcome.name,
          'reserved_ceiling_micros': fixture.quote,
          'settled_micros': fixture.runtime.budget.chargedMicros - before,
          'unknown_usage_calls': 1,
          'seconds': started.elapsedMilliseconds / 1000,
        });
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  tearDownAll(() async {
    final output = Platform.environment['EASY_ADAPTIVE_BUDGET_REPORT'];
    final revision = Platform.environment['EASY_ADAPTIVE_BUDGET_REVISION'];
    if (output == null || revision == null || results.length != 6) return;
    final report = {
      'run_at_utc': DateTime.now().toUtc().toIso8601String(),
      'source_revision': revision,
      'profile': 'fake HTTP client and revision-checked state store',
      'paid_network_requests': 0,
      'elapsed_seconds': started.elapsedMilliseconds / 1000,
      'results': results,
    };
    await File(
      output,
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  });
}

Map<String, int> _budget(AiRuntime runtime) {
  final budget = runtime.budget;
  return {
    'charged_micros': budget.chargedMicros,
    'reserved_micros': budget.reservedMicros,
    'remaining_micros': budget.remainingMicros,
    'projected_micros': budget.projectedMicros,
    'discretionary_micros': budget.discretionaryMicros,
    'unknown_usage_calls': budget.unknownUsageCalls,
  };
}

class _Fixture {
  _Fixture(this.quote, this.reply, this.settings);

  final int quote;
  final _Reply reply;
  final AiRuntimeSettings settings;
  final vault = AiSessionCredentialVault();
  DateTime now = DateTime.utc(2026, 11, 24, 9);
  AiStoredState? store;
  late AiRuntime runtime;
  var calls = 0;

  static Future<_Fixture> open({
    required int quote,
    int history = 24 * _pound,
    bool enabled = true,
    _Reply reply = _Reply.knownUsage,
  }) async {
    final settings = AiRuntimeSettings(
      route: AiRoute.api,
      apiBaseUrl: _endpoint,
      apiModel: 'budget-fixture',
      monthlyCapMicros: _cap,
      inputMicrosPerMillion: quote * 1000000 ~/ _maxInput,
      outputMicrosPerMillion: 0,
      maxInputTokens: _maxInput,
      maxOutputTokens: _maxOutput,
      allowEstimates: true,
      automaticEstimates: enabled,
      adaptiveEstimatePacing: enabled,
    );
    final fixture = _Fixture(quote, reply, settings);
    var day = DateTime.utc(2026, 11);
    final ledger = AiBudgetLedger(
      monthlyCapMicros: _cap,
      currency: 'GBP',
      clock: () => day,
    );
    for (var index = 1; index <= 24; index++) {
      day = DateTime.utc(2026, 11, index);
      final amount = history ~/ 24 + (index <= history % 24 ? 1 : 0);
      final id = 'known-$index';
      final reserved = ledger.reserve(
        AiBudgetRequest(
          id: id,
          maxInputTokens: 1000000,
          maxOutputTokens: 1,
          price: AiPrice(
            currency: 'GBP',
            inputMicrosPerMillion: amount,
            outputMicrosPerMillion: 0,
          ),
        ),
      );
      expect(reserved.approved, isTrue);
      ledger.settle(
        id,
        actual: const AiTokenUsage(inputTokens: 1000000, outputTokens: 0),
      );
    }
    fixture.store = AiStoredState(
      revision: 1,
      value: jsonEncode({
        'version': 1,
        'settings': settings.toJson(),
        'budget': jsonDecode(ledger.encode()),
      }),
    );
    await fixture.vault.write(
      settings.apiCredentialReference!,
      _fixtureCredential,
    );
    await fixture.load();
    return fixture;
  }

  Future<void> load() async {
    runtime = AiRuntime(
      clock: () => now,
      read: () async => store,
      compareAndSwap: (expected, value) async {
        if (expected != (store?.revision ?? 0)) return null;
        store = AiStoredState(revision: expected + 1, value: value);
        return store!.revision;
      },
      vault: vault,
      transport: _FakeClient(_handle),
    );
    expect(await runtime.load(), isTrue);
  }

  void dispose() => runtime.dispose();

  Future<void> reopen() async {
    dispose();
    await load();
  }

  void advance(int minutes) => now = now.add(Duration(minutes: minutes));

  Future<AiRunStatus> attempt(String id) async {
    final result = await runtime.runAutomaticEstimate(
      candidate: AiEnrichmentCandidate(
        taskId: id,
        title: 'Synthetic duration title',
        sourceRevision: _taskRevision.sourceRevision,
        contextRevision: _taskRevision.contextRevision,
      ),
      currentRevision: (key) => key == id ? _taskRevision : null,
    );
    return result.status;
  }

  Future<http.StreamedResponse> _handle(http.BaseRequest request) async {
    calls++;
    expect(request.url.host, 'budget-fixture.invalid');
    expect(request.url.scheme, 'https');
    final onDisk = jsonDecode(store!.value) as Map;
    final ledger = AiBudgetLedger.decode(
      jsonEncode(onDisk['budget']),
      clock: () => now,
    );
    expect(ledger.report().reservedMicros, quote);
    expect(ledger.report().committedMicros, lessThanOrEqualTo(_cap));
    if (reply == _Reply.noReply) {
      final abort = (request as http.AbortableRequest).abortTrigger!;
      await abort;
      throw const SocketException('Synthetic client aborted');
    }
    if (reply == _Reply.malformedBody) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('malformed response')),
        200,
      );
    }
    final body = jsonDecode((request as http.Request).body) as Map;
    final messages = body['messages'] as List;
    final fields =
        jsonDecode((messages.last as Map)['content'] as String) as Map;
    final answer = {
      for (final key in ['captureId', 'sourceRevision', 'contextRevision'])
        key: fields[key],
      'minutes': 35,
    };
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(answer)},
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 4},
          }),
        ),
      ),
      200,
    );
  }
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
