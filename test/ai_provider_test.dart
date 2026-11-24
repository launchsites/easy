import 'dart:async';
import 'dart:convert';

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/inference_jobs.dart';
import 'package:easy/ai/provider/ai_provider.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
    'paid capture persists its reservation before one bounded request',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      final provider = fixture.provider((request) async {
        expect(request, isA<http.AbortableRequest>());
        expect(
          request.url.toString(),
          'https://example.test/v1/chat/completions',
        );
        expect(request.method, 'POST');
        expect(request.followRedirects, false);
        expect(request.maxRedirects, 0);
        expect(request.headers['authorization'], 'Bearer $_fakeKey');
        expect(fixture.saved, hasLength(1));
        final persisted = AiBudgetLedger.decode(
          fixture.saved.single,
          clock: _clock,
        );
        expect(persisted.report().reservedMicros, 10300);
        final body = (request as http.Request).body;
        expect(body, isNot(contains(_fakeKey)));
        expect(body, isNot(contains('unrelated private record')));
        expect(body, isNot(contains('unrelated private category')));
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['max_completion_tokens'], 100);
        expect(json['stream'], false);
        return _completion(
          _captureOutput(fixture.input),
          input: 20,
          outputTokens: 6,
        );
      });

      final claim = fixture.claim(config);
      final result = await provider.capture(
        config: config,
        claim: claim,
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      expect(result.succeeded, true);
      expect(result.value!.proposals.single.draft.title, 'Send the brief');
      expect(result.accounting!.chargedMicros, 38);
      expect(fixture.ledger.report().reservedMicros, 0);
      expect(fixture.vault.references, ['test-reference']);
      expect(fixture.saved, hasLength(2));
      expect(
        fixture.saved.every((snapshot) => !snapshot.contains(_fakeKey)),
        true,
      );
      expect(
        AiBudgetLedger.decode(
          fixture.saved.last,
          clock: _clock,
        ).report().chargedMicros,
        38,
      );
    },
  );

  test(
    'endpoint validation rejects insecure paid hosts and loopback lookalikes',
    () async {
      for (final address in [
        'http://example.test/v1',
        'https://user@example.test/v1',
        'https://example.test/v1?secret=query',
        'https://example.test/v1#other',
        'https://example.test/v1/%2felsewhere',
        'https://example.test/v1//other',
      ]) {
        final fixture = _Fixture();
        final config = _paid(address: address);
        final result = await fixture
            .provider(_unexpected)
            .capture(
              config: config,
              claim: fixture.claim(config),
              input: fixture.input,
              currentRevision: fixture.currentRevision,
            );
        expect(
          result.failure,
          AiProviderFailure.invalidConfiguration,
          reason: address,
        );
        expect(result.accounting!.usageBasis, AiUsageBasis.notDispatched);
        expect(fixture.vault.references, isEmpty);
      }

      for (final address in [
        'http://localhost:8800/v1',
        'http://127.0.0.1.example.test/v1',
        'http://0.0.0.0/v1',
        'http://192.168.1.5/v1',
        'http://[::ffff:127.0.0.1]/v1',
      ]) {
        expect(
          _local(address: address).completionsEndpoint,
          isNull,
          reason: address,
        );
      }
      expect(
        _local(address: 'http://[::1]:8800/v1').completionsEndpoint!.host,
        '::1',
      );
    },
  );

  test(
    'explicit local requests carry no credential and no budget write',
    () async {
      final fixture = _Fixture();
      final config = _local();
      final provider = fixture.provider((request) async {
        expect(
          request.url.toString(),
          'http://127.0.0.1:8800/v1/chat/completions',
        );
        expect(request.headers.containsKey('authorization'), false);
        expect(request.followRedirects, false);
        final body =
            jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        expect(body['max_tokens'], 100);
        expect(body.containsKey('response_format'), false);
        return _completion(_captureOutput(fixture.input));
      });
      final result = await provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      expect(result.succeeded, true);
      expect(result.accounting, isNull);
      expect(fixture.vault.references, isEmpty);
      expect(fixture.saved, isEmpty);
    },
  );

  test(
    'invalid vault data and a failed persisted reservation prevent dispatch',
    () async {
      final invalidKey = _Fixture(vaultValue: '$_fakeKey\n');
      final config = _paid();
      final blocked = await invalidKey
          .provider(_unexpected)
          .capture(
            config: config,
            claim: invalidKey.claim(config),
            input: invalidKey.input,
            currentRevision: invalidKey.currentRevision,
          );
      expect(blocked.failure, AiProviderFailure.credentialsUnavailable);
      expect(blocked.accounting!.usageBasis, AiUsageBasis.notDispatched);

      final failedDisk = _Fixture();
      final result = await failedDisk
          .provider(
            _unexpected,
            persist: (_) async => throw StateError('storage unavailable'),
          )
          .capture(
            config: config,
            claim: failedDisk.claim(config),
            input: failedDisk.input,
            currentRevision: failedDisk.currentRevision,
          );
      expect(result.failure, AiProviderFailure.accountingUnavailable);
      expect(failedDisk.ledger.report().committedMicros, 0);
    },
  );

  test(
    'a change while saving the reservation cancels before the transport',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      final writing = Completer<void>();
      final allowWrite = Completer<void>();
      final provider = fixture.provider(
        _unexpected,
        persist: (text) async {
          if (!writing.isCompleted) writing.complete();
          await allowWrite.future;
          fixture.saved.add(text);
        },
      );
      final pending = provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      await writing.future;
      fixture.revision = (sourceRevision: 5, contextRevision: 3);
      allowWrite.complete();
      final result = await pending;
      expect(result.failure, AiProviderFailure.stale);
      expect(result.accounting!.usageBasis, AiUsageBasis.notDispatched);
      expect(fixture.saved, hasLength(2));
      expect(fixture.ledger.report().committedMicros, 0);
    },
  );

  test(
    'redirect response is rejected without sending credentials elsewhere',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      var requests = 0;
      final provider = fixture.provider((request) async {
        requests++;
        expect(request.followRedirects, false);
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"unexpected":"redirect"}')),
          302,
          headers: {'location': 'https://other.example.test/receive'},
        );
      });
      final result = await provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      expect(requests, 1);
      expect(result.failure, AiProviderFailure.providerRejected);
      expect(result.statusCode, 302);
      expect(result.accounting!.usageBasis, AiUsageBasis.reservedMaximum);
    },
  );

  test(
    'bounded response does not keep reading or refund a possibly billed call',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      late Future<void> aborted;
      final provider = fixture.provider((request) async {
        aborted = (request as http.AbortableRequest).abortTrigger!;
        return http.StreamedResponse(
          Stream.fromIterable([List.filled(40, 65), List.filled(40, 66)]),
          200,
        );
      }, maxResponseBytes: 64);
      final result = await provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      await aborted;
      expect(result.failure, AiProviderFailure.responseTooLarge);
      expect(result.accounting!.chargedMicros, 10300);
    },
  );

  test(
    'transport timeout aborts a lost reply and conservatively accounts for it',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      final reply = Completer<http.StreamedResponse>();
      final provider = fixture.provider((request) {
        final transportRequest = request as http.AbortableRequest;
        unawaited(
          transportRequest.abortTrigger!.then((_) {
            reply.completeError(StateError('lost response'));
          }),
        );
        return reply.future;
      }, timeout: const Duration(milliseconds: 30));
      final result = await provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      expect(result.failure, AiProviderFailure.timedOut);
      expect(result.accounting!.chargedMicros, 10300);
      expect(fixture.ledger.report().unknownUsageCalls, 1);
    },
  );

  test(
    'cancelled local claim aborts transport and hides its late result',
    () async {
      final fixture = _Fixture();
      final config = _local();
      final started = Completer<http.AbortableRequest>();
      final response = Completer<http.StreamedResponse>();
      final provider = fixture.provider((request) {
        started.complete(request as http.AbortableRequest);
        return response.future;
      });
      final claim = fixture.claim(config);
      final pending = provider.capture(
        config: config,
        claim: claim,
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      final request = await started.future;
      fixture.queue.setForeground(false);
      await request.abortTrigger!;
      expect((await pending).failure, AiProviderFailure.cancelled);
      response.complete(_completion(_captureOutput(fixture.input)));
      expect(fixture.vault.references, isEmpty);
      expect(fixture.saved, isEmpty);
    },
  );

  test('a terminal or replayed claim cannot start another request', () async {
    final fixture = _Fixture();
    final config = _paid();
    final claim = fixture.claim(config);
    final started = Completer<void>();
    final response = Completer<http.StreamedResponse>();
    final pending = fixture
        .provider((_) {
          started.complete();
          return response.future;
        })
        .capture(
          config: config,
          claim: claim,
          input: fixture.input,
          currentRevision: fixture.currentRevision,
        );
    await started.future;
    final duplicate = await fixture
        .provider(_unexpected)
        .capture(
          config: config,
          claim: claim,
          input: fixture.input,
          currentRevision: fixture.currentRevision,
        );
    expect(duplicate.failure, AiProviderFailure.duplicateCall);
    expect(claim.reservation!.isActive, true);
    response.complete(_completion(_captureOutput(fixture.input)));
    expect((await pending).succeeded, true);

    final ended = _Fixture();
    final unused = ended.claim(config);
    expect(
      ended.queue.fail(unused, currentRevision: ended.currentRevision),
      true,
    );
    final blocked = await ended
        .provider(_unexpected)
        .capture(
          config: config,
          claim: unused,
          input: ended.input,
          currentRevision: ended.currentRevision,
        );
    expect(blocked.failure, AiProviderFailure.stale);
    expect(blocked.accounting!.usageBasis, AiUsageBasis.notDispatched);
    expect(ended.vault.references, isEmpty);
  });

  test('a stale late response still settles verified paid usage', () async {
    final fixture = _Fixture();
    final config = _paid();
    final result = await fixture
        .provider((_) async {
          fixture.revision = (sourceRevision: 99, contextRevision: 3);
          return _completion(
            _captureOutput(fixture.input),
            input: 7,
            outputTokens: 3,
          );
        })
        .capture(
          config: config,
          claim: fixture.claim(config),
          input: fixture.input,
          currentRevision: fixture.currentRevision,
        );
    expect(result.failure, AiProviderFailure.stale);
    expect(result.value, isNull);
    expect(result.accounting!.chargedMicros, 16);
  });

  test('budget writes stay ordered across clients using one ledger', () async {
    final first = _Fixture();
    final second = _Fixture(sharedLedger: first.ledger);
    final config = _paid();
    final entered = Completer<void>();
    final releaseWrite = Completer<void>();
    final snapshots = <String>[];
    var writing = false;
    var overlap = false;
    Future<void> persist(String state) async {
      if (writing) overlap = true;
      writing = true;
      if (!entered.isCompleted) {
        entered.complete();
        await releaseWrite.future;
      }
      snapshots.add(state);
      writing = false;
    }

    Future<AiProviderResult<CaptureReview>> launch(
      _Fixture fixture,
      String id,
    ) => fixture
        .provider(
          (_) async => _completion(
            _captureOutput(fixture.input),
            input: 1,
            outputTokens: 1,
          ),
          persist: persist,
        )
        .capture(
          config: config,
          claim: fixture.claim(config, id: id),
          input: fixture.input,
          currentRevision: fixture.currentRevision,
        );

    final a = launch(first, 'a');
    await entered.future;
    final b = launch(second, 'b');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, isEmpty);
    releaseWrite.complete();
    final results = await Future.wait([a, b]);
    expect(results.every((result) => result.succeeded), true);
    expect(overlap, false);
    final restored = AiBudgetLedger.decode(snapshots.last, clock: _clock);
    expect(restored.report().chargedMicros, 8);
    expect(restored.report().reservedMicros, 0);
  });

  test(
    'configured token bound blocks oversized messages before reading a key',
    () async {
      final fixture = _Fixture();
      final config = _paid(maxInputTokens: 64);
      final result = await fixture
          .provider(_unexpected)
          .capture(
            config: config,
            claim: fixture.claim(config),
            input: fixture.input,
            currentRevision: fixture.currentRevision,
          );
      expect(result.failure, AiProviderFailure.requestTooLarge);
      expect(result.accounting!.usageBasis, AiUsageBasis.notDispatched);
      expect(fixture.vault.references, isEmpty);
    },
  );

  test(
    'invalid structured output has no authority and verified usage settles',
    () async {
      final fixture = _Fixture();
      final config = _paid();
      final output = _captureOutput(fixture.input)..['deleteAll'] = _fakeKey;
      final provider = fixture.provider(
        (_) async => _completion(output, input: 2, outputTokens: 1),
      );
      final result = await provider.capture(
        config: config,
        claim: fixture.claim(config),
        input: fixture.input,
        currentRevision: fixture.currentRevision,
      );
      expect(result.failure, AiProviderFailure.invalidResponse);
      expect(result.value, isNull);
      expect(result.accounting!.chargedMicros, 5);
      expect(
        fixture.saved.every((snapshot) => !snapshot.contains(_fakeKey)),
        true,
      );
    },
  );

  test(
    'optional estimates require discretionary work and strict reviewed values',
    () async {
      final disabled = _Fixture();
      final missingConsent = _paid();
      final input = AiEstimateInput(title: 'Draft brief');
      final refused = await disabled
          .provider(_unexpected)
          .estimate(
            config: missingConsent,
            claim: disabled.claim(
              missingConsent,
              work: AiWorkKind.discretionary,
            ),
            input: input,
            currentRevision: disabled.currentRevision,
          );
      expect(refused.failure, AiProviderFailure.invalidRequest);
      expect(refused.accounting!.usageBasis, AiUsageBasis.notDispatched);

      final fixture = _Fixture();
      final config = _paid(allowEstimates: true);
      final response = {
        'captureId': fixture.input.id,
        'sourceRevision': fixture.input.revision,
        'contextRevision': fixture.input.context.revision,
        'minutes': 45,
      };
      final result = await fixture
          .provider((_) async => _completion(response))
          .estimate(
            config: config,
            claim: fixture.claim(config, work: AiWorkKind.discretionary),
            input: input,
            currentRevision: fixture.currentRevision,
          );
      expect(result.value!.requiresReview, true);
      expect(result.value!.duration, const Duration(minutes: 45));
      expect(result.value!.title, 'Draft brief');

      final invalid = _Fixture();
      final rejected = await invalid
          .provider((_) async => _completion(response..['minutes'] = 45.0))
          .estimate(
            config: config,
            claim: invalid.claim(config, work: AiWorkKind.discretionary),
            input: input,
            currentRevision: invalid.currentRevision,
          );
      expect(rejected.failure, AiProviderFailure.invalidResponse);
    },
  );
}

const _fakeKey = 'test-only-key';
const _price = AiPrice(
  currency: 'GBP',
  inputMicrosPerMillion: 1000000,
  outputMicrosPerMillion: 3000000,
);

DateTime _clock() => DateTime.utc(2026, 11, 24);

AiProviderConfig _paid({
  String address = 'https://example.test/v1',
  bool allowEstimates = false,
  int maxInputTokens = 10000,
}) => AiProviderConfig.paid(
  baseUri: Uri.parse(address),
  model: 'fixture-model',
  credentialRef: 'test-reference',
  price: _price,
  maxInputTokens: maxInputTokens,
  maxOutputTokens: 100,
  allowEstimates: allowEstimates,
);

AiProviderConfig _local({String address = 'http://127.0.0.1:8800/v1'}) =>
    AiProviderConfig.loopback(
      baseUri: Uri.parse(address),
      model: 'local-fixture',
      maxInputTokens: 10000,
      maxOutputTokens: 100,
    );

class _Fixture {
  _Fixture({String? vaultValue = _fakeKey, AiBudgetLedger? sharedLedger})
    : vault = _Vault(vaultValue),
      ledger =
          sharedLedger ??
          AiBudgetLedger(
            monthlyCapMicros: 1000000,
            currency: 'GBP',
            clock: _clock,
          );

  final _Vault vault;
  final queue = AiInferenceQueue(foreground: true, clock: _clock);
  final AiBudgetLedger ledger;
  final saved = <String>[];
  final input = CaptureInput(
    id: 'capture',
    revision: 4,
    text: 'Task: Send the brief',
    context: CaptureContext(
      anchor: _clock(),
      revision: 3,
      categories: const {'personal': 'unrelated private category'},
      records: const [
        CaptureRecordRef(
          id: 'off-scope',
          kind: CaptureIntentKind.note,
          title: 'unrelated private record',
          revision: 1,
        ),
      ],
    ),
  );
  AiCaptureRevision revision = (sourceRevision: 4, contextRevision: 3);

  AiCaptureRevision? currentRevision(String id) =>
      id == input.id ? revision : null;

  AiInferenceClaim claim(
    AiProviderConfig config, {
    AiWorkKind work = AiWorkKind.interactive,
    String id = 'fixture-request',
  }) {
    queue.enqueue(
      AiInferenceRequest(
        id: id,
        captureId: input.id,
        sourceRevision: input.revision,
        contextRevision: input.context.revision,
        execution: config.execution,
        work: work,
      ),
    );
    return queue.claimNext(
      currentRevision: currentRevision,
      reservePaid: (request) => ledger
          .reserve(config.budgetRequest(request.id, work: request.work))
          .reservation,
    )!;
  }

  AiProviderClient provider(
    Future<http.StreamedResponse> Function(http.BaseRequest) send, {
    AiPersistBudget? persist,
    Duration timeout = const Duration(seconds: 1),
    int maxResponseBytes = 128 * 1024,
  }) => AiProviderClient(
    transport: _MockHttp(send),
    vault: vault,
    ledger: ledger,
    persistBudget: persist ?? (state) async => saved.add(state),
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
  );
}

class _Vault implements AiCredentialVault {
  _Vault(this.value);

  final String? value;
  final references = <String>[];

  @override
  Future<String?> read(String reference) async {
    references.add(reference);
    return value;
  }
}

class _MockHttp extends http.BaseClient {
  _MockHttp(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

Future<http.StreamedResponse> _unexpected(http.BaseRequest request) async {
  fail('The mock transport should never be called.');
}

Map<String, Object> _captureOutput(CaptureInput input) => {
  'version': 1,
  'captureId': input.id,
  'sourceRevision': input.revision,
  'contextRevision': input.context.revision,
  'proposals': [
    {
      'kind': 'task',
      'span': {'start': 0, 'end': input.text.length},
      'fields': {'title': 'Send the brief'},
    },
  ],
};

http.StreamedResponse _completion(
  Map<String, Object> output, {
  int? input,
  int? outputTokens,
}) {
  final response = jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(output)},
        'finish_reason': 'stop',
      },
    ],
    if (input != null)
      'usage': {'prompt_tokens': input, 'completion_tokens': outputTokens},
  });
  return http.StreamedResponse(Stream.value(utf8.encode(response)), 200);
}
