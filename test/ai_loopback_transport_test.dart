import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a real loopback request stops while backgrounded and can be reviewed after return', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = StreamIterator(server);
    addTearDown(requests.cancel);
    AiStoredState? persisted;
    final runtime = AiRuntime(
      read: () async => persisted,
      compareAndSwap: (expected, value) async {
        final revision = persisted?.revision ?? 0;
        if (expected != revision) return null;
        persisted = AiStoredState(revision: revision + 1, value: value);
        return revision + 1;
      },
    );
    addTearDown(runtime.dispose);
    final clock = DateTime.utc(2026, 11, 24, 12);
    final source = CaptureInput(
      id: 'loopback-fixture',
      revision: 1,
      text: 'Task: Send the project brief',
      context: CaptureContext(anchor: clock, revision: 2),
    );
    AiCaptureRevision? current(String id) =>
        id == source.id ? (sourceRevision: 1, contextRevision: 2) : null;

    expect(
      await runtime.saveSettings(
        AiRuntimeSettings(
          route: AiRoute.local,
          localBaseUrl: 'http://127.0.0.1:${server.port}/v1',
          localModel: 'fixture-model',
          localCaptureJsonSchema: true,
        ),
      ),
      AiSettingsSaveStatus.saved,
    );
    var authorizations = 0;
    Future<AiRuntimeOutcome<CaptureReview>> capture() => runtime.runCapture(
      input: source,
      currentRevision: current,
      authorize: (preview) async {
        authorizations++;
        expect(preview.endpoint.host, '127.0.0.1');
        return true;
      },
    );

    final first = capture();
    expect(await requests.moveNext().timeout(const Duration(seconds: 5)), true);
    final firstRequest = requests.current;
    expect(firstRequest.uri.path, '/v1/chat/completions');
    expect(firstRequest.headers.value(HttpHeaders.authorizationHeader), isNull);
    final firstBody = await utf8.decoder.bind(firstRequest).join();
    runtime.setForeground(false);
    expect(
      (await first.timeout(const Duration(seconds: 5))).status,
      AiRunStatus.declined,
    );
    expect((await capture()).status, AiRunStatus.blocked);
    expect(authorizations, 1);

    runtime.setForeground(true);
    final second = capture();
    expect(await requests.moveNext().timeout(const Duration(seconds: 5)), true);
    final secondRequest = requests.current;
    final body = await utf8.decoder.bind(secondRequest).join();
    expect(body, firstBody);
    final envelope = jsonDecode(body) as Map;
    expect((envelope['response_format'] as Map)['type'], 'json_schema');
    secondRequest.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'version': 2,
                  'captureId': source.id,
                  'sourceRevision': source.revision,
                  'contextRevision': source.context.revision,
                  'suggestions': [
                    {'clause': 0, 'kind': 'category', 'category': 'work'},
                  ],
                }),
              },
            },
          ],
        }),
      );
    await secondRequest.response.close();
    final ready = await second.timeout(const Duration(seconds: 5));
    expect(authorizations, 2);
    expect(ready.status, AiRunStatus.ready);
    expect(ready.value!.proposals.single.requiresSelection, true);
    expect(ready.value!.proposals.single.draft.category, 'work');
    expect(runtime.budget.committedMicros, 0);
  });

  test(
    'a transient automatic Local failure allows one paced retry after reopen',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var ready = false;
      var requests = 0;
      server.listen((request) async {
        requests++;
        final envelope =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final user = (envelope['messages'] as List)[1] as Map;
        final fields = jsonDecode(user['content'] as String) as Map;
        request.response.headers.contentType = ContentType.json;
        if (ready) {
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'captureId': fields['captureId'],
                      'sourceRevision': fields['sourceRevision'],
                      'contextRevision': fields['contextRevision'],
                      'minutes': 18,
                    }),
                  },
                },
              ],
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write(
            jsonEncode({'error': 'The fixture is still loading.'}),
          );
        }
        await request.response.close();
      });

      var now = DateTime.utc(2026, 11, 24, 10);
      AiStoredState? persisted;
      AiRuntime open() {
        final runtime = AiRuntime(
          read: () async => persisted,
          compareAndSwap: (expected, value) async {
            final revision = persisted?.revision ?? 0;
            if (expected != revision) return null;
            persisted = AiStoredState(revision: revision + 1, value: value);
            return revision + 1;
          },
          clock: () => now,
        );
        addTearDown(runtime.dispose);
        return runtime;
      }

      AiRuntimeSettings settings({bool automatic = true}) => AiRuntimeSettings(
        route: AiRoute.local,
        localBaseUrl: 'http://127.0.0.1:${server.port}/v1',
        localModel: 'fixture-model',
        allowEstimates: true,
        automaticEstimates: automatic,
        adaptiveEstimatePacing: automatic,
      );

      AiEnrichmentCandidate task(String id) => AiEnrichmentCandidate(
        taskId: id,
        title: 'Draft the next planning note',
        sourceRevision: 1,
        contextRevision: 2,
      );
      Future<AiRuntimeOutcome<AiPendingEstimate>> run(
        AiRuntime runtime,
        AiEnrichmentCandidate input,
      ) => runtime.runAutomaticEstimate(
        candidate: input,
        currentRevision: (id) => id == input.taskId ? input.revision : null,
      );

      final first = open();
      expect(
        await first.saveSettings(
          settings(),
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.saved,
      );
      final original = task('transient');
      expect((await run(first, original)).status, AiRunStatus.blocked);
      expect(requests, 1);
      expect(first.pendingEstimates, isEmpty);

      ready = true;
      now = now.add(const Duration(minutes: 29, seconds: 59));
      final reopened = open();
      expect(await reopened.load(), isTrue);
      expect(reopened.canAutomaticallyEstimate(original), isFalse);
      expect((await run(reopened, original)).status, AiRunStatus.blocked);

      now = now.add(const Duration(seconds: 1));
      reopened.setForeground(false);
      expect((await run(reopened, original)).status, AiRunStatus.blocked);
      reopened.setForeground(true);
      expect(
        await reopened.saveSettings(settings(automatic: false)),
        AiSettingsSaveStatus.saved,
      );
      expect((await run(reopened, original)).status, AiRunStatus.blocked);
      expect(requests, 1);
      expect(
        await reopened.saveSettings(
          settings(),
          authorizeAutomatic: (_) async => true,
        ),
        AiSettingsSaveStatus.saved,
      );

      final peer = open();
      expect(await peer.load(), isTrue);
      expect(reopened.canAutomaticallyEstimate(original), isTrue);
      expect(peer.canAutomaticallyEstimate(original), isTrue);
      final outcomes = await Future.wait([
        run(reopened, original),
        run(peer, original),
      ]);
      expect(
        outcomes
            .where((outcome) => outcome.status == AiRunStatus.ready)
            .single
            .value!
            .durationMinutes,
        18,
      );
      expect(requests, 2);

      final finalRuntime = open();
      expect(await finalRuntime.load(), isTrue);
      expect(finalRuntime.pendingEstimates.single.taskId, original.taskId);
      final enrichment =
          (jsonDecode(persisted!.value) as Map)['enrichment'] as Map;
      expect(enrichment['attemptsOnLastDay'], 2);
      now = now.add(const Duration(days: 2));
      expect(finalRuntime.canAutomaticallyEstimate(original), isFalse);

      ready = false;
      final unavailable = task('still-unavailable');
      expect(
        (await run(finalRuntime, unavailable)).status,
        AiRunStatus.blocked,
      );
      now = now.add(const Duration(minutes: 30));
      expect(
        (await run(finalRuntime, unavailable)).status,
        AiRunStatus.blocked,
      );
      expect(requests, 4);
      now = now.add(const Duration(days: 2));
      expect(finalRuntime.canAutomaticallyEstimate(unavailable), isFalse);
      expect(
        (await run(finalRuntime, unavailable)).status,
        AiRunStatus.blocked,
      );
      expect(requests, 4);
    },
  );
}
