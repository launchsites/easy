import 'dart:convert';
import 'dart:io';

import 'package:easy/ai/ai_runtime.dart';
import 'package:easy/capture/capture_interpreter.dart';
import 'package:easy/task_context/task_context.dart';
import 'package:flutter_test/flutter_test.dart';

const _range = {'lowerMinutes': 20, 'upperMinutes': 55};

void main() {
  test(
    'real Local ranges respect opt-in, request limits, and history consent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests =
          <
            ({
              Map<String, dynamic> fields,
              bool requestedRange,
              bool authenticated,
            })
          >[];
      server.listen((request) async {
        final envelope =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = envelope['messages'] as List;
        final system = (messages.first as Map)['content'] as String;
        final user = (messages.last as Map)['content'] as String;
        final fields = jsonDecode(user) as Map<String, dynamic>;
        final requestedRange = system.contains('lowerMinutes');
        requests.add((
          fields: fields,
          requestedRange: requestedRange,
          authenticated:
              request.headers.value(HttpHeaders.authorizationHeader) != null,
        ));
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'captureId': fields['captureId'],
                      'sourceRevision': fields['sourceRevision'],
                      'contextRevision': fields['contextRevision'],
                      'minutes': 35,
                      if (requestedRange) 'range': _range,
                    }),
                  },
                },
              ],
            }),
          );
        await request.response.close();
      });

      final anchor = DateTime.utc(2026, 11, 24, 12);
      final source = CaptureInput(
        id: 'range-loopback',
        revision: 1,
        text: 'Draft a planning brief',
        context: CaptureContext(anchor: anchor, revision: 2),
      );
      final history = TaskDurationEvidence(
        cohort: TaskEvidenceCohort.titleAndCategory,
        strength: TaskEvidenceStrength.indicative,
        median: const Duration(minutes: 30),
        lower: const Duration(minutes: 25),
        upper: const Duration(minutes: 35),
        minimum: const Duration(minutes: 20),
        maximum: const Duration(minutes: 40),
        sampleCount: 2,
        matchingSamples: 2,
        last90DaysCount: 2,
        outlierCount: null,
        earliestCompletion: anchor.subtract(const Duration(days: 2)),
        latestCompletion: anchor.subtract(const Duration(days: 1)),
        asOf: anchor,
        compatibleMinutes: const [20, 40],
      );
      final candidate = AiEnrichmentCandidate(
        taskId: 'private-task-id',
        title: source.text,
        sourceRevision: 1,
        contextRevision: 2,
        sampleDurationsMinutes: history.compatibleMinutes,
        durationHistory: history,
      );

      for (final (ranges, shareHistory, outputTokens, expectRange) in [
        (false, false, 512, false),
        (true, false, 512, true),
        (true, true, 512, true),
        (true, false, 127, false),
      ]) {
        final firstRequest = requests.length;
        AiStoredState? persisted;
        final runtime = AiRuntime(
          read: () async => persisted,
          compareAndSwap: (expected, value) async {
            final revision = persisted?.revision ?? 0;
            if (expected != revision) return null;
            persisted = AiStoredState(revision: revision + 1, value: value);
            return revision + 1;
          },
          clock: () => anchor,
        );
        addTearDown(runtime.dispose);
        expect(
          await runtime.saveSettings(
            AiRuntimeSettings(
              route: AiRoute.local,
              localBaseUrl: 'http://127.0.0.1:${server.port}/v1',
              localModel: 'fixture-capable-model',
              localEstimateRanges: ranges,
              maxOutputTokens: outputTokens,
              allowEstimates: true,
              automaticEstimates: true,
              includeOptionalMetadata: shareHistory,
            ),
            authorizeAutomatic: (_) async => true,
          ),
          AiSettingsSaveStatus.saved,
        );

        Map<String, Object?>? disclosed;
        final manual = await runtime
            .runEstimate(
              source: source,
              input: AiEstimateInput(
                title: source.text,
                sampleDurationsMinutes: history.compatibleMinutes,
                durationHistory: history,
              ),
              currentRevision: (id) => id == source.id
                  ? (sourceRevision: 1, contextRevision: 2)
                  : null,
              authorize: (preview) async {
                disclosed = preview.fields;
                return true;
              },
            )
            .timeout(const Duration(seconds: 5));
        expect(manual.status, AiRunStatus.ready);
        expect(manual.value!.duration.inMinutes, 35);
        expect(
          manual.value!.uncertainty.contains('Model range 20–55 min'),
          expectRange,
        );

        Future<AiRuntimeOutcome<AiPendingEstimate>> runAutomatic() =>
            runtime.runAutomaticEstimate(
              candidate: candidate,
              currentRevision: (id) =>
                  id == candidate.taskId ? candidate.revision : null,
            );
        runtime.setForeground(false);
        expect((await runAutomatic()).status, AiRunStatus.blocked);
        runtime.setForeground(true);
        final automatic = await runAutomatic().timeout(
          const Duration(seconds: 5),
        );
        expect(automatic.status, AiRunStatus.ready);
        expect(
          runtime.pendingEstimates.single.details!.range?.toJson(),
          expectRange ? _range : null,
        );
        expect(runtime.budget.chargedMicros, 0);

        expect(requests.length, firstRequest + 2);
        expect(requests[firstRequest].fields, disclosed);
        for (final request in requests.skip(firstRequest)) {
          expect(request.requestedRange, expectRange);
          expect(request.authenticated, isFalse);
          expect(request.fields.keys.toSet(), {
            'captureId',
            'sourceRevision',
            'contextRevision',
            'title',
            if (shareHistory) ...{'sampleDurationsMinutes', 'durationHistory'},
          });
        }
      }
    },
  );
}
