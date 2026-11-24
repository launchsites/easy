import 'dart:convert';

/// Monetary inputs and serialized totals stay exact on both Dart VM and web.
const aiMaxExactInteger = 9007199254740991;
const _tokensPerMillion = 1000000;
final _maximum = BigInt.from(aiMaxExactInteger);
final _million = BigInt.from(_tokensPerMillion);
final _currencyCode = RegExp(r'^[A-Z]{3}$');

enum AiExecution { paidApi, local }

enum AiWorkKind { interactive, discretionary }

enum AiBudgetDenial {
  invalidRequest,
  missingPrice,
  invalidPrice,
  currencyMismatch,
  duplicateId,
  perCallCostOverflow,
  monthlyCap,
  pacingLimit,
}

enum AiReservationState { reserved, settled, abandoned }

enum AiUsageBasis { actual, reservedMaximum, notDispatched }

class AiPrice {
  const AiPrice({
    required this.currency,
    required this.inputMicrosPerMillion,
    required this.outputMicrosPerMillion,
  });

  final String currency;
  final int inputMicrosPerMillion;
  final int outputMicrosPerMillion;

  bool get valid =>
      _currencyCode.hasMatch(currency) &&
      _validInteger(inputMicrosPerMillion) &&
      _validInteger(outputMicrosPerMillion);

  BigInt _cost(int inputTokens, int outputTokens) {
    final price =
        BigInt.from(inputTokens) * BigInt.from(inputMicrosPerMillion) +
        BigInt.from(outputTokens) * BigInt.from(outputMicrosPerMillion);
    return _roundUp(price, _million);
  }

  Map<String, Object> _toJson() => {
    'currency': currency,
    'inputMicrosPerMillion': inputMicrosPerMillion,
    'outputMicrosPerMillion': outputMicrosPerMillion,
  };

  factory AiPrice._fromJson(Map<String, dynamic> json) => AiPrice(
    currency: json['currency'] as String,
    inputMicrosPerMillion: json['inputMicrosPerMillion'] as int,
    outputMicrosPerMillion: json['outputMicrosPerMillion'] as int,
  );
}

class AiTokenUsage {
  const AiTokenUsage({required this.inputTokens, required this.outputTokens});

  final int inputTokens;
  final int outputTokens;

  bool get valid => _validInteger(inputTokens) && _validInteger(outputTokens);

  Map<String, int> _toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
  };

  factory AiTokenUsage._fromJson(Map<String, dynamic> json) => AiTokenUsage(
    inputTokens: json['inputTokens'] as int,
    outputTokens: json['outputTokens'] as int,
  );
}

class AiBudgetRequest {
  const AiBudgetRequest({
    required this.id,
    required this.maxInputTokens,
    required this.maxOutputTokens,
    this.price,
    this.work = AiWorkKind.interactive,
    this.execution = AiExecution.paidApi,
  });

  final String id;
  final int maxInputTokens;
  final int maxOutputTokens;
  final AiPrice? price;
  final AiWorkKind work;
  final AiExecution execution;

  Map<String, Object> _toJson() => {
    'id': id,
    'maxInputTokens': maxInputTokens,
    'maxOutputTokens': maxOutputTokens,
    if (price != null) 'price': price!._toJson(),
    'work': work.name,
    'execution': execution.name,
  };

  factory AiBudgetRequest._fromJson(Map<String, dynamic> json) =>
      AiBudgetRequest(
        id: json['id'] as String,
        maxInputTokens: json['maxInputTokens'] as int,
        maxOutputTokens: json['maxOutputTokens'] as int,
        price: json['price'] == null
            ? null
            : AiPrice._fromJson(json['price'] as Map<String, dynamic>),
        work: AiWorkKind.values.byName(json['work'] as String),
        execution: AiExecution.values.byName(json['execution'] as String),
      );
}

class AiBudgetMonth {
  const AiBudgetMonth(this.year, this.month)
    : assert(month >= 1 && month <= 12);

  factory AiBudgetMonth.of(DateTime wallClock) =>
      AiBudgetMonth(wallClock.year, wallClock.month);

  final int year;
  final int month;

  int get days => DateTime.utc(year, month + 1, 0).day;
  int get _ordinal => year * 12 + month;

  @override
  bool operator ==(Object other) =>
      other is AiBudgetMonth && year == other.year && month == other.month;

  @override
  int get hashCode => Object.hash(year, month);
}

class AiReservation {
  const AiReservation._({
    required this._owner,
    required this.request,
    required this.month,
    required this.reservedAt,
    required this.reservedMicros,
    this.state = AiReservationState.reserved,
    this.chargedMicros = 0,
    this.usageBasis,
    this.actualUsage,
    this.exceededTokenLimits = false,
  });

  final AiBudgetLedger _owner;
  final AiBudgetRequest request;
  final AiBudgetMonth month;
  final DateTime reservedAt;
  final int reservedMicros;
  final AiReservationState state;
  final int chargedMicros;
  final AiUsageBasis? usageBasis;
  final AiTokenUsage? actualUsage;
  final bool exceededTokenLimits;

  String get id => request.id;
  bool get isActive =>
      state == AiReservationState.reserved &&
      identical(_owner._reservations[id], this);
  bool get exceededReservation => chargedMicros > reservedMicros;

  AiReservation _resolved({
    required AiReservationState state,
    required AiUsageBasis basis,
    required int charge,
    AiTokenUsage? actualUsage,
    bool exceededTokenLimits = false,
  }) => AiReservation._(
    owner: _owner,
    request: request,
    month: month,
    reservedAt: reservedAt,
    reservedMicros: reservedMicros,
    state: state,
    usageBasis: basis,
    chargedMicros: charge,
    actualUsage: actualUsage,
    exceededTokenLimits: exceededTokenLimits,
  );

  Map<String, Object> _toJson() => {
    'request': request._toJson(),
    'month': [month.year, month.month],
    'reservedAt': reservedAt.toIso8601String(),
    'reservedMicros': reservedMicros,
    'state': state.name,
    'chargedMicros': chargedMicros,
    if (usageBasis case final basis?) 'usageBasis': basis.name,
    if (actualUsage case final actual?) 'actualUsage': actual._toJson(),
    'exceededTokenLimits': exceededTokenLimits,
  };

  factory AiReservation._fromJson(
    Map<String, dynamic> json,
    AiBudgetLedger owner,
  ) {
    final month = json['month'] as List;
    final basis = json['usageBasis'];
    return AiReservation._(
      owner: owner,
      request: AiBudgetRequest._fromJson(
        json['request'] as Map<String, dynamic>,
      ),
      month: AiBudgetMonth(month[0] as int, month[1] as int),
      reservedAt: DateTime.parse(json['reservedAt'] as String),
      reservedMicros: json['reservedMicros'] as int,
      state: AiReservationState.values.byName(json['state'] as String),
      chargedMicros: json['chargedMicros'] as int,
      usageBasis: basis == null
          ? null
          : AiUsageBasis.values.byName(basis as String),
      actualUsage: json['actualUsage'] == null
          ? null
          : AiTokenUsage._fromJson(json['actualUsage'] as Map<String, dynamic>),
      exceededTokenLimits: json['exceededTokenLimits'] as bool,
    );
  }
}

class AiBudgetDecision {
  const AiBudgetDecision._({this.reservation, this.denial});

  final AiReservation? reservation;
  final AiBudgetDenial? denial;
  bool get approved => reservation != null;
}

class AiBudgetReport {
  const AiBudgetReport._({
    required this.month,
    required this.asOf,
    required this.currency,
    required this.monthlyCapMicros,
    required this.chargedMicros,
    required this.reservedMicros,
    required this.committedMicros,
    required this.remainingMicros,
    required this.projectedMicros,
    required this.discretionaryMicros,
    required this.knownInputTokens,
    required this.knownOutputTokens,
    required this.unknownUsageCalls,
  });

  final AiBudgetMonth month;
  final DateTime asOf;
  final String currency;
  final int monthlyCapMicros;
  final int chargedMicros;
  final int reservedMicros;
  final int committedMicros;
  final int remainingMicros;
  final int projectedMicros;
  final int discretionaryMicros;
  final int knownInputTokens;
  final int knownOutputTokens;
  final int unknownUsageCalls;
}

/// Synchronous accounting owned by one isolate. Persist the encoded snapshot
/// with the caller's state before starting a reserved API operation.
class AiBudgetLedger {
  AiBudgetLedger({
    required int monthlyCapMicros,
    required this.currency,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _monthlyCapMicros = _checkedCap(monthlyCapMicros) {
    if (!_currencyCode.hasMatch(currency)) {
      throw ArgumentError.value(
        currency,
        'currency',
        'Use a three-letter currency code.',
      );
    }
  }

  final String currency;
  final DateTime Function() _clock;
  final _reservations = <String, AiReservation>{};
  int _monthlyCapMicros;

  int get monthlyCapMicros => _monthlyCapMicros;

  void setMonthlyCapMicros(int micros) {
    _monthlyCapMicros = _checkedCap(micros);
  }

  List<AiReservation> get reservations =>
      List.unmodifiable(_reservations.values);

  int? maximumCost(AiBudgetRequest request) {
    final (cost, denial) = _quote(request);
    return denial == null ? cost : null;
  }

  AiBudgetDecision reserve(AiBudgetRequest request) {
    if (_reservations.containsKey(request.id)) {
      return const AiBudgetDecision._(denial: AiBudgetDenial.duplicateId);
    }
    final (cost, denial) = _quote(request);
    if (denial != null) return AiBudgetDecision._(denial: denial);
    final now = _clock();
    if (_reservations.containsKey(request.id)) {
      return const AiBudgetDecision._(denial: AiBudgetDenial.duplicateId);
    }
    final month = AiBudgetMonth.of(now);
    if (request.execution == AiExecution.paidApi) {
      final report = _report(now, month);
      if (cost > report.remainingMicros) {
        return const AiBudgetDecision._(denial: AiBudgetDenial.monthlyCap);
      }
      if (request.work == AiWorkKind.discretionary &&
          cost > report.discretionaryMicros) {
        return const AiBudgetDecision._(denial: AiBudgetDenial.pacingLimit);
      }
    }
    final reservation = AiReservation._(
      owner: this,
      request: request,
      month: month,
      reservedAt: now,
      reservedMicros: cost,
    );
    _reservations[request.id] = reservation;
    return AiBudgetDecision._(reservation: reservation);
  }

  (int, AiBudgetDenial?) _quote(AiBudgetRequest request) {
    if (request.id.trim().isEmpty ||
        !_validInteger(request.maxInputTokens) ||
        !_validInteger(request.maxOutputTokens) ||
        request.maxOutputTokens == 0) {
      return (0, AiBudgetDenial.invalidRequest);
    }
    final price = request.price;
    if (request.execution == AiExecution.local) {
      return (0, price == null ? null : AiBudgetDenial.invalidRequest);
    }
    if (price == null) return (0, AiBudgetDenial.missingPrice);
    if (!price.valid) return (0, AiBudgetDenial.invalidPrice);
    if (price.currency != currency) return (0, AiBudgetDenial.currencyMismatch);
    final cost = price._cost(request.maxInputTokens, request.maxOutputTokens);
    return cost > _maximum
        ? (0, AiBudgetDenial.perCallCostOverflow)
        : (cost.toInt(), null);
  }

  /// A missing or malformed usage report keeps the full reservation charged.
  /// Settlements are idempotent, including retries of a failed outer write.
  AiReservation? settle(String id, {AiTokenUsage? actual}) {
    final previous = _reservations[id];
    if (previous == null || previous.state != AiReservationState.reserved) {
      return previous;
    }
    final validUsage = actual?.valid == true ? actual : null;
    final price = previous.request.price;
    final charge = validUsage == null
        ? previous.reservedMicros
        : price == null
        ? 0
        : _bounded(
            price._cost(validUsage.inputTokens, validUsage.outputTokens),
          );
    final updated = previous._resolved(
      state: AiReservationState.settled,
      basis: validUsage == null
          ? AiUsageBasis.reservedMaximum
          : AiUsageBasis.actual,
      charge: charge,
      actualUsage: validUsage,
      exceededTokenLimits:
          validUsage != null &&
          (validUsage.inputTokens > previous.request.maxInputTokens ||
              validUsage.outputTokens > previous.request.maxOutputTokens),
    );
    return _reservations[id] = updated;
  }

  /// Release a reservation only when the executor knows it never dispatched.
  /// An operation whose reply was lost may already have incurred its cost.
  AiReservation? abandon(String id, {bool dispatched = true}) {
    final previous = _reservations[id];
    if (previous == null || previous.state != AiReservationState.reserved) {
      return previous;
    }
    final updated = previous._resolved(
      state: AiReservationState.abandoned,
      basis: dispatched
          ? AiUsageBasis.reservedMaximum
          : AiUsageBasis.notDispatched,
      charge: dispatched ? previous.reservedMicros : 0,
    );
    return _reservations[id] = updated;
  }

  AiBudgetReport report({AiBudgetMonth? month}) {
    final now = _clock();
    return _report(now, month ?? AiBudgetMonth.of(now));
  }

  AiBudgetReport _report(DateTime now, AiBudgetMonth month) {
    var charged = BigInt.zero;
    var reserved = BigInt.zero;
    var inputTokens = BigInt.zero;
    var outputTokens = BigInt.zero;
    var unknown = 0;
    for (final entry in _reservations.values) {
      if (entry.month != month ||
          entry.request.execution == AiExecution.local) {
        continue;
      }
      if (entry.state == AiReservationState.reserved) {
        reserved += BigInt.from(entry.reservedMicros);
      } else {
        charged += BigInt.from(entry.chargedMicros);
        if (entry.actualUsage case final usage?) {
          inputTokens += BigInt.from(usage.inputTokens);
          outputTokens += BigInt.from(usage.outputTokens);
        } else if (entry.usageBasis == AiUsageBasis.reservedMaximum) {
          unknown++;
        }
      }
    }
    final committed = charged + reserved;
    final cap = BigInt.from(monthlyCapMicros);
    final current = AiBudgetMonth.of(now);
    final days = BigInt.from(month.days);
    final elapsedDays = BigInt.from(
      month == current
          ? now.day
          : month._ordinal < current._ordinal
          ? month.days
          : 0,
    );
    final paced = cap * elapsedDays ~/ days;
    return AiBudgetReport._(
      month: month,
      asOf: now,
      currency: currency,
      monthlyCapMicros: monthlyCapMicros,
      chargedMicros: _bounded(charged),
      reservedMicros: _bounded(reserved),
      committedMicros: _bounded(committed),
      remainingMicros: _bounded(cap - committed),
      projectedMicros: elapsedDays == BigInt.zero
          ? _bounded(committed)
          : _bounded(_roundUp(committed * days, elapsedDays)),
      discretionaryMicros: _bounded(paced - committed),
      knownInputTokens: _bounded(inputTokens),
      knownOutputTokens: _bounded(outputTokens),
      unknownUsageCalls: unknown,
    );
  }

  String encode() => jsonEncode({
    'version': 1,
    'currency': currency,
    'monthlyCapMicros': monthlyCapMicros,
    'reservations': _reservations.values
        .map((entry) => entry._toJson())
        .toList(),
  });

  factory AiBudgetLedger.decode(String source, {DateTime Function()? clock}) {
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      if (json['version'] is! int || json['version'] != 1) {
        throw const FormatException('Unsupported budget ledger format.');
      }
      final ledger = AiBudgetLedger(
        currency: json['currency'] as String,
        monthlyCapMicros: json['monthlyCapMicros'] as int,
        clock: clock,
      );
      for (final value in json['reservations'] as List) {
        final entry = AiReservation._fromJson(
          value as Map<String, dynamic>,
          ledger,
        );
        final (cost, denial) = ledger._quote(entry.request);
        final actualBasis = entry.usageBasis == AiUsageBasis.actual;
        final usage = entry.actualUsage;
        final price = entry.request.price;
        final actualCost = usage == null || price == null || !usage.valid
            ? 0
            : _bounded(price._cost(usage.inputTokens, usage.outputTokens));
        final exceedsTokens =
            usage != null &&
            (usage.inputTokens > entry.request.maxInputTokens ||
                usage.outputTokens > entry.request.maxOutputTokens);
        if (ledger._reservations.containsKey(entry.id) ||
            denial != null ||
            entry.month != AiBudgetMonth.of(entry.reservedAt) ||
            entry.reservedMicros != cost ||
            !_validInteger(entry.chargedMicros) ||
            (entry.state == AiReservationState.reserved) !=
                (entry.usageBasis == null) ||
            (entry.usageBasis == AiUsageBasis.notDispatched &&
                entry.state != AiReservationState.abandoned) ||
            (actualBasis && entry.state != AiReservationState.settled) ||
            actualBasis != (usage != null) ||
            (usage != null &&
                (!usage.valid || entry.chargedMicros != actualCost)) ||
            entry.exceededTokenLimits != exceedsTokens ||
            (entry.request.execution == AiExecution.local &&
                entry.chargedMicros != 0) ||
            (entry.usageBasis == AiUsageBasis.reservedMaximum &&
                entry.chargedMicros != cost) ||
            (!actualBasis &&
                entry.usageBasis != AiUsageBasis.reservedMaximum &&
                entry.chargedMicros != 0)) {
          throw const FormatException('Invalid budget reservation.');
        }
        ledger._reservations[entry.id] = entry;
      }
      return ledger;
    } on TypeError catch (_) {
      throw const FormatException('Invalid budget ledger.');
    } on ArgumentError catch (_) {
      throw const FormatException('Invalid budget ledger.');
    }
  }
}

bool _validInteger(int value) => value >= 0 && value <= aiMaxExactInteger;

int _checkedCap(int value) {
  if (!_validInteger(value)) {
    throw ArgumentError.value(
      value,
      'monthlyCapMicros',
      'Use a nonnegative exact integer.',
    );
  }
  return value;
}

BigInt _roundUp(BigInt value, BigInt divisor) =>
    (value + divisor - BigInt.one) ~/ divisor;

int _bounded(BigInt value) => value <= BigInt.zero
    ? 0
    : value > _maximum
    ? aiMaxExactInteger
    : value.toInt();
