import 'dart:convert';

import 'package:easy/ai/ai_budget.dart';
import 'package:flutter_test/flutter_test.dart';

const _price = AiPrice(
  currency: 'GBP',
  inputMicrosPerMillion: 1000000,
  outputMicrosPerMillion: 3000000,
);

void main() {
  test(
    'prices and tokens must be explicit, nonnegative, and exactly bounded',
    () {
      final ledger = _ledger(2);
      expect(
        ledger.reserve(_request('missing', price: null)).denial,
        AiBudgetDenial.missingPrice,
      );
      expect(
        ledger
            .reserve(
              _request(
                'negative',
                price: const AiPrice(
                  currency: 'GBP',
                  inputMicrosPerMillion: -1,
                  outputMicrosPerMillion: 0,
                ),
              ),
            )
            .denial,
        AiBudgetDenial.invalidPrice,
      );
      expect(
        ledger
            .reserve(
              _request(
                'wrong-currency',
                price: const AiPrice(
                  currency: 'USD',
                  inputMicrosPerMillion: 0,
                  outputMicrosPerMillion: 0,
                ),
              ),
            )
            .denial,
        AiBudgetDenial.currencyMismatch,
      );
      expect(
        ledger.reserve(_request('zero', output: 0)).denial,
        AiBudgetDenial.invalidRequest,
      );
      expect(
        ledger
            .reserve(
              _request(
                'overflow',
                input: aiMaxExactInteger,
                price: const AiPrice(
                  currency: 'GBP',
                  inputMicrosPerMillion: aiMaxExactInteger,
                  outputMicrosPerMillion: aiMaxExactInteger,
                ),
              ),
            )
            .denial,
        AiBudgetDenial.perCallCostOverflow,
      );
      final fractional = ledger.reserve(
        _request(
          'rounded',
          price: const AiPrice(
            currency: 'GBP',
            inputMicrosPerMillion: 1,
            outputMicrosPerMillion: 1,
          ),
        ),
      );
      expect(fractional.reservation!.reservedMicros, 1);
      expect(
        ledger.reserve(_request('over-call')).denial,
        AiBudgetDenial.monthlyCap,
      );
      expect(ledger.reservations, hasLength(1));
    },
  );

  test(
    'same-isolate requests cannot overrun capacity or reserve one ID twice',
    () async {
      final ledger = _ledger(10);
      final decisions = await Future.wait([
        for (var i = 0; i < 20; i++)
          Future.microtask(
            () => ledger.reserve(_request('request-$i', input: 4, output: 2)),
          ),
      ]);
      expect(decisions.where((decision) => decision.approved), hasLength(1));
      expect(ledger.report().reservedMicros, 10);
      final id = decisions
          .firstWhere((decision) => decision.approved)
          .reservation!
          .id;
      expect(ledger.reserve(_request(id)).denial, AiBudgetDenial.duplicateId);
      expect(
        ledger
            .settle(
              id,
              actual: const AiTokenUsage(inputTokens: 1, outputTokens: 1),
            )!
            .chargedMicros,
        4,
      );
      expect(ledger.report().remainingMicros, 6);
      expect(ledger.report().knownInputTokens, 1);
      expect(ledger.report().knownOutputTokens, 1);

      late final AiBudgetLedger reentrant;
      AiBudgetDecision? nested;
      var nestedClock = false;
      reentrant = AiBudgetLedger(
        monthlyCapMicros: 10,
        currency: 'GBP',
        clock: () {
          if (!nestedClock) {
            nestedClock = true;
            nested = reentrant.reserve(_request('same'));
          }
          return DateTime.utc(2026, 11, 24);
        },
      );
      expect(
        reentrant.reserve(_request('same')).denial,
        AiBudgetDenial.duplicateId,
      );
      expect(nested!.approved, true);
      expect(reentrant.reservations, hasLength(1));
    },
  );

  test(
    'rollover and restart keep a delayed charge in its reservation month',
    () {
      var now = DateTime.utc(2026, 12, 31, 23, 59);
      final ledger = _ledger(10, clock: () => now);
      expect(
        ledger.reserve(_request('dec', input: 4, output: 2)).approved,
        true,
      );
      now = DateTime.utc(2027);
      expect(
        ledger.reserve(_request('jan', input: 4, output: 2)).approved,
        true,
      );
      final restored = AiBudgetLedger.decode(ledger.encode(), clock: () => now);
      expect(restored.report().month, const AiBudgetMonth(2027, 1));
      expect(restored.report().asOf, now);
      expect(restored.report().reservedMicros, 10);
      expect(restored.abandon('dec')!.chargedMicros, 10);
      expect(restored.report().chargedMicros, 0);
      final december = restored.report(month: const AiBudgetMonth(2026, 12));
      expect(december.chargedMicros, 10);
      expect(december.unknownUsageCalls, 1);
      expect(december.reservedMicros, 0);
      expect(
        restored.reserve(_request('dec')).denial,
        AiBudgetDenial.duplicateId,
      );
    },
  );

  test(
    'discretionary work follows civil-month pacing while local work stays free',
    () {
      var now = DateTime.utc(2027, 2, 7);
      final ledger = _ledger(2800, clock: () => now);
      expect(ledger.report().discretionaryMicros, 700);
      expect(
        ledger
            .reserve(
              _request('early', input: 698, work: AiWorkKind.discretionary),
            )
            .denial,
        AiBudgetDenial.pacingLimit,
      );
      expect(ledger.reserve(_request('requested', input: 698)).approved, true);
      expect(ledger.report().projectedMicros, 2804);
      expect(ledger.report().discretionaryMicros, 0);
      now = DateTime.utc(2027, 2, 8);
      expect(ledger.report().discretionaryMicros, 99);
      expect(ledger.report().projectedMicros, 2454);
      ledger.setMonthlyCapMicros(0);
      expect(
        ledger.reserve(_request('paid')).denial,
        AiBudgetDenial.monthlyCap,
      );
      final local = ledger.reserve(
        _request('local', execution: AiExecution.local, price: null),
      );
      expect(local.approved, true);
      expect(local.reservation!.reservedMicros, 0);
      expect(ledger.report().reservedMicros, 701);
    },
  );

  test('failed and lost replies retain liability and verified overruns block calls', () {
    final ledger = _ledger(40);
    expect(ledger.reserve(_request('never-sent', input: 7)).approved, true);
    expect(
      ledger.abandon('never-sent', dispatched: false)!.usageBasis,
      AiUsageBasis.notDispatched,
    );
    expect(ledger.report().remainingMicros, 40);

    expect(ledger.reserve(_request('lost', input: 7)).approved, true);
    expect(ledger.abandon('lost')!.chargedMicros, 10);
    expect(
      ledger
          .settle(
            'lost',
            actual: const AiTokenUsage(inputTokens: 0, outputTokens: 0),
          )!
          .chargedMicros,
      10,
    );
    expect(ledger.reserve(_request('malformed', input: 7)).approved, true);
    expect(
      ledger
          .settle(
            'malformed',
            actual: const AiTokenUsage(inputTokens: -1, outputTokens: 2),
          )!
          .usageBasis,
      AiUsageBasis.reservedMaximum,
    );
    expect(ledger.report().unknownUsageCalls, 2);

    expect(ledger.reserve(_request('overran', input: 7)).approved, true);
    final overran = ledger.settle(
      'overran',
      actual: const AiTokenUsage(inputTokens: 17, outputTokens: 2),
    )!;
    expect(overran.exceededTokenLimits, true);
    expect(overran.exceededReservation, true);
    expect(ledger.report().chargedMicros, 43);
    expect(
      ledger.reserve(_request('blocked')).denial,
      AiBudgetDenial.monthlyCap,
    );
    expect(
      AiBudgetLedger.decode(ledger.encode()).reservations.last.chargedMicros,
      23,
    );
  });

  test(
    'restoring a corrupt committed amount fails rather than granting allowance',
    () {
      final ledger = _ledger(100);
      ledger.reserve(_request('paid'));
      ledger.settle(
        'paid',
        actual: const AiTokenUsage(inputTokens: 1, outputTokens: 1),
      );
      final serialized = jsonDecode(ledger.encode()) as Map<String, dynamic>;
      final entry =
          (serialized['reservations'] as List).single as Map<String, dynamic>;
      entry['chargedMicros'] = 0;
      expect(
        () => AiBudgetLedger.decode(jsonEncode(serialized)),
        throwsFormatException,
      );
    },
  );
}

AiBudgetLedger _ledger(int cap, {DateTime Function()? clock}) => AiBudgetLedger(
  monthlyCapMicros: cap,
  currency: 'GBP',
  clock: clock ?? () => DateTime.utc(2026, 11, 24),
);

AiBudgetRequest _request(
  String id, {
  int input = 1,
  int output = 1,
  AiPrice? price = _price,
  AiWorkKind work = AiWorkKind.interactive,
  AiExecution execution = AiExecution.paidApi,
}) => AiBudgetRequest(
  id: id,
  maxInputTokens: input,
  maxOutputTokens: output,
  price: price,
  work: work,
  execution: execution,
);
