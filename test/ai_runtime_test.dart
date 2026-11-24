import 'dart:async';
import 'dart:convert';

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/ai/ai_settings_page.dart';
import 'package:easy/ai/task_estimates_page.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:easy/task_context/task_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'a failed replacement key never activates automatic paid estimates',
    () async {
      final store = _Store();
      final keys = <String, String>{};
      var rejectWrites = false;
      final vault = AiCallbackCredentialVault(
        readSecret: (ref) async => keys[ref],
        writeSecret: (ref, value) async {
          if (rejectWrites) throw StateError('Synthetic device vault failure.');
          keys[ref] = value;
        },
        deleteSecret: (ref) async => keys.remove(ref),
      );
      final runtime = store.runtime(vault: vault);
      addTearDown(runtime.dispose);
      expect(
        await runtime.saveSettings(_paid(), apiKey: _testKey),
        AiSettingsSaveStatus.saved,
      );
      rejectWrites = true;
      expect(
        await runtime.saveSettings(
          _paid(automatic: true),
          apiKey: 'synthetic-replacement-key',
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.vaultUnavailable,
      );
      expect(keys.values, [_testKey]);
      expect(runtime.settings.automaticEstimates, isFalse);

      final reopened = store.runtime(vault: vault);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.settings.automaticEstimates, isFalse);
    },
  );

  test(
    'rotating the active paid key pauses automation before the vault write',
    () async {
      final store = _Store();
      final keys = <String, String>{};
      final writeStarted = Completer<void>();
      final failWrite = Completer<void>();
      final vault = AiCallbackCredentialVault(
        readSecret: (ref) async => keys[ref],
        writeSecret: (ref, value) async {
          if (value != _testKey) {
            writeStarted.complete();
            await failWrite.future;
            throw StateError('Synthetic device vault failure.');
          }
          keys[ref] = value;
        },
        deleteSecret: (ref) async => keys.remove(ref),
      );
      final runtime = store.runtime(vault: vault);
      addTearDown(runtime.dispose);
      expect(
        await runtime.saveSettings(
          _paid(automatic: true),
          apiKey: _testKey,
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.saved,
      );

      final pending = runtime.saveSettings(
        _paid(automatic: true),
        apiKey: 'synthetic-replacement-key',
      );
      await writeStarted.future;
      final reopened = store.runtime(vault: vault);
      addTearDown(reopened.dispose);
      try {
        await reopened.load();
        expect(reopened.settings.automaticEstimates, isFalse);
      } finally {
        failWrite.complete();
        expect(await pending, AiSettingsSaveStatus.vaultUnavailable);
      }
      expect(runtime.settings.automaticEstimates, isFalse);
      expect(keys.values, [_testKey]);
    },
  );

  test(
    'a stale settings instance leaves the device credential untouched',
    () async {
      final store = _Store();
      final keys = <String, String>{};
      final vault = AiCallbackCredentialVault(
        readSecret: (ref) async => keys[ref],
        writeSecret: (ref, value) async => keys[ref] = value,
        deleteSecret: (ref) async => keys.remove(ref),
      );
      final active = store.runtime(vault: vault);
      addTearDown(active.dispose);
      expect(
        await active.saveSettings(_paid(), apiKey: _testKey),
        AiSettingsSaveStatus.saved,
      );
      final stale = store.runtime(vault: vault);
      addTearDown(stale.dispose);
      expect(await stale.load(), isTrue);
      expect(
        await active.saveSettings(_paid(model: 'confirmed-model')),
        AiSettingsSaveStatus.saved,
      );
      expect(
        await stale.saveSettings(
          _paid(model: 'stale-model'),
          apiKey: 'synthetic-replacement-key',
        ),
        AiSettingsSaveStatus.storageUnavailable,
      );
      expect(keys.values, [_testKey]);
    },
  );

  test(
    'a final settings write failure leaves automation paused after rotation',
    () async {
      final store = _Store();
      final keys = <String, String>{};
      final vault = AiCallbackCredentialVault(
        readSecret: (ref) async => keys[ref],
        writeSecret: (ref, value) async {
          keys[ref] = value;
          if (value != _testKey) store.rejectWrites = true;
        },
        deleteSecret: (ref) async => keys.remove(ref),
      );
      final runtime = store.runtime(vault: vault);
      addTearDown(runtime.dispose);
      final settings = _paid(automatic: true);
      expect(
        await runtime.saveSettings(
          settings,
          apiKey: _testKey,
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.saved,
      );
      expect(
        await runtime.saveSettings(
          settings,
          apiKey: 'synthetic-replacement-key',
        ),
        AiSettingsSaveStatus.storageUnavailable,
      );
      final reopened = store.runtime(vault: vault);
      addTearDown(reopened.dispose);
      expect(await reopened.load(), isTrue);
      expect(reopened.settings.automaticEstimates, isFalse);
      expect(await reopened.hasApiKey(), isTrue);
      expect(keys.values, ['synthetic-replacement-key']);
    },
  );

  test(
    'timing history matches the disclosed payload only when configured',
    () async {
      final source = _capture();
      final history = TaskDurationEvidence(
        cohort: TaskEvidenceCohort.titleAndCategory,
        strength: TaskEvidenceStrength.indicative,
        median: const Duration(minutes: 35),
        lower: const Duration(minutes: 25),
        upper: const Duration(minutes: 45),
        minimum: const Duration(minutes: 25),
        maximum: const Duration(minutes: 45),
        sampleCount: 2,
        matchingSamples: 2,
        last90DaysCount: 2,
        outlierCount: null,
        earliestCompletion: _clock().subtract(const Duration(days: 2)),
        latestCompletion: _clock().subtract(const Duration(days: 1)),
        asOf: _clock(),
        compatibleMinutes: const [25, 45],
      );
      Map<String, Object?>? disclosed;
      var useHistory = false;
      final runtime = _Store().runtime(
        send: (request) async {
          final payload = _userPayload(request);
          expect(payload, disclosed);
          expect(payload.containsKey('durationHistory'), useHistory);
          expect(payload.containsKey('sampleDurationsMinutes'), useHistory);
          if (useHistory) {
            final fields = payload['durationHistory'] as Map;
            expect(fields['cohort'], 'titleAndCategory');
            expect(fields['sampleCount'], 2);
            expect(fields['medianSeconds'], 2100);
            expect(fields['newestAgeDays'], 1);
            expect(fields.containsKey('latestCompletion'), isFalse);
            expect(fields.containsKey('taskId'), isFalse);
          }
          return _estimateAnswer(payload);
        },
      );
      addTearDown(runtime.dispose);
      for (final share in [false, true]) {
        useHistory = share;
        await runtime.saveSettings(
          AiRuntimeSettings(
            route: AiRoute.local,
            localModel: 'test-local',
            allowEstimates: true,
            includeOptionalMetadata: share,
          ),
        );
        final result = await runtime.runEstimate(
          source: source,
          input: AiEstimateInput(
            title: source.text,
            sampleDurationsMinutes: history.compatibleMinutes,
            durationHistory: history,
          ),
          currentRevision: (id) => id == source.id
              ? (
                  sourceRevision: source.revision,
                  contextRevision: source.context.revision,
                )
              : null,
          authorize: (preview) async {
            disclosed = preview.fields;
            return true;
          },
        );
        expect(result.status, AiRunStatus.ready);
        expect(result.value?.duration, const Duration(minutes: 35));
      }
    },
  );

  test('pound amounts retain exact microunits and reject invalid input', () {
    expect(parsePoundsMicros('£1,234.000009'), 1234000009);
    expect(parsePoundsMicros('.50'), 500000);
    expect(parsePoundsMicros('£9,007,199,254.740991'), aiMaxExactInteger);
    expect(formatPoundsMicros(500000), '£0.50');
    expect(formatPoundsMicros(12), '£0.000012');
    for (final invalid in ['-1', '£', '1,23.45', '1e2', '1.0000001', 'NaN']) {
      expect(parsePoundsMicros(invalid), isNull, reason: invalid);
    }
  });

  test(
    'settings persist without secrets and endpoint changes require a new key',
    () async {
      final store = _Store();
      final secrets = <String, String>{};
      final vault = AiCallbackCredentialVault(
        readSecret: (ref) async => secrets[ref],
        writeSecret: (ref, value) async => secrets[ref] = value,
        deleteSecret: (ref) async => secrets.remove(ref),
      );
      final first = store.runtime(vault: vault);
      addTearDown(first.dispose);
      expect(
        await first.saveSettings(_paid(), apiKey: _testKey),
        AiSettingsSaveStatus.saved,
      );
      expect(await first.hasApiKey(), true);
      expect(first.persistentVault, true);
      expect(store.state!.value, isNot(contains(_testKey)));
      expect(secrets.values.single, _testKey);

      final reopened = store.runtime(vault: vault);
      addTearDown(reopened.dispose);
      expect(await reopened.load(), true);
      expect(await reopened.hasApiKey(), true);
      expect(reopened.budget.monthlyCapMicros, 1000000);
      expect(
        await reopened.saveSettings(
          _paid(endpoint: 'https://other.example.test/v2'),
        ),
        AiSettingsSaveStatus.saved,
      );
      expect(await reopened.hasApiKey(), false);
      expect(secrets.values.single, _testKey);
      final noVault = store.runtime();
      addTearDown(noVault.dispose);
      await noVault.load();
      expect(noVault.persistentVault, false);
      expect(await noVault.hasApiKey(), false);
    },
  );

  test(
    'paid disclosure matches the transmitted data and billing is durable',
    () async {
      final store = _Store();
      final source = _capture();
      AiTransmissionPreview? approved;
      final runtime = store.runtime(
        send: (request) async {
          expect(approved, isNotNull);
          expect(request.headers['authorization'], 'Bearer $_testKey');
          final body = jsonDecode(
            (request as http.Request).body,
          ) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          final user = messages[1] as Map<String, dynamic>;
          expect(jsonDecode(user['content'] as String), approved!.fields);
          final pending = AiBudgetLedger.decode(
            jsonEncode((jsonDecode(store.state!.value) as Map)['budget']),
            clock: _clock,
          );
          expect(pending.report().reservedMicros, approved!.reserveMicros);
          return _answer(source, usage: true);
        },
      );
      addTearDown(runtime.dispose);
      expect(
        await runtime.saveSettings(_paid(), apiKey: _testKey),
        AiSettingsSaveStatus.saved,
      );
      final outcome = await runtime.runCapture(
        input: source,
        currentRevision: _revision,
        authorize: (preview) async {
          approved = preview;
          expect(
            preview.endpoint.toString(),
            'https://fixture.example.test/v1/chat/completions',
          );
          expect(preview.fields['version'], 2);
          expect(
            (preview.fields['clauses'] as List).single['text'],
            source.text,
          );
          expect(preview.fields, isNot(contains('text')));
          expect(preview.fields, isNot(contains('timezone')));
          expect(preview.fields, isNot(contains('completionTargets')));
          expect(preview.reserveMicros, isPositive);
          return true;
        },
      );
      expect(outcome.status, AiRunStatus.ready);
      expect(outcome.source, AiRoute.api);
      expect(outcome.value!.proposals.single.draft.title, 'Send the brief');
      expect(runtime.budget.chargedMicros, 4);
      expect(runtime.budget.reservedMicros, 0);
      expect(store.state!.value, isNot(contains(_testKey)));
    },
  );

  test('decline, small allowance, or missing key skip paid dispatch', () async {
    final store = _Store();
    final normal = store.runtime();
    addTearDown(normal.dispose);
    await normal.saveSettings(_paid(), apiKey: _testKey);
    final original = store.state!.value;
    final declined = await normal.runCapture(
      input: _capture(),
      currentRevision: _revision,
      authorize: (_) async => false,
    );
    expect(declined.status, AiRunStatus.declined);
    expect(store.state!.value, original);

    await normal.saveSettings(_paid(cap: 1));
    final blocked = await normal.runCapture(
      input: _capture(),
      currentRevision: _revision,
      authorize: (_) async =>
          fail('Allowance should be checked before authorization.'),
    );
    expect(blocked.status, AiRunStatus.fallback);
    expect(blocked.source, AiRoute.offline);

    await normal.saveSettings(_paid());
    expect(await normal.deleteApiKey(), true);
    final missing = await normal.runCapture(
      input: _capture(),
      currentRevision: _revision,
      authorize: (_) async =>
          fail('The key should be checked before authorization.'),
    );
    expect(missing.status, AiRunStatus.fallback);
    expect(normal.budget.committedMicros, 0);
  });

  test(
    'stale durable settings block network and require an explicit reload',
    () async {
      final store = _Store();
      final first = store.runtime();
      final other = store.runtime();
      addTearDown(first.dispose);
      addTearDown(other.dispose);
      await first.saveSettings(_paid(), apiKey: _testKey);
      await other.saveSettings(_paid(model: 'changed'));
      final result = await first.runCapture(
        input: _capture(),
        currentRevision: _revision,
        authorize: (_) async => fail('A stale configuration must not prompt.'),
      );
      expect(result.status, AiRunStatus.storageUnavailable);
      expect(result.value, isNull);
      expect(first.storageReady, false);
      expect(await first.load(refresh: true), true);
      expect(first.settings.apiModel, 'changed');
    },
  );

  test(
    'a configuration change during disclosure invalidates authorization',
    () async {
      final store = _Store();
      final first = store.runtime();
      final other = store.runtime();
      addTearDown(first.dispose);
      addTearDown(other.dispose);
      await first.saveSettings(_paid(), apiKey: _testKey);
      final result = await first.runCapture(
        input: _capture(),
        currentRevision: _revision,
        authorize: (_) async {
          expect(
            await other.saveSettings(_paid(model: 'changed')),
            AiSettingsSaveStatus.saved,
          );
          return true;
        },
      );
      expect(result.status, AiRunStatus.storageUnavailable);
      expect(result.value, isNull);
    },
  );

  test(
    'local confirmation has an independent setting and runs in foreground',
    () async {
      final store = _Store();
      final input = _capture();
      var requests = 0;
      final runtime = store.runtime(
        send: (request) async {
          requests++;
          expect(request.headers.containsKey('authorization'), false);
          expect(request.url.host, '127.0.0.1');
          expect((request as http.Request).body, contains('Europe/London'));
          return _answer(input);
        },
      );
      addTearDown(runtime.dispose);
      expect(
        await runtime.saveSettings(
          const AiRuntimeSettings(
            route: AiRoute.local,
            localModel: 'test-local',
            confirmLocal: false,
            includeOptionalMetadata: true,
          ),
        ),
        AiSettingsSaveStatus.saved,
      );
      final outcome = await runtime.runCapture(
        input: input,
        currentRevision: _revision,
        authorize: (_) async =>
            fail('Local confirmation was disabled separately.'),
      );
      expect(outcome.source, AiRoute.local);
      expect(outcome.status, AiRunStatus.ready);
      runtime.setForeground(false);
      final background = await runtime.runCapture(
        input: input,
        currentRevision: _revision,
        authorize: (_) async => fail('Background requests cannot begin.'),
      );
      expect(background.status, AiRunStatus.blocked);
      expect(requests, 1);
      expect(runtime.budget.committedMicros, 0);
    },
  );

  test(
    'offline duration estimates use available samples and indicate uncertainty',
    () async {
      final runtime = _Store().runtime();
      addTearDown(runtime.dispose);
      await runtime.saveSettings(const AiRuntimeSettings(allowEstimates: true));
      final review = await runtime.runEstimate(
        source: _capture(),
        input: AiEstimateInput(
          title: 'Draft',
          sampleDurationsMinutes: [80, 20, 30],
        ),
        currentRevision: _revision,
        authorize: (_) async =>
            fail('Offline estimates should not send anything.'),
      );
      expect(review.source, AiRoute.offline);
      expect(review.value!.duration, const Duration(minutes: 30));
      expect(
        review.value!.uncertainty,
        contains('ranging from 20 to 80 minutes'),
      );
      final unknown = await runtime.runEstimate(
        source: _capture(),
        input: AiEstimateInput(title: 'Draft'),
        currentRevision: _revision,
        authorize: (_) async =>
            fail('Offline estimates should not send anything.'),
      );
      expect(unknown.status, AiRunStatus.blocked);
      expect(unknown.value, isNull);
    },
  );

  test(
    'an outstanding persisted reservation is recovered conservatively once',
    () async {
      final settings = _paid();
      final ledger = AiBudgetLedger(
        monthlyCapMicros: settings.monthlyCapMicros,
        currency: 'GBP',
        clock: _clock,
      );
      final approval = ledger.reserve(
        settings.provider!.budgetRequest('lost', work: AiWorkKind.interactive),
      );
      final reserved = approval.reservation!.reservedMicros;
      final store = _Store()
        ..state = AiStoredState(
          revision: 1,
          value: jsonEncode({
            'version': 1,
            'settings': settings.toJson(),
            'budget': jsonDecode(ledger.encode()),
          }),
        );
      final runtime = store.runtime();
      addTearDown(runtime.dispose);
      expect(await runtime.load(), true);
      expect(store.state!.revision, 2);
      expect(runtime.budget.chargedMicros, reserved);
      expect(runtime.budget.reservedMicros, 0);
      expect(runtime.budget.unknownUsageCalls, 1);
      expect(await runtime.load(refresh: true), true);
      expect(store.state!.revision, 2);
      expect(runtime.budget.chargedMicros, reserved);
    },
  );

  test(
    'automatic estimates require scoped consent before durable activation',
    () async {
      final store = _Store();
      final runtime = store.runtime();
      addTearDown(runtime.dispose);
      expect(
        await runtime.saveSettings(_automaticLocal()),
        AiSettingsSaveStatus.authorizationRequired,
      );
      expect(store.state, isNull);
      expect(runtime.settings.automaticEstimates, false);
      expect(
        await runtime.saveSettings(
          _automaticLocal(),
          authorizeAutomatic: (preview) async {
            expect(preview.route, AiRoute.local);
            expect(preview.endpoint.host, '127.0.0.1');
            expect(preview.includeOptionalMetadata, false);
            expect(preview.reserveMicros, isNull);
            return true;
          },
        ),
        AiSettingsSaveStatus.saved,
      );
      expect(runtime.settings.automaticEstimates, true);
      final confirmed = store.state!.value;
      expect(
        await runtime.saveSettings(_automaticLocal(metadata: true)),
        AiSettingsSaveStatus.authorizationRequired,
      );
      expect(store.state!.value, confirmed);
    },
  );

  test('automatic work is metadata-scoped, deduped, and restored as pending review', () async {
    final store = _Store();
    var now = _clock();
    var sends = 0;
    final runtime = store.runtime(
      clock: () => now,
      send: (request) async {
        sends++;
        final payload = _userPayload(request);
        expect(payload.keys.toSet(), {
          'captureId',
          'sourceRevision',
          'contextRevision',
          'title',
          'sampleDurationsMinutes',
        });
        expect(payload['captureId'], isNot(contains('private-workspace-id')));
        expect(payload['sourceRevision'], 0);
        expect(payload['contextRevision'], 0);
        expect(payload['sampleDurationsMinutes'], [20, 40]);
        return _estimateAnswer(payload);
      },
    );
    addTearDown(runtime.dispose);
    await runtime.saveSettings(
      _automaticLocal(metadata: true),
      authorizeAutomatic: (_) async => true,
    );
    final a = _candidate('private-workspace-id');
    final b = _candidate('private-workspace-id-2');
    runtime.setForeground(false);
    expect(runtime.canAutomaticallyEstimate(a), false);
    expect(
      (await runtime.runAutomaticEstimate(
        candidate: a,
        currentRevision: _candidateRevision,
      )).status,
      AiRunStatus.blocked,
    );
    runtime.setForeground(true);
    expect(runtime.canAutomaticallyEstimate(a), true);
    final first = await runtime.runAutomaticEstimate(
      candidate: a,
      currentRevision: _candidateRevision,
    );
    expect(first.status, AiRunStatus.ready);
    expect(first.value!.requiresReview, true);
    expect(first.value!.durationMinutes, 35);
    expect(runtime.canAutomaticallyEstimate(b), false);
    expect(
      (await runtime.runAutomaticEstimate(
        candidate: b,
        currentRevision: _candidateRevision,
      )).status,
      AiRunStatus.blocked,
    );
    now = now.add(const Duration(hours: 1));
    expect(runtime.canAutomaticallyEstimate(a), false);
    expect(runtime.canAutomaticallyEstimate(b), true);
    expect(
      (await runtime.runAutomaticEstimate(
        candidate: a,
        currentRevision: _candidateRevision,
      )).status,
      AiRunStatus.blocked,
    );
    expect(
      (await runtime.runAutomaticEstimate(
        candidate: b,
        currentRevision: _candidateRevision,
      )).status,
      AiRunStatus.ready,
    );
    expect(sends, 2);
    expect(store.state!.value, isNot(contains(a.title)));
    expect(store.state!.value, isNot(contains('sampleDurationsMinutes')));

    final restored = store.runtime(clock: () => now);
    addTearDown(restored.dispose);
    expect(await restored.load(), true);
    expect(restored.pendingEstimates, hasLength(2));
    expect(restored.currentPendingEstimates((_) => null), isEmpty);
    expect(restored.currentPendingEstimates(_candidateRevision), hasLength(2));
    expect(
      await restored.discardPendingEstimate(restored.pendingEstimates.first),
      true,
    );
    expect(restored.pendingEstimates, hasLength(1));
  });

  test(
    'a paid estimate range keeps the same disclosed fields and reservation',
    () async {
      final source = _capture();
      final input = AiEstimateInput(
        title: 'Draft the brief',
        sampleDurationsMinutes: [11, 22],
      );
      var plainRequestBytes = 0;
      for (final (outputTokens, tightlyBoundInput, rangeExpected) in [
        (100, false, false),
        (128, true, false),
        (128, false, true),
      ]) {
        final store = _Store();
        final inputTokens = tightlyBoundInput ? plainRequestBytes : 8192;
        final maximum = inputTokens + 2 * outputTokens;
        var sends = 0;
        late final AiRuntime runtime;
        runtime = store.runtime(
          send: (request) async {
            sends++;
            expect(runtime.budget.reservedMicros, maximum);
            final body = jsonDecode((request as http.Request).body) as Map;
            final system =
                ((body['messages'] as List).first as Map)['content'] as String;
            expect(system.contains('lowerMinutes'), rangeExpected);
            expect(body['max_completion_tokens'], outputTokens);
            if (outputTokens == 100) {
              plainRequestBytes = request.bodyBytes.length;
            }
            final payload = _userPayload(request);
            expect(payload.keys.toSet(), {
              'captureId',
              'sourceRevision',
              'contextRevision',
              'title',
            });
            return _estimateAnswer(
              payload,
              range: rangeExpected ? _exampleRange : null,
            );
          },
        );
        addTearDown(runtime.dispose);
        expect(
          await runtime.saveSettings(
            _paid(
              allowEstimates: true,
              maxInputTokens: inputTokens,
              maxOutputTokens: outputTokens,
            ),
            apiKey: _testKey,
          ),
          AiSettingsSaveStatus.saved,
        );

        final result = await runtime.runEstimate(
          source: source,
          input: input,
          currentRevision: _revision,
          authorize: (preview) async {
            expect(preview.reserveMicros, maximum);
            expect(preview.fields.keys.toSet(), {
              'captureId',
              'sourceRevision',
              'contextRevision',
              'title',
            });
            return true;
          },
        );

        expect(result.status, AiRunStatus.ready);
        expect(result.value!.duration.inMinutes, 35);
        expect(
          result.value!.uncertainty,
          rangeExpected
              ? 'Model range 20–55 min\nModel received the task title only.'
              : 'Model received the task title only.',
        );
        expect(sends, 1);
        expect(runtime.budget.reservedMicros, 0);
        expect(runtime.budget.chargedMicros, maximum);
        expect(runtime.pendingEstimates, isEmpty);
      }
    },
  );

  test(
    'paid background ranges require adaptive consent and sustainable headroom',
    () async {
      for (final (cap, adaptive, rangeExpected) in [
        (1000000, false, false),
        (100000, true, false),
        (1000000, true, true),
      ]) {
        final store = _Store();
        var sends = 0;
        final runtime = store.runtime(
          send: (request) async {
            sends++;
            final body = jsonDecode((request as http.Request).body) as Map;
            final system =
                ((body['messages'] as List).first as Map)['content'] as String;
            expect(system.contains('lowerMinutes'), rangeExpected);
            return _estimateAnswer(
              _userPayload(request),
              range: rangeExpected ? _exampleRange : null,
            );
          },
        );
        addTearDown(runtime.dispose);
        await runtime.saveSettings(
          _paid(cap: cap, automatic: true, adaptive: adaptive),
          apiKey: _testKey,
          authorizeAutomatic: (_) async => true,
        );
        final candidate = _candidate('private-workspace-id-range');
        final result = await runtime.runAutomaticEstimate(
          candidate: candidate,
          currentRevision: _candidateRevision,
        );
        expect(result.status, AiRunStatus.ready, reason: '$cap $adaptive');
        expect(sends, 1);
        expect(runtime.pendingEstimates.single.details!.disclosedDurations, 0);
        expect(
          runtime.pendingEstimates.single.details!.range?.toJson(),
          rangeExpected ? _exampleRange : null,
        );
        expect(runtime.budget.chargedMicros, 9216);
        expect(runtime.budget.reservedMicros, 0);
      }
    },
  );

  test(
    'local range review survives reopen and older records keep their point',
    () async {
      final store = _Store();
      final runtime = store.runtime(
        send: (request) async {
          final payload = _userPayload(request);
          expect(payload['sampleDurationsMinutes'], [20, 40]);
          return _estimateAnswer(payload, range: _exampleRange);
        },
      );
      addTearDown(runtime.dispose);
      await runtime.saveSettings(
        _automaticLocal(metadata: true, adaptive: true),
        authorizeAutomatic: (_) async => true,
      );
      final result = await runtime.runAutomaticEstimate(
        candidate: _candidate('private-workspace-id-range'),
        currentRevision: _candidateRevision,
      );
      expect(result.status, AiRunStatus.ready);
      expect(runtime.budget.chargedMicros, 0);
      expect(store.state!.value, isNot(contains('Draft reviewed estimate')));
      expect(store.state!.value, isNot(contains('sampleDurationsMinutes')));
      final restored = store.runtime();
      addTearDown(restored.dispose);
      expect(await restored.load(), true);
      final pending = restored
          .currentPendingEstimates(_candidateRevision)
          .single;
      expect(
        pending.details!.reviewDescription,
        'Model range 20–55 min\nModel received the task title and 2 recorded durations.',
      );
      expect(restored.currentPendingEstimates((_) => null), isEmpty);

      final beforeRanges = pending.toJson()..remove('details');
      final legacy = AiPendingEstimate.fromJson(beforeRanges);
      expect(legacy.durationMinutes, 35);
      expect(legacy.details, isNull);
      expect(legacy.isCurrent(_candidateRevision), true);
      final damagedRange = AiPendingEstimate.fromJson({
        ...beforeRanges,
        'details': {
          'disclosedDurations': 2,
          'range': {'lowerMinutes': 36, 'upperMinutes': 40},
        },
      });
      expect(damagedRange.durationMinutes, 35);
      expect(damagedRange.details!.range, isNull);
    },
  );

  test(
    'context changing in flight keeps the returned range out of review',
    () async {
      final store = _Store();
      final started = Completer<Map<String, dynamic>>();
      final reply = Completer<http.StreamedResponse>();
      final runtime = store.runtime(
        send: (request) {
          started.complete(_userPayload(request));
          return reply.future;
        },
      );
      addTearDown(runtime.dispose);
      await runtime.saveSettings(
        _automaticLocal(adaptive: true),
        authorizeAutomatic: (_) async => true,
      );
      final candidate = _candidate('private-workspace-id-range');
      var revision = candidate.revision;
      final running = runtime.runAutomaticEstimate(
        candidate: candidate,
        currentRevision: (_) => revision,
      );
      final payload = await started.future;
      revision = (
        sourceRevision: candidate.sourceRevision,
        contextRevision: candidate.contextRevision + 1,
      );
      reply.complete(_estimateAnswer(payload, range: _exampleRange));

      final result = await running;
      expect(result.status, AiRunStatus.stale);
      expect(runtime.pendingEstimates, isEmpty);
      expect(store.state!.value, isNot(contains('lowerMinutes')));
    },
  );

  testWidgets('range and review controls fit a narrow phone with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 460);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final runtime = _Store().runtime();
    addTearDown(runtime.dispose);
    final item = TaskEstimateReviewItem(
      estimate: AiPendingEstimate.fromJson({
        'taskId': 'task',
        'sourceRevision': 2,
        'contextRevision': 4,
        'durationMinutes': 35,
        'route': 'api',
        'createdAt': _clock().toIso8601String(),
        'details': {'disclosedDurations': 2, 'range': _exampleRange},
      }),
      title: 'Draft a project brief for the next planning session',
    );
    AiPendingEstimate? accepted;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: TaskEstimatesPage(
          runtime: runtime,
          readItems: () => [item],
          onAccept: (estimate) async => accepted = estimate,
        ),
      ),
    );
    expect(find.textContaining('Model range 20–55 min'), findsOneWidget);
    expect(accepted, isNull);
    final useEstimate = find.text('Use estimate');
    await tester.scrollUntilVisible(useEstimate, 90);
    await tester.ensureVisible(useEstimate);
    await tester.pumpAndSettle();
    await tester.tap(useEstimate);
    await tester.pumpAndSettle();
    expect(accepted, same(item.estimate));
    expect(tester.takeException(), isNull);
  });

  test('a paid forecast at the cap stops automatic work', () async {
    final store = _Store();
    final source = _capture();
    var calls = 0;
    final runtime = store.runtime(
      clock: () => DateTime.utc(2026, 11),
      send: (_) async {
        calls++;
        return _answer(source, usage: true, inputTokens: 40000);
      },
    );
    addTearDown(runtime.dispose);
    expect(
      await runtime.saveSettings(
        _paid(automatic: true),
        apiKey: _testKey,
        authorizeAutomatic: (_) async => true,
      ),
      AiSettingsSaveStatus.saved,
    );
    final manual = await runtime.runCapture(
      input: source,
      currentRevision: _revision,
      authorize: (_) async => true,
    );
    expect(manual.status, AiRunStatus.ready);
    expect(
      runtime.budget.projectedMicros,
      greaterThan(runtime.budget.monthlyCapMicros),
    );
    final automatic = await runtime.runAutomaticEstimate(
      candidate: _candidate('private-workspace-id'),
      currentRevision: _candidateRevision,
    );
    expect(automatic.status, AiRunStatus.blocked);
    expect(runtime.pendingEstimates, isEmpty);
    expect(calls, 1);
  });

  test(
    'backgrounding cancels an automatic request without publishing output',
    () async {
      final store = _Store();
      final reached = Completer<http.AbortableRequest>();
      final reply = Completer<http.StreamedResponse>();
      final runtime = store.runtime(
        send: (request) {
          reached.complete(request as http.AbortableRequest);
          return reply.future;
        },
      );
      addTearDown(runtime.dispose);
      await runtime.saveSettings(
        _automaticLocal(),
        authorizeAutomatic: (_) async => true,
      );
      final running = runtime.runAutomaticEstimate(
        candidate: _candidate('private-workspace-id'),
        currentRevision: _candidateRevision,
      );
      final req = await reached.future;
      runtime.setForeground(false);
      await req.abortTrigger!;
      expect((await running).status, AiRunStatus.declined);
      reply.complete(_estimateAnswer(_userPayload(req)));
      expect(runtime.pendingEstimates, isEmpty);
    },
  );

  testWidgets('settings fit a 320px phone and save the local preference', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 610);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final runtime = _Store().runtime();
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AiSettingsPage(runtime: runtime)),
    );
    await tester.pumpAndSettle();
    expect(find.text('AI settings'), findsOneWidget);
    expect(find.text('Monthly API limit'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Local'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Model',
      ),
      'test-local',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final outerScroll = find.byType(Scrollable).first;
    final confirmation = find.widgetWithText(
      SwitchListTile,
      'Confirm local requests',
    );
    await tester.scrollUntilVisible(confirmation, 140, scrollable: outerScroll);
    await tester.ensureVisible(confirmation);
    await tester.pumpAndSettle();
    await tester.tap(confirmation);
    final save = find.text('Save settings');
    await tester.scrollUntilVisible(save, 130, scrollable: outerScroll);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(runtime.settings.route, AiRoute.local);
    expect(runtime.settings.confirmLocal, false);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final estimates = find.widgetWithText(SwitchListTile, 'Suggest durations');
    await tester.scrollUntilVisible(estimates, 120, scrollable: outerScroll);
    await tester.tap(estimates);
    await tester.pumpAndSettle();
    final automatic = find.widgetWithText(SwitchListTile, 'Use spare capacity');
    await tester.scrollUntilVisible(automatic, 120, scrollable: outerScroll);
    await tester.tap(automatic);
    await tester.pumpAndSettle();
    final adaptive = find.widgetWithText(
      SwitchListTile,
      'Group estimates while active',
    );
    await tester.scrollUntilVisible(adaptive, 120, scrollable: outerScroll);
    await tester.ensureVisible(adaptive);
    await tester.pumpAndSettle();
    await tester.tap(adaptive);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(save, 120, scrollable: outerScroll);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Enable automatic estimates?'), findsOneWidget);
    expect(find.text('Task title and temporary request ID'), findsOneWidget);
    expect(
      find.text(
        'At least 20 minutes between estimates, up to six a day while Easy is active.',
      ),
      findsOneWidget,
    );
    expect(runtime.settings.automaticEstimates, false);
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    expect(runtime.settings.automaticEstimates, true);
    expect(runtime.settings.adaptiveEstimatePacing, true);
    expect(tester.takeException(), isNull);
  });
}

const _testKey = 'synthetic-key-for-tests';
const _exampleRange = {'lowerMinutes': 20, 'upperMinutes': 55};

DateTime _clock() => DateTime.utc(2026, 11, 24);

AiCaptureRevision? _revision(String id) =>
    id == 'capture' ? (sourceRevision: 2, contextRevision: 4) : null;

CaptureInput _capture() => CaptureInput(
  id: 'capture',
  revision: 2,
  text: 'Task: Send the brief',
  context: CaptureContext(
    anchor: _clock(),
    revision: 4,
    timezone: 'Europe/London',
  ),
);

AiRuntimeSettings _paid({
  String endpoint = 'https://fixture.example.test/v1',
  String model = 'text-fixture',
  int cap = 1000000,
  bool automatic = false,
  bool adaptive = false,
  bool allowEstimates = false,
  int maxInputTokens = 8192,
  int maxOutputTokens = 512,
}) => AiRuntimeSettings(
  route: AiRoute.api,
  apiBaseUrl: endpoint,
  apiModel: model,
  monthlyCapMicros: cap,
  inputMicrosPerMillion: 1000000,
  outputMicrosPerMillion: 2000000,
  maxInputTokens: maxInputTokens,
  maxOutputTokens: maxOutputTokens,
  allowEstimates: automatic || allowEstimates,
  automaticEstimates: automatic,
  adaptiveEstimatePacing: adaptive,
);

AiRuntimeSettings _automaticLocal({
  bool metadata = false,
  bool adaptive = false,
}) => AiRuntimeSettings(
  route: AiRoute.local,
  localModel: 'test-local',
  allowEstimates: true,
  automaticEstimates: true,
  adaptiveEstimatePacing: adaptive,
  includeOptionalMetadata: metadata,
);

AiEnrichmentCandidate _candidate(String id) => AiEnrichmentCandidate(
  taskId: id,
  title: 'Draft reviewed estimate',
  sourceRevision: 8,
  contextRevision: 9,
  sampleDurationsMinutes: [20, 40],
);

AiCaptureRevision? _candidateRevision(String id) =>
    id.startsWith('private-workspace-id')
    ? (sourceRevision: 8, contextRevision: 9)
    : null;

class _Store {
  AiStoredState? state;
  bool rejectWrites = false;

  AiRuntime runtime({
    AiWritableCredentialVault? vault,
    Future<http.StreamedResponse> Function(http.BaseRequest)? send,
    DateTime Function()? clock,
  }) => AiRuntime(
    read: () async => state,
    compareAndSwap: (expected, value) async {
      if (rejectWrites || expected != (state?.revision ?? 0)) return null;
      state = AiStoredState(revision: expected + 1, value: value);
      return state!.revision;
    },
    vault: vault,
    transport: _FakeClient(send),
    clock: clock ?? _clock,
  );
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest)? handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (handler case final send?) return send(request);
    return Future.error(StateError('Unexpected fixture request.'));
  }
}

http.StreamedResponse _answer(
  CaptureInput source, {
  bool usage = false,
  int inputTokens = 2,
}) {
  final content = jsonEncode({
    'version': 1,
    'captureId': source.id,
    'sourceRevision': source.revision,
    'contextRevision': source.context.revision,
    'proposals': [
      {
        'kind': 'task',
        'span': {'start': 0, 'end': source.text.length},
        'fields': {'title': 'Send the brief'},
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
          if (usage)
            'usage': {'prompt_tokens': inputTokens, 'completion_tokens': 1},
        }),
      ),
    ),
    200,
  );
}

Map<String, dynamic> _userPayload(http.BaseRequest request) {
  final json =
      jsonDecode((request as http.Request).body) as Map<String, dynamic>;
  final userMessage = (json['messages'] as List)[1] as Map<String, dynamic>;
  return jsonDecode(userMessage['content'] as String) as Map<String, dynamic>;
}

http.StreamedResponse _estimateAnswer(
  Map<String, dynamic> payload, {
  Map<String, int>? range,
}) => http.StreamedResponse(
  Stream.value(
    utf8.encode(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'captureId': payload['captureId'],
                'sourceRevision': payload['sourceRevision'],
                'contextRevision': payload['contextRevision'],
                'minutes': 35,
                'range': ?range,
              }),
            },
          },
        ],
      }),
    ),
  ),
  200,
);
