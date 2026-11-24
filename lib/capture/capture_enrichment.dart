part of 'capture_interpreter.dart';

final _unsafeEnrichment = RegExp(
  r'\b(?:delete|erase|overwrite|ignore (?:the |all )?(?:previous|prior)|'
  r'cancel all|move everything|mark (?:all|every))\b',
  caseSensitive: false,
);
final _dateEnrichment = RegExp(
  r'\b(?:today|tomorrow|yesterday|next week|tonight|monday|tuesday|wednesday|'
  r'thursday|friday|saturday|sunday)\b|\b\d{1,4}[-/]\d{1,2}[-/]\d{1,4}\b',
  caseSensitive: false,
);

typedef _CaptureClause = ({
  _Slice slice,
  _Scope scope,
  CaptureProposal? original,
  List<String> choices,
});

/// Classifier input uses stable clause numbers and the original words.
/// The model can choose a permitted interpretation or leave a clause alone.
List<Map<String, Object>> captureEnrichmentChoices(CaptureInput input) {
  final original = interpretCapture(input);
  final clauses = _modelClauses(input, original);
  return [
    for (final (index, clause) in clauses.indexed)
      if (clause.choices.isNotEmpty)
        {
          'clause': index,
          'text': clause.slice.text,
          'choices': clause.choices,
          'existingKind': ?clause.original?.draft.kind.name,
          'explicitCategory': ?clause.scope.category,
        },
  ];
}

List<_CaptureClause> _modelClauses(CaptureInput input, CaptureReview original) {
  final source = _Slice(input.text, 0, input.text.length).trim();
  final names = _CategoryNames(input.context.categories);
  final proposals = {
    for (final proposal in original.proposals) proposal.span: proposal,
  };
  final unknown = {
    for (final issue in original.issues)
      if (issue.code == CaptureIssueCode.unrecognizedIntent) issue.span,
  };
  return [
    for (final slice in _split(source, names).take(24))
      _classifyClause(
        slice,
        _readScope(slice, names),
        proposals[slice.span],
        unknown.contains(slice.span),
      ),
  ];
}

_CaptureClause _classifyClause(
  _Slice slice,
  _Scope scope,
  CaptureProposal? existing,
  bool unknown,
) {
  final text = scope.body.text.trim();
  final safe =
      scope.issues.isEmpty &&
      text.isNotEmpty &&
      text.length <= 3000 &&
      !_unsafeEnrichment.hasMatch(text);
  final choices = <String>[];
  if (safe &&
      existing != null &&
      existing.isReady &&
      existing.draft.category == null &&
      (existing.draft is CaptureTaskDraft ||
          existing.draft is CaptureNoteDraft)) {
    choices.add('category');
  }
  if (safe &&
      existing == null &&
      unknown &&
      !text.endsWith('?') &&
      !_dateEnrichment.hasMatch(text) &&
      !_numericDate.hasMatch(text) &&
      !_dateCue.hasMatch(text) &&
      !_clockCue.hasMatch(text)) {
    if (text.length <= 300) choices.add('task');
    choices.add('note');
  }
  return (slice: slice, scope: scope, original: existing, choices: choices);
}

CaptureReview _validateModelEnrichment(
  CaptureInput input,
  Map<String, Object?> object,
) {
  CaptureReview reject(CaptureIssueCode code, String message) =>
      CaptureReview(input: input, issues: [CaptureIssue(code, message)]);

  CaptureReview invalid() => reject(
    CaptureIssueCode.invalidModelOutput,
    'Review the original capture text.',
  );
  if (!_keysMatch(object, const {
        'version',
        'captureId',
        'sourceRevision',
        'contextRevision',
        'suggestions',
      }) ||
      object['captureId'] is! String ||
      object['sourceRevision'] is! int ||
      object['contextRevision'] is! int ||
      object['suggestions'] is! List) {
    return invalid();
  }
  if (object['captureId'] != input.id ||
      object['sourceRevision'] != input.revision) {
    return reject(
      CaptureIssueCode.staleSource,
      'The capture text has changed.',
    );
  }
  if (object['contextRevision'] != input.context.revision) {
    return reject(CaptureIssueCode.staleContext, 'The workspace has changed.');
  }

  final verified = interpretCapture(input);
  final clauses = _modelClauses(input, verified);
  final suggestions = object['suggestions']! as List;
  if (suggestions.length > clauses.length) return invalid();
  final seen = <int>{};
  final changed = <CaptureSpan, CaptureProposal>{};

  for (final raw in suggestions) {
    final choice = _stringMap(raw);
    if (choice == null ||
        !_keysMatch(choice, const {'clause', 'kind', 'category'})) {
      return invalid();
    }
    final index = choice['clause'];
    final kind = choice['kind'];
    final category = choice['category'];
    if (index is! int ||
        index < 0 ||
        index >= clauses.length ||
        !seen.add(index) ||
        kind is! String ||
        (category != null &&
            (category is! String ||
                !input.context.categories.containsKey(category)))) {
      return invalid();
    }
    final clause = clauses[index];
    if (!clause.choices.contains(kind)) return invalid();
    final stableCategory = category as String?;
    final explicit = clause.scope.category;
    if (explicit != null && explicit != stableCategory) return invalid();
    final original = clause.original;
    final draft = switch ((kind, original?.draft)) {
      ('category', CaptureTaskDraft(:final title, :final dueDate))
          when stableCategory != null =>
        CaptureTaskDraft(
          title: title,
          category: stableCategory,
          dueDate: dueDate,
        ),
      (
        'category',
        CaptureNoteDraft(:final title, :final body, :final noteToSelf),
      )
          when stableCategory != null =>
        CaptureNoteDraft(
          title: title,
          body: body,
          category: stableCategory,
          noteToSelf: noteToSelf,
        ),
      ('task', null) => CaptureTaskDraft(
        title: _title(clause.scope.body.text),
        category: stableCategory,
      ),
      ('note', null) => CaptureNoteDraft(
        title: _modelNoteTitle(clause.scope.body.text),
        body: clause.scope.body.text.trim(),
        category: stableCategory,
      ),
      _ => null,
    };
    if (draft == null || draft.title.isEmpty) return invalid();
    changed[clause.slice.span] = CaptureProposal(
      draft: draft,
      span: clause.slice.span,
      evidence: {
        ...?original?.evidence,
        if (original == null)
          'intent': CaptureEvidence(
            provenance: CaptureProvenance.model,
            span: clause.slice.span,
          ),
        if (stableCategory != null)
          'category': CaptureEvidence(
            provenance: explicit == null
                ? CaptureProvenance.model
                : CaptureProvenance.explicit,
            span: clause.scope.categorySpan,
          ),
      },
      requiresSelection: true,
    );
  }

  final proposals = [
    for (final proposal in verified.proposals)
      if (!changed.containsKey(proposal.span)) proposal,
    ...changed.values,
  ]..sort((first, second) => first.span.start.compareTo(second.span.start));
  return CaptureReview(
    input: input,
    proposals: proposals,
    issues: [
      for (final issue in verified.issues)
        if (issue.code != CaptureIssueCode.unrecognizedIntent ||
            !changed.containsKey(issue.span))
          issue,
    ],
  );
}

String _modelNoteTitle(String input) {
  final first = input.trim().split(RegExp(r'[\r\n]')).first;
  final runes = first.runes.take(81).toList();
  return runes.length <= 80
      ? first
      : '${String.fromCharCodes(runes.take(80))}…';
}
