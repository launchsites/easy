part of 'main.dart';

extension _WorkspaceWorkoutCapture on _WorkspaceState {
  GymSession? _liveWorkoutFor(DateTime date, Iterable<GymSession> sessions) =>
      sessions
          .where(
            (session) => !session.finished && !date.isBefore(session.startedAt),
          )
          .lastOrNull;

  String _workoutSourceText(CaptureReview review, CaptureProposal proposal) {
    final text = review.input.text;
    final details = proposal.evidence['details'];
    final explicit = details?.provenance == CaptureProvenance.explicit
        ? details?.span
        : null;
    if (explicit case final span?
        when span.isWithin(text) &&
            span.start >= proposal.span.start &&
            span.end <= proposal.span.end) {
      return span.textFrom(text);
    }
    return proposal.span.textFrom(text);
  }

  CaptureWorkoutPreview? _inspectWorkoutCapture(
    CaptureReview review,
    CaptureProposal proposal,
  ) {
    if (proposal.draft is! CaptureWorkoutDraft) return null;
    final recordedAt = review.input.context.anchor;
    final session = _liveWorkoutFor(recordedAt, _gymSessions ?? const []);
    if (session == null) {
      return (draft: null, detail: 'Save to workout history');
    }
    final checked = reviewGymWorkoutCapture(
      session: session,
      originalText: _workoutSourceText(review, proposal),
      recordedAt: recordedAt,
    );
    final draft = checked.draft;
    if (draft == null) {
      return (
        draft: null,
        detail: checked.issue?.message ?? 'Save as a session note',
      );
    }
    return (draft: draft, detail: draft.detail);
  }
}
