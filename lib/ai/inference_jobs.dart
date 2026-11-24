import 'dart:async';

import 'ai_budget.dart';

enum AiJobState { queued, running, completed, failed, cancelled, stale }

enum AiJobStopReason { cancelled, backgrounded, stale }

typedef AiCaptureRevision = ({int sourceRevision, int contextRevision});
typedef AiRevisionLookup = AiCaptureRevision? Function(String captureId);
typedef AiPaidReservation = AiReservation? Function(AiInferenceRequest request);

class AiInferenceRequest {
  const AiInferenceRequest({
    required this.id,
    required this.captureId,
    required this.sourceRevision,
    required this.contextRevision,
    this.execution = AiExecution.local,
    this.work = AiWorkKind.interactive,
  });

  final String id;
  final String captureId;
  final int sourceRevision;
  final int contextRevision;
  final AiExecution execution;
  final AiWorkKind work;

  AiCaptureRevision get revision =>
      (sourceRevision: sourceRevision, contextRevision: contextRevision);
}

class AiInferenceJob {
  const AiInferenceJob._({
    required this.request,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.attempts = 0,
    this.result,
  });

  final AiInferenceRequest request;
  final AiJobState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int attempts;
  final Object? result;

  AiInferenceJob _transition(AiJobState next, DateTime at, {Object? result}) =>
      AiInferenceJob._(
        request: request,
        state: next,
        createdAt: createdAt,
        updatedAt: at,
        attempts: next == AiJobState.running ? attempts + 1 : attempts,
        result: result,
      );
}

/// A claim authorizes result delivery for a single attempt.
class AiInferenceClaim {
  AiInferenceClaim._({
    required this._owner,
    required this.request,
    required this.attempt,
    required this.startedAt,
    this.reservation,
  });

  final AiInferenceQueue _owner;
  final AiInferenceRequest request;
  final int attempt;
  final DateTime startedAt;
  final AiReservation? reservation;
  final _stop = Completer<AiJobStopReason>();
  AiJobStopReason? _stopReason;
  bool _requestStarted = false;

  AiJobStopReason? get stopReason => _stopReason;
  Future<AiJobStopReason> get whenStopped => _stop.future;
  bool get requestStarted => _requestStarted;
  bool get isActive =>
      stopReason == null &&
      identical(_owner._claims[request.id], this) &&
      _owner._jobs[request.id]?.state == AiJobState.running;

  /// Claims the single transport operation for this running attempt.
  bool beginRequest() {
    if (!isActive || _requestStarted) return false;
    _requestStarted = true;
    return true;
  }

  void _requestStop(AiJobStopReason reason) {
    if (_stop.isCompleted) return;
    _stopReason = reason;
    _stop.complete(reason);
  }
}

/// Cooperative scheduling only. Workers own execution and must acknowledge
/// cancellation, so restarting foreground work cannot overlap a stopping worker.
class AiInferenceQueue {
  AiInferenceQueue({this._foreground = false, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _jobs = <String, AiInferenceJob>{};
  final _claims = <String, AiInferenceClaim>{};
  bool _foreground;

  bool get foreground => _foreground;
  List<AiInferenceJob> get jobs => List.unmodifiable(_jobs.values);

  AiInferenceJob? job(String id) => _jobs[id];

  bool enqueue(AiInferenceRequest request) {
    if (request.id.trim().isEmpty ||
        request.captureId.trim().isEmpty ||
        request.sourceRevision < 0 ||
        request.contextRevision < 0 ||
        _jobs.containsKey(request.id)) {
      return false;
    }
    final now = _clock();
    _jobs[request.id] = AiInferenceJob._(
      request: request,
      state: AiJobState.queued,
      createdAt: now,
      updatedAt: now,
    );
    return true;
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) return;
    for (final claim in _claims.values) {
      final job = _jobs[claim.request.id]!;
      if (claim.request.execution == AiExecution.local &&
          job.state == AiJobState.running) {
        claim._requestStop(AiJobStopReason.backgrounded);
        _jobs[claim.request.id] = job._transition(AiJobState.queued, _clock());
      }
    }
  }

  /// Paid jobs require an existing reservation for the same request ID and
  /// work class. The caller persists it before dispatch and settles it even if
  /// the job's eventual output becomes stale.
  AiInferenceClaim? claimNext({
    required AiRevisionLookup currentRevision,
    AiPaidReservation? reservePaid,
  }) {
    invalidateStale(currentRevision);
    final jobs = _jobs.values.toList();
    for (final work in AiWorkKind.values) {
      for (final job in jobs) {
        final request = job.request;
        if (job.state != AiJobState.queued ||
            request.work != work ||
            _jobs[request.id]?.state != AiJobState.queued ||
            _claims.values.any(
              (claim) => claim.request.execution == request.execution,
            )) {
          continue;
        }
        AiReservation? reservation;
        if (request.execution == AiExecution.local) {
          if (!_foreground) continue;
        } else {
          reservation = reservePaid?.call(request);
          if (reservation == null ||
              reservation.id != request.id ||
              reservation.request.execution != AiExecution.paidApi ||
              reservation.request.work != request.work ||
              !reservation.isActive ||
              _jobs[request.id]?.state != AiJobState.queued) {
            continue;
          }
        }
        final started = _clock();
        final running = job._transition(AiJobState.running, started);
        _jobs[request.id] = running;
        return _claims[request.id] = AiInferenceClaim._(
          owner: this,
          request: request,
          attempt: running.attempts,
          startedAt: started,
          reservation: reservation,
        );
      }
    }
    return null;
  }

  bool cancel(String id) {
    final job = _jobs[id];
    if (job == null || !_active(job.state)) return false;
    _claims[id]?._requestStop(AiJobStopReason.cancelled);
    _jobs[id] = job._transition(AiJobState.cancelled, _clock());
    return true;
  }

  void invalidateStale(AiRevisionLookup currentRevision) {
    for (final job in _jobs.values.toList()) {
      final request = job.request;
      if ((_active(job.state) || job.state == AiJobState.completed) &&
          currentRevision(request.captureId) != request.revision) {
        _claims[request.id]?._requestStop(AiJobStopReason.stale);
        _jobs[request.id] = job._transition(AiJobState.stale, _clock());
      }
    }
  }

  bool acknowledgeStopped(AiInferenceClaim claim) {
    if (claim.stopReason == null ||
        !identical(_claims[claim.request.id], claim)) {
      return false;
    }
    _claims.remove(claim.request.id);
    return true;
  }

  bool complete(
    AiInferenceClaim claim, {
    required AiRevisionLookup currentRevision,
    required Object? result,
  }) => _resolve(claim, currentRevision, AiJobState.completed, result: result);

  bool fail(
    AiInferenceClaim claim, {
    required AiRevisionLookup currentRevision,
  }) => _resolve(claim, currentRevision, AiJobState.failed);

  bool _resolve(
    AiInferenceClaim claim,
    AiRevisionLookup currentRevision,
    AiJobState next, {
    Object? result,
  }) {
    final request = claim.request;
    if (!identical(_claims[request.id], claim)) return false;
    _claims.remove(request.id);
    final job = _jobs[request.id]!;
    if (claim.stopReason != null || job.state != AiJobState.running) {
      return false;
    }
    if (currentRevision(request.captureId) != request.revision) {
      claim._requestStop(AiJobStopReason.stale);
      _jobs[request.id] = job._transition(AiJobState.stale, _clock());
      return false;
    }
    _jobs[request.id] = job._transition(next, _clock(), result: result);
    return true;
  }
}

bool _active(AiJobState state) =>
    state == AiJobState.queued || state == AiJobState.running;
