import 'package:easy/ai/ai_budget.dart';
import 'package:easy/ai/ai_enrichment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a £40 cap and £1 a day sustainably allow six 5p drafts', () {
    final when = DateTime.utc(2026, 6, 15, 12);
    final ledger = AiBudgetLedger(
      monthlyCapMicros: 40000000,
      currency: 'GBP',
      clock: () => when,
    );
    expect(
      ledger
          .reserve(
            const AiBudgetRequest(
              id: 'sixteen-days-test-start',
              maxInputTokens: 15000000,
          maxOutputTokens: 1,
              price: AiPrice(
                currency: 'GBP',
                inputMicrosPerMillion: 1000000,
                outputMicrosPerMillion: 0,
              ),
            ),
          )
          .approved,
      isTrue,
    );
    ledger.settle('sixteen-days-test-start');
    expect(ledger.report().projectedMicros, 30000000);
    final pace = AiAutomaticPace.forApi(
      budget: ledger.report(),
      requestMicros: 50000,
      adaptive: true,
    );
    expect(pace?.dailyAttempts, 6);
    expect(pace?.minimumMinutes, 30);
    expect(
      AiAutomaticPace.forApi(
        budget: ledger.report(),
        requestMicros: 2000000,
        adaptive: true,
      ),
      isNull,
    );
    ledger.setMonthlyCapMicros(30000000);
    expect(
      AiAutomaticPace.forApi(
        budget: ledger.report(),
        requestMicros: 50000,
        adaptive: true,
      ),
      isNull,
    );
  });

  test('local pacing survives restart and keeps a distinct daily quota', () {
    final pace = AiAutomaticPace.forLocal(adaptive: true);
    final start = DateTime.utc(2026, 11, 24, 12);
    AiEnrichmentCandidate candidate(int number) => AiEnrichmentCandidate(
      taskId: 'draft-$number',
      title: 'Review files',
      sourceRevision: 1,
      contextRevision: 2,
    );
    var state = AiEnrichmentState();
    for (var index = 0; index < 6; index++) {
      final at = start.add(Duration(minutes: index * 20));
      expect(state.permits(candidate(index), at, pace), isTrue);
      state = AiEnrichmentState.fromJson(
        state.withAttempt(candidate(index), at).toJson(),
      );
      expect(
        state.permits(
          candidate(index + 1),
          at.add(const Duration(minutes: 19)),
          pace,
        ),
        isFalse,
      );
    }
    expect(
      state.permits(candidate(6), start.add(const Duration(hours: 8)), pace),
      isFalse,
    );
    final tomorrow = start.add(const Duration(days: 1));
    expect(state.permits(candidate(6), tomorrow, pace), isTrue);
    expect(state.permits(candidate(1), tomorrow, pace), isFalse);
  });

  test('legacy hour stamps preserve the previous spending fence', () {
    final attempt = DateTime.utc(2026, 11, 24, 10);
    final state = AiEnrichmentState.fromJson({
      'lastHour': AiEnrichmentState.minuteOf(attempt) ~/ 60,
      'attempted': <String, List<int>>{},
      'pending': <Object>[],
    });
    expect(
      state.permitsTime(
        attempt.add(const Duration(minutes: 59)),
        const AiAutomaticPace.hourly(),
      ),
      isFalse,
    );
    expect(
      state.permitsTime(
        attempt.add(const Duration(hours: 1)),
        const AiAutomaticPace.hourly(),
      ),
      isTrue,
    );
    final adaptive = AiAutomaticPace.forLocal(adaptive: true);
    expect(
      state.permitsTime(attempt.add(const Duration(minutes: 78)), adaptive),
      isFalse,
    );
    expect(
      state.permitsTime(attempt.add(const Duration(minutes: 79)), adaptive),
      isTrue,
    );
  });
}
