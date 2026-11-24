import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy/ai/ai_budget.dart';

const _seed = 261124;
const _trajectories = 64;
const _steps = 2048;
const _ledgerRevision = 'b942321011984eebffd95af049ea0d3629201e71';
const _caps = [0, 20000, 500000, 40000000, 67000000];

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: ai_budget_replay OUTPUT_JSON');
    exitCode = 2;
    return;
  }
  final random = Random(_seed);
  final operations = <String, int>{};
  final started = Stopwatch()..start();
  for (var index = 0; index < _trajectories; index++) {
    _Trajectory(random, operations, index).run();
  }
  started.stop();
  final evidence = {
    'run_at_utc': DateTime.now().toUtc().toIso8601String(),
    'ledger_source_revision': _ledgerRevision,
    'dart': Platform.version,
    'seed': _seed,
    'trajectories': _trajectories,
    'steps_per_trajectory': _steps,
    'operations': operations,
    'elapsed_ms': started.elapsedMicroseconds / 1000,
    'status': 'all assertions passed',
  };
  File(args.single).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
  );
  stdout.writeln('Verified ${_trajectories * _steps} ledger operations.');
}

class _Trajectory {
  _Trajectory(this.random, this.operations, this.index)
    : now = DateTime.utc(2024 + index % 3, index.isEven ? 2 : 12, 25),
      cap = _caps[index % _caps.length];

  final Random random;
  final Map<String, int> operations;
  final int index;
  final entries = <String, _Entry>{};
  final ids = <String>[];
  late AiBudgetLedger ledger;
  DateTime now;
  int cap;
  int step = 0;

  void run() {
    ledger = AiBudgetLedger(
      monthlyCapMicros: cap,
      currency: 'GBP',
      clock: () => now,
    );
    for (step = 0; step < _steps; step++) {
      final operation = random.nextInt(100);
      if (operation < 50 || ids.isEmpty) {
        reserve();
      } else if (operation < 81) {
        resolve();
      } else if (operation < 91) {
        final before = _month(now);
        now = now.add(Duration(days: random.nextInt(14) - 2));
        count(before == _month(now) ? 'clock_day' : 'clock_month');
        checkReport(before);
      } else if (operation < 96) {
        cap = _caps[random.nextInt(_caps.length)];
        ledger.setMonthlyCapMicros(cap);
        count('cap_change');
      } else {
        final saved = ledger.encode();
        ledger = AiBudgetLedger.decode(saved, clock: () => now);
        check(ledger.encode() == saved, 'Restart changed the ledger');
        count('restart');
      }
      checkReport(_month(now));
    }
    for (final month in entries.values.map((entry) => entry.month).toSet()) {
      checkReport(month);
    }
  }

  void reserve() {
    final id = ids.isNotEmpty && random.nextInt(8) == 0
        ? ids[random.nextInt(ids.length)]
        : '$index/$step';
    final local = random.nextInt(4) == 0;
    final fixture = random.nextInt(31);
    final price = local || fixture == 0
        ? null
        : AiPrice(
            currency: fixture == 1 ? 'USD' : 'GBP',
            inputMicrosPerMillion: fixture == 2 ? -1 : random.nextInt(45000000),
            outputMicrosPerMillion: random.nextInt(45000000),
          );
    final request = AiBudgetRequest(
      id: id,
      maxInputTokens: random.nextInt(15000),
      maxOutputTokens: fixture == 3 ? 0 : 1 + random.nextInt(5000),
      price: price,
      work: random.nextBool()
          ? AiWorkKind.interactive
          : AiWorkKind.discretionary,
      execution: local ? AiExecution.local : AiExecution.paidApi,
    );
    final decision = ledger.reserve(request);
    final month = _month(now);
    final used = totals(month);
    final cost = _cost(price, request.maxInputTokens, request.maxOutputTokens);
    final remaining = max(0, cap - used.charged - used.reserved);
    final paced = max(
      0,
      cap * now.day ~/ _days(month) - used.charged - used.reserved,
    );
    final AiBudgetDenial? expected;
    if (entries.containsKey(id)) {
      expected = AiBudgetDenial.duplicateId;
    } else if (fixture == 3) {
      expected = AiBudgetDenial.invalidRequest;
    } else if (!local && price == null) {
      expected = AiBudgetDenial.missingPrice;
    } else if (!local && fixture == 2) {
      expected = AiBudgetDenial.invalidPrice;
    } else if (!local && fixture == 1) {
      expected = AiBudgetDenial.currencyMismatch;
    } else if (cost > remaining) {
      expected = AiBudgetDenial.monthlyCap;
    } else if (request.work == AiWorkKind.discretionary && cost > paced) {
      expected = AiBudgetDenial.pacingLimit;
    } else {
      expected = null;
    }
    check(decision.denial == expected, 'Reserve disagreed for $id');
    if (expected != null) {
      count('denial_${expected.name}');
      return;
    }
    entries[id] = _Entry(request, month, cost);
    ids.add(id);
    check(
      decision.reservation?.reservedMicros == cost,
      'Wrong reserved amount',
    );
    count(local ? 'reserve_local' : 'reserve_paid');
  }

  void resolve() {
    final id = ids[random.nextInt(ids.length)];
    final entry = entries[id]!;
    final branch = random.nextInt(5);
    final usage = switch (branch) {
      0 => AiTokenUsage(
        inputTokens: random.nextInt(entry.request.maxInputTokens + 1),
        outputTokens: random.nextInt(entry.request.maxOutputTokens + 1),
      ),
      1 => AiTokenUsage(
        inputTokens: entry.request.maxInputTokens + 100,
        outputTokens: entry.request.maxOutputTokens + 100,
      ),
      _ => null,
    };
    final result = branch < 3
        ? ledger.settle(id, actual: usage)
        : ledger.abandon(id, dispatched: branch == 3);
    if (entry.active) {
      entry.active = false;
      entry.usage = usage;
      entry.basis = switch (branch) {
        0 || 1 => AiUsageBasis.actual,
        4 => AiUsageBasis.notDispatched,
        _ => AiUsageBasis.reservedMaximum,
      };
      entry.charge = switch (entry.basis!) {
        AiUsageBasis.actual => _cost(
          entry.request.price,
          usage!.inputTokens,
          usage.outputTokens,
        ),
        AiUsageBasis.reservedMaximum => entry.cost,
        AiUsageBasis.notDispatched => 0,
      };
      count(switch (branch) {
        0 => 'actual_within_envelope',
        1 => 'actual_above_envelope',
        2 => 'settle_missing_usage',
        3 => 'abandon_dispatched',
        _ => 'abandon_before_dispatch',
      });
      if (entry.month != _month(now)) count('resolve_after_clock_month_change');
      checkReport(entry.month);
    } else {
      count('idempotent_resolution');
    }
    check(
      result != null &&
          !result.isActive &&
          result.chargedMicros == entry.charge &&
          result.usageBasis == entry.basis,
      'Wrong resolution for $id',
    );
  }

  ({int charged, int reserved, int inputs, int outputs, int unknown}) totals(
    DateTime month,
  ) {
    var charged = 0;
    var reserved = 0;
    var inputs = 0;
    var outputs = 0;
    var unknown = 0;
    for (final entry in entries.values) {
      if (entry.month != month ||
          entry.request.execution == AiExecution.local) {
        continue;
      }
      if (entry.active) {
        reserved += entry.cost;
      } else {
        charged += entry.charge;
        inputs += entry.usage?.inputTokens ?? 0;
        outputs += entry.usage?.outputTokens ?? 0;
        if (entry.basis == AiUsageBasis.reservedMaximum) unknown++;
      }
    }
    return (
      charged: charged,
      reserved: reserved,
      inputs: inputs,
      outputs: outputs,
      unknown: unknown,
    );
  }

  void checkReport(DateTime month) {
    final actual = ledger.report(month: AiBudgetMonth(month.year, month.month));
    final expected = totals(month);
    final committed = expected.charged + expected.reserved;
    final days = _days(month);
    final elapsed = month == _month(now)
        ? now.day
        : month.isBefore(now)
        ? days
        : 0;
    final projected = elapsed == 0
        ? committed
        : (committed * days + elapsed - 1) ~/ elapsed;
    check(
      actual.monthlyCapMicros == cap &&
          actual.asOf == now &&
          actual.currency == 'GBP' &&
          actual.chargedMicros == expected.charged &&
          actual.reservedMicros == expected.reserved &&
          actual.committedMicros == committed &&
          actual.remainingMicros == max(0, cap - committed) &&
          actual.discretionaryMicros ==
              max(0, cap * elapsed ~/ days - committed) &&
          actual.projectedMicros == projected &&
          actual.knownInputTokens == expected.inputs &&
          actual.knownOutputTokens == expected.outputs &&
          actual.unknownUsageCalls == expected.unknown,
      'Report disagreed for ${month.year}-${month.month}',
    );
    count('monthly_report');
  }

  void count(String key) =>
      operations.update(key, (total) => total + 1, ifAbsent: () => 1);

  void check(bool value, String message) {
    if (!value) {
      throw StateError(
        '$message at seed $_seed, trajectory $index, step $step.',
      );
    }
  }
}

class _Entry {
  _Entry(this.request, this.month, this.cost);

  final AiBudgetRequest request;
  final DateTime month;
  final int cost;
  bool active = true;
  int charge = 0;
  AiUsageBasis? basis;
  AiTokenUsage? usage;
}

DateTime _month(DateTime day) => DateTime.utc(day.year, day.month);

int _days(DateTime month) => DateTime.utc(month.year, month.month + 1, 0).day;

int _cost(AiPrice? price, int input, int output) {
  if (price == null) return 0;
  final numerator =
      input * price.inputMicrosPerMillion +
      output * price.outputMicrosPerMillion;
  return (numerator + 999999) ~/ 1000000;
}
