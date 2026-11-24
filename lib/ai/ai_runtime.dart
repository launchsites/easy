import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../capture/capture_interpreter.dart';
import 'ai_budget.dart';
import 'ai_runtime_settings.dart';
import 'inference_jobs.dart';
import 'provider/ai_provider.dart';

export 'ai_runtime_settings.dart';
export 'inference_jobs.dart' show AiCaptureRevision, AiRevisionLookup;
export 'provider/ai_provider.dart' show AiEstimateInput;

class AiStoredState {
  const AiStoredState({required this.revision, required this.value});

  final int revision;
  final String value;
}

typedef AiRuntimeRead = Future<AiStoredState?> Function();
typedef AiRuntimeCompareAndSwap = Future<int?> Function(
  int expectedRevision,
  String value,
);
typedef AiAuthorize = Future<bool> Function(AiTransmissionPreview preview);

enum AiSettingsSaveStatus {
  saved,
  invalid,
  busy,
  storageUnavailable,
  vaultUnavailable,
}

enum AiRunStatus {
  ready,
  fallback,
  declined,
  stale,
  busy,
  blocked,
  storageUnavailable,
}

class AiTransmissionPreview {
  AiTransmissionPreview._({
    required this.route,
    required this.endpoint,
    required this.model,
    required Map<String, Object?> fields,
    required this.reserveMicros,
  }) : fields = Map.unmodifiable(fields);

  final AiRoute route;
  final Uri endpoint;
  final String model;
  final Map<String, Object?> fields;
  final int? reserveMicros;
}

class AiRuntimeOutcome<T> {
  const AiRuntimeOutcome._({
    required this.status,
    required this.source,
    this.value,
    this.message,
  });

  final AiRunStatus status;
  final AiRoute source;
  final T? value;
  final String? message;
}

class AiDurationReview {
  const AiDurationReview._({required this.duration, required this.uncertainty});

  final Duration duration;
  final String uncertainty;
  bool get requiresReview => true;
}

/// Opt-in review runtime. Its durable state contains settings and one GBP
/// ledger. Capture text and credentials stay outside that state.
class AiRuntime extends ChangeNotifier {
  AiRuntime({
    required this._read,
    required this._compareAndSwap,
    AiWritableCredentialVault? vault,
    http.Client? transport,
    DateTime Function()? clock,
    this._foreground = true,
  }) : _vault = vault ?? AiSessionCredentialVault(),
       _transport = transport ?? createAiProviderHttpClient(),
       _ownsTransport = transport == null,
       _clock = clock ?? DateTime.now;

  final AiRuntimeRead _read;
  final AiRuntimeCompareAndSwap _compareAndSwap;
  final AiWritableCredentialVault _vault;
  final http.Client _transport;
  final bool _ownsTransport;
  final DateTime Function() _clock;
  AiRuntimeSettings _settings = const AiRuntimeSettings();
  late AiBudgetLedger _ledger = _emptyLedger();
  late AiProviderClient _provider = _providerFor(_ledger);
  Future<void> _writes = Future.value();
  bool _foreground;
  bool _loaded = false;
  bool _storageReady = false;
  bool _busy = false;
  bool _disposed = false;
  bool _cancelRequested = false;
  int _revision = 0;
  String? _durableValue;
  AiInferenceQueue? _queue;
  String? _runningId;
  int _serial = 0;

  AiRuntimeSettings get settings => _settings;
  AiBudgetReport get budget => _ledger.report();
  bool get busy => _busy;
  bool get storageReady => _storageReady;
  bool get persistentVault => _vault.persistent;

  Future<bool> load({bool refresh = false}) => _writeLane(() async {
    if (_disposed || (_busy && refresh)) return false;
    if (_loaded && !refresh) return _storageReady;
    try {
      final stored = await _read().timeout(const Duration(seconds: 5));
      var next = const AiRuntimeSettings();
      var ledger = _emptyLedger();
      if (stored != null) {
        if (stored.revision < 1) {
          throw const FormatException('Invalid state revision.');
        }
        final parsed = jsonDecode(stored.value) as Map<String, dynamic>;
        if (parsed['version'] is! int || parsed['version'] != 1) {
          throw const FormatException('Invalid AI state version.');
        }
        next = AiRuntimeSettings.fromJson(
          parsed['settings'] as Map<String, dynamic>,
        );
        ledger = AiBudgetLedger.decode(
          jsonEncode(parsed['budget']),
          clock: _clock,
        );
        if (!next.valid ||
            ledger.currency != 'GBP' ||
            ledger.monthlyCapMicros != next.monthlyCapMicros) {
          throw const FormatException('Invalid AI state.');
        }
      }
      _settings = next;
      _ledger = ledger;
      _provider = _providerFor(ledger);
      _revision = stored?.revision ?? 0;
      _durableValue = stored?.value;
      _storageReady = true;
      var hasUnresolved = false;
      for (final entry in ledger.reservations) {
        if (entry.state == AiReservationState.reserved) {
          ledger.abandon(
            entry.id,
            dispatched: entry.request.execution == AiExecution.paidApi,
          );
          hasUnresolved = true;
        }
      }
      if (hasUnresolved) await _commit(next, ledger);
    } catch (_) {
      _storageReady = false;
    }
    _loaded = true;
    _notify();
    return _storageReady;
  });

  Future<AiSettingsSaveStatus> saveSettings(
    AiRuntimeSettings next, {
    String? apiKey,
  }) async {
    await load();
    return _writeLane(() async {
      if (_busy) return AiSettingsSaveStatus.busy;
      if (!_storageReady || _disposed) {
        return AiSettingsSaveStatus.storageUnavailable;
      }
      final reference = next.apiCredentialReference;
      if (!next.valid ||
          (apiKey != null && (reference == null || !validAiKey(apiKey)))) {
        return AiSettingsSaveStatus.invalid;
      }
      final previousCap = _ledger.monthlyCapMicros;
      _ledger.setMonthlyCapMicros(next.monthlyCapMicros);
      if (!await _commit(next, _ledger)) {
        _ledger.setMonthlyCapMicros(previousCap);
        return AiSettingsSaveStatus.storageUnavailable;
      }
      _settings = next;
      if (apiKey != null) {
        try {
          await _vault.write(reference!, apiKey);
        } catch (_) {
          _notify();
          return AiSettingsSaveStatus.vaultUnavailable;
        }
      }
      _notify();
      return AiSettingsSaveStatus.saved;
    });
  }

  Future<bool> hasApiKey() => _keyAvailable(_settings.apiCredentialReference);

  Future<bool> deleteApiKey() => _writeLane(() async {
    final reference = _settings.apiCredentialReference;
    if (_disposed || _busy || reference == null) return false;
    try {
      await _vault.delete(reference);
      _notify();
      return true;
    } catch (_) {
      return false;
    }
  });

  void setForeground(bool foreground) {
    _foreground = foreground;
    _queue?.setForeground(foreground);
    if (!foreground && _busy && _queue == null) _cancelRequested = true;
  }

  void cancelCurrent() {
    if (!_busy) return;
    _cancelRequested = true;
    if (_runningId case final id?) _queue?.cancel(id);
  }

  Future<AiRuntimeOutcome<CaptureReview>> runCapture({
    required CaptureInput input,
    required AiRevisionLookup currentRevision,
    required AiAuthorize authorize,
  }) async {
    final manual = interpretCapture(input);
    return _run(
      source: input,
      currentRevision: currentRevision,
      authorize: authorize,
      work: AiWorkKind.interactive,
      fallback: () => manual,
      payload: (settings) => aiCapturePayload(
        input,
        includeOptionalMetadata: settings.includeOptionalMetadata,
      ),
      routeBlock: (settings) {
        if (!settings.includeOptionalMetadata &&
            manual.proposals.any(
              (item) => item.draft is CaptureCompleteTaskDraft,
            )) {
          return 'Review contextual completions on this device.';
        }
        return null;
      },
      execute: (config, claim, settings) => _provider.capture(
        config: config,
        claim: claim,
        input: input,
        currentRevision: currentRevision,
        includeOptionalMetadata: settings.includeOptionalMetadata,
      ),
      convert: (review) => review,
    );
  }

  Future<AiRuntimeOutcome<AiDurationReview>> runEstimate({
    required CaptureInput source,
    required AiEstimateInput input,
    required AiRevisionLookup currentRevision,
    required AiAuthorize authorize,
  }) => _run(
    source: source,
    currentRevision: currentRevision,
    authorize: authorize,
    work: AiWorkKind.discretionary,
    fallback: () => _offlineEstimate(input),
    payload: (settings) => aiEstimatePayload(
      _estimateInput(input, settings),
      captureId: source.id,
      sourceRevision: source.revision,
      contextRevision: source.context.revision,
    ),
    routeBlock: (_) => input.title.trim().isEmpty
        ? 'Enter a title to estimate its duration.'
        : null,
    execute: (config, claim, settings) => _provider.estimate(
      config: config,
      claim: claim,
      input: _estimateInput(input, settings),
      currentRevision: currentRevision,
    ),
    convert: (estimate) => AiDurationReview._(
      duration: estimate.duration,
      uncertainty: 'Provider estimate for review.',
    ),
  );

  Future<AiRuntimeOutcome<T>> _run<T extends Object, P extends Object>({
    required CaptureInput source,
    required AiRevisionLookup currentRevision,
    required AiAuthorize authorize,
    required AiWorkKind work,
    required T? Function() fallback,
    required Map<String, Object?> Function(AiRuntimeSettings settings) payload,
    required String? Function(AiRuntimeSettings settings) routeBlock,
    required Future<AiProviderResult<P>> Function(
      AiProviderConfig config,
      AiInferenceClaim claim,
      AiRuntimeSettings settings,
    )
    execute,
    required T Function(P result) convert,
  }) async {
    final ready = await load();
    AiRuntimeOutcome<T> status(AiRunStatus state, [String? message]) =>
        AiRuntimeOutcome._(
          status: state,
          source: settings.route,
          message: message,
        );
    AiRuntimeOutcome<T> localReview([String? message]) {
      final value = fallback();
      return AiRuntimeOutcome._(
        status: value == null
            ? AiRunStatus.blocked
            : message == null
            ? AiRunStatus.ready
            : AiRunStatus.fallback,
        source: AiRoute.offline,
        value: value,
        message: message,
      );
    }

    if (!ready || _disposed) {
      return status(
        AiRunStatus.storageUnavailable,
        'Reload AI settings to continue.',
      );
    }
    if (_busy) return status(AiRunStatus.busy);
    if (!_current(source, currentRevision)) return status(AiRunStatus.stale);
    final activeSettings = settings;
    final discretionary = work == AiWorkKind.discretionary;
    if (discretionary && !activeSettings.allowEstimates) {
      return status(AiRunStatus.blocked);
    }
    if (activeSettings.route == AiRoute.offline) return localReview();
    if (!_foreground) return status(AiRunStatus.blocked);

    _busy = true;
    _cancelRequested = false;
    _notify();
    try {
      if (!await _verifyHead()) return status(AiRunStatus.storageUnavailable);
      if (!_current(source, currentRevision)) return status(AiRunStatus.stale);
      if (_cancelRequested || !_foreground) return status(AiRunStatus.declined);

      final config = activeSettings.provider;
      final endpoint = config?.completionsEndpoint;
      if (config == null || endpoint == null) {
        return localReview('Configure a valid provider to use this route.');
      }
      if (routeBlock(activeSettings) case final message?) {
        return localReview(message);
      }
      final fields = payload(activeSettings);
      if (!_provider.fitsRequest(config, fields, estimate: discretionary)) {
        return localReview('This input exceeds the configured request limit.');
      }
      final paid = config.execution == AiExecution.paidApi;
      final id = _requestId();
      final budgetRequest = config.budgetRequest(id, work: work);
      final maximum = paid ? _ledger.maximumCost(budgetRequest) : null;
      if (paid) {
        final available = discretionary
            ? budget.discretionaryMicros
            : budget.remainingMicros;
        if (maximum == null || maximum > available) {
          return localReview(
            'The current allowance cannot cover this request.',
          );
        }
        if (!await _keyAvailable(config.credentialRef)) {
          return localReview(
            'Add an API key for this endpoint in AI settings.',
          );
        }
      }
      if (!_current(source, currentRevision)) return status(AiRunStatus.stale);
      if (_cancelRequested || !_foreground) return status(AiRunStatus.declined);
      if (paid || activeSettings.confirmLocal) {
        var allowed = false;
        try {
          allowed = await authorize(
            AiTransmissionPreview._(
              route: activeSettings.route,
              endpoint: endpoint,
              model: config.model,
              fields: fields,
              reserveMicros: maximum,
            ),
          );
        } catch (_) {
          return status(AiRunStatus.declined);
        }
        if (!allowed) return status(AiRunStatus.declined);
      }

      if (_cancelRequested || !_foreground) return status(AiRunStatus.declined);
      if (!await _verifyHead()) return status(AiRunStatus.storageUnavailable);
      if (!_current(source, currentRevision)) return status(AiRunStatus.stale);
      if (_cancelRequested || !_foreground) return status(AiRunStatus.declined);
      final queue = AiInferenceQueue(foreground: true, clock: _clock);
      _queue = queue;
      _runningId = id;
      queue.enqueue(
        AiInferenceRequest(
          id: id,
          captureId: source.id,
          sourceRevision: source.revision,
          contextRevision: source.context.revision,
          execution: config.execution,
          work: work,
        ),
      );
      final claim = queue.claimNext(
        currentRevision: (id) => _lookup(currentRevision, id),
        reservePaid: (_) => _ledger.reserve(budgetRequest).reservation,
      );
      if (claim == null) {
        return localReview('The current allowance cannot cover this request.');
      }

      final reply = await execute(config, claim, activeSettings);
      if (reply.succeeded &&
          queue.complete(
            claim,
            currentRevision: (id) => _lookup(currentRevision, id),
            result: null,
          )) {
        return AiRuntimeOutcome._(
          status: AiRunStatus.ready,
          source: activeSettings.route,
          value: convert(reply.value!),
        );
      }
      queue.fail(claim, currentRevision: (id) => _lookup(currentRevision, id));
      if (reply.failure == AiProviderFailure.accountingUnavailable) {
        return status(AiRunStatus.storageUnavailable);
      }
      if (reply.failure == AiProviderFailure.stale ||
          !_current(source, currentRevision)) {
        return status(AiRunStatus.stale);
      }
      if (_cancelRequested || reply.failure == AiProviderFailure.cancelled) {
        return status(AiRunStatus.declined);
      }
      return localReview('Review this input using the offline tools.');
    } finally {
      _queue = null;
      _runningId = null;
      _busy = false;
      _notify();
    }
  }

  Future<bool> _verifyHead() => _writeLane(() async {
    if (!_storageReady) return false;
    try {
      final recorded = await _read().timeout(const Duration(seconds: 5));
      if (recorded?.value != _durableValue ||
          (recorded?.revision ?? 0) < _revision) {
        _storageReady = false;
        _notify();
        return false;
      }
      _revision = recorded?.revision ?? 0;
      return true;
    } catch (_) {
      _storageReady = false;
      _notify();
      return false;
    }
  });

  Future<bool> _commit(
    AiRuntimeSettings settings,
    AiBudgetLedger ledger,
  ) async {
    final data = jsonEncode({
      'version': 1,
      'settings': settings.toJson(),
      'budget': jsonDecode(ledger.encode()),
    });
    if (data == _durableValue) return true;
    try {
      final revision = await _compareAndSwap(_revision, data);
      if (revision == null || revision <= _revision) {
        _storageReady = false;
      } else {
        _revision = revision;
        _durableValue = data;
        return true;
      }
    } catch (_) {
      _storageReady = false;
    }
    _notify();
    return false;
  }

  Future<T> _writeLane<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  AiBudgetLedger _emptyLedger() =>
      AiBudgetLedger(currency: 'GBP', monthlyCapMicros: 0, clock: _clock);

  String _requestId() {
    final stamp = _clock().microsecondsSinceEpoch;
    final existing = _ledger.reservations.map((entry) => entry.id).toSet();
    String id;
    do {
      id = '$stamp-ai-${_serial++}';
    } while (existing.contains(id));
    return id;
  }

  AiProviderClient _providerFor(AiBudgetLedger ledger) => AiProviderClient(
    transport: _transport,
    vault: _vault,
    ledger: ledger,
    persistBudget: (_) => _writeLane(() async {
      if (!_storageReady ||
          !identical(ledger, _ledger) ||
          !await _commit(_settings, ledger)) {
        throw StateError('AI budget state unavailable.');
      }
      _notify();
    }),
  );

  Future<bool> _keyAvailable(String? reference) async {
    if (reference == null) return false;
    try {
      final key = await _vault
          .read(reference)
          .timeout(const Duration(seconds: 5));
      return key != null && validAiKey(key);
    } catch (_) {
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    cancelCurrent();
    _disposed = true;
    if (_ownsTransport) _transport.close();
    super.dispose();
  }
}

AiEstimateInput _estimateInput(
  AiEstimateInput input,
  AiRuntimeSettings settings,
) => AiEstimateInput(
  title: input.title,
  sampleDurationsMinutes: settings.includeOptionalMetadata
      ? _samples(input)
      : [],
);

List<int> _samples(AiEstimateInput input) => [
  for (final value in input.sampleDurationsMinutes.take(32))
    if (value >= 1 && value <= 1440) value,
];

AiDurationReview? _offlineEstimate(AiEstimateInput input) {
  if (input.title.trim().isEmpty) return null;
  final samples = _samples(input)..sort();
  if (samples.isEmpty) return null;
  final mid = samples.length ~/ 2;
  final minutes = samples.length.isOdd
      ? samples[mid]
      : (samples[mid - 1] + samples[mid]) ~/ 2;
  return AiDurationReview._(
    duration: Duration(minutes: minutes),
    uncertainty: samples.length == 1
        ? 'One prior duration provides limited evidence.'
        : 'Median of ${samples.length} prior durations, ranging from '
              '${samples.first} to ${samples.last} minutes.',
  );
}

bool _current(CaptureInput input, AiRevisionLookup lookup) {
  return input.id.trim().isNotEmpty &&
      _lookup(lookup, input.id) ==
          (
            sourceRevision: input.revision,
            contextRevision: input.context.revision,
          );
}

AiCaptureRevision? _lookup(AiRevisionLookup lookup, String id) {
  try {
    return lookup(id);
  } catch (_) {
    return null;
  }
}
