import 'dart:convert';

import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/ai/ai_settings_page.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

void main() {
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
          expect(preview.fields['text'], source.text);
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
    final outerScroll = find.byType(Scrollable).first;
    final confirmation = find.widgetWithText(
      SwitchListTile,
      'Confirm local requests',
    );
    await tester.scrollUntilVisible(confirmation, 140, scrollable: outerScroll);
    await tester.tap(confirmation);
    final save = find.text('Save settings');
    await tester.scrollUntilVisible(save, 130, scrollable: outerScroll);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(runtime.settings.route, AiRoute.local);
    expect(runtime.settings.confirmLocal, false);
    expect(tester.takeException(), isNull);
  });
}

const _testKey = 'synthetic-key-for-tests';

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
}) => AiRuntimeSettings(
  route: AiRoute.api,
  apiBaseUrl: endpoint,
  apiModel: model,
  monthlyCapMicros: cap,
  inputMicrosPerMillion: 1000000,
  outputMicrosPerMillion: 2000000,
);

class _Store {
  AiStoredState? state;

  AiRuntime runtime({
    AiWritableCredentialVault? vault,
    Future<http.StreamedResponse> Function(http.BaseRequest)? send,
  }) => AiRuntime(
    read: () async => state,
    compareAndSwap: (expected, value) async {
      if (expected != (state?.revision ?? 0)) return null;
      state = AiStoredState(revision: expected + 1, value: value);
      return state!.revision;
    },
    vault: vault,
    transport: _FakeClient(send),
    clock: _clock,
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

http.StreamedResponse _answer(CaptureInput source, {bool usage = false}) {
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
          if (usage) 'usage': {'prompt_tokens': 2, 'completion_tokens': 1},
        }),
      ),
    ),
    200,
  );
}
