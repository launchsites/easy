import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/inference_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'backgrounded local work stops, releases, and resumes with a new fence',
    () async {
      var now = DateTime.utc(2026, 11, 24, 13);
      final queue = AiInferenceQueue(clock: () => now);
      expect(queue.enqueue(_request('local')), true);
      expect(queue.enqueue(_request('local')), false);
      expect(queue.claimNext(currentRevision: _current), isNull);

      queue.setForeground(true);
      final first = queue.claimNext(currentRevision: _current)!;
      expect(first.startedAt, now);
      expect(first.attempt, 1);
      expect(queue.claimNext(currentRevision: _current), isNull);

      queue.setForeground(false);
      expect(await first.whenStopped, AiJobStopReason.backgrounded);
      expect(queue.job('local')!.state, AiJobState.queued);
      now = now.add(const Duration(minutes: 5));
      queue.setForeground(true);
      expect(queue.claimNext(currentRevision: _current), isNull);
      expect(queue.acknowledgeStopped(first), true);
      final second = queue.claimNext(currentRevision: _current)!;
      expect(second.attempt, 2);
      expect(second.startedAt, now);
      expect(
        queue.complete(first, currentRevision: _current, result: 'old'),
        false,
      );
      expect(
        queue.complete(second, currentRevision: _current, result: 'new'),
        true,
      );
      expect(queue.job('local')!.result, 'new');
    },
  );

  test(
    'queued stale work and late or stale completed results stay inaccessible',
    () {
      var revision = (sourceRevision: 1, contextRevision: 2);
      AiCaptureRevision? lookup(String id) => id == 'capture' ? revision : null;
      final queue = AiInferenceQueue(foreground: true);
      queue.enqueue(_request('late'));
      final first = queue.claimNext(currentRevision: lookup)!;
      queue.enqueue(_request('queued'));
      revision = (sourceRevision: 1, contextRevision: 3);
      queue.invalidateStale(lookup);
      expect(first.stopReason, AiJobStopReason.stale);
      expect(queue.job('queued')!.state, AiJobState.stale);
      expect(
        queue.complete(first, currentRevision: lookup, result: 'old'),
        false,
      );
      expect(queue.job('late')!.result, isNull);

      queue.enqueue(_request('fresh', revision: revision));
      final fresh = queue.claimNext(currentRevision: lookup)!;
      expect(
        queue.complete(fresh, currentRevision: lookup, result: 'review'),
        true,
      );
      revision = (sourceRevision: 2, contextRevision: 3);
      queue.invalidateStale(lookup);
      expect(queue.job('fresh')!.state, AiJobState.stale);
      expect(queue.job('fresh')!.result, isNull);
    },
  );

  test('cancellation and failure do not publish results', () async {
    final queue = AiInferenceQueue(foreground: true);
    queue.enqueue(_request('queued'));
    expect(queue.cancel('queued'), true);
    expect(queue.claimNext(currentRevision: _current), isNull);
    expect(queue.cancel('queued'), false);

    queue.enqueue(_request('executing'));
    final cancelled = queue.claimNext(currentRevision: _current)!;
    expect(queue.cancel('executing'), true);
    expect(await cancelled.whenStopped, AiJobStopReason.cancelled);
    expect(queue.fail(cancelled, currentRevision: _current), false);
    expect(queue.job('executing')!.state, AiJobState.cancelled);
    queue.enqueue(_request('fault'));
    final failed = queue.claimNext(currentRevision: _current)!;
    expect(queue.fail(failed, currentRevision: _current), true);
    expect(queue.job('fault')!.state, AiJobState.failed);
    expect(queue.job('fault')!.result, isNull);
  });

  test('paid jobs require a live matching reservation and lost replies stay charged', () {
    final queue = AiInferenceQueue();
    final ledger = AiBudgetLedger(
      monthlyCapMicros: 60,
      currency: 'GBP',
      clock: () => DateTime.utc(2026, 11, 24),
    );
    queue.enqueue(_request('paid', execution: AiExecution.paidApi));
    expect(queue.claimNext(currentRevision: _current), isNull);

    final other = ledger.reserve(_budgetRequest('different')).reservation!;
    expect(
      queue.claimNext(currentRevision: _current, reservePaid: (_) => other),
      isNull,
    );
    ledger.abandon('different', dispatched: false);

    final old = ledger.reserve(_budgetRequest('old')).reservation!;
    ledger.abandon('old', dispatched: false);
    queue.enqueue(_request('old', execution: AiExecution.paidApi));
    expect(
      queue.claimNext(currentRevision: _current, reservePaid: (_) => old),
      isNull,
    );

    final paid = queue.claimNext(
      currentRevision: _current,
      reservePaid: (request) =>
          ledger.reserve(_budgetRequest(request.id)).reservation,
    )!;
    expect(paid.request.id, 'paid');
    expect(paid.reservation!.isActive, true);
    expect(paid.reservation!.reservedMicros, 35);
    expect(queue.fail(paid, currentRevision: _current), true);
    expect(ledger.abandon('paid')!.chargedMicros, 35);
    expect(paid.reservation!.isActive, false);
    expect(ledger.report().remainingMicros, 25);
  });

  test(
    'interactive jobs are claimed before discretionary jobs of the same kind',
    () {
      final queue = AiInferenceQueue(foreground: true);
      queue.enqueue(_request('pacing', work: AiWorkKind.discretionary));
      queue.enqueue(_request('user'));
      final first = queue.claimNext(currentRevision: _current)!;
      expect(first.request.id, 'user');
      expect(
        queue.complete(first, currentRevision: _current, result: null),
        true,
      );
      final second = queue.claimNext(currentRevision: _current)!;
      expect(second.request.id, 'pacing');
    },
  );
}

AiCaptureRevision? _current(String id) =>
    id == 'capture' ? (sourceRevision: 1, contextRevision: 2) : null;

AiInferenceRequest _request(
  String id, {
  AiExecution execution = AiExecution.local,
  AiWorkKind work = AiWorkKind.interactive,
  AiCaptureRevision revision = (sourceRevision: 1, contextRevision: 2),
}) => AiInferenceRequest(
  id: id,
  captureId: 'capture',
  sourceRevision: revision.sourceRevision,
  contextRevision: revision.contextRevision,
  execution: execution,
  work: work,
);

AiBudgetRequest _budgetRequest(String id) => AiBudgetRequest(
  id: id,
  maxInputTokens: 5,
  maxOutputTokens: 10,
  price: const AiPrice(
    currency: 'GBP',
    inputMicrosPerMillion: 1000000,
    outputMicrosPerMillion: 3000000,
  ),
);
