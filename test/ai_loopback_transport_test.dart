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
}
