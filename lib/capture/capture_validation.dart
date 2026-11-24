part of 'capture_interpreter.dart';

/// Checks a model response against this capture's deterministic evidence.
///
/// Version 1 accepts an object (or JSON for that object) with `version`,
/// `captureId`, `sourceRevision`, `contextRevision`, and `proposals`. Each
/// proposal has `kind`, `span: {start, end}`, and `fields`. Dates are local
/// ISO dates, timestamps are local ISO timestamps, and durations are minutes.
/// The whole batch is withheld if a field, source span, or revision differs.
CaptureReview validateModelCapture(CaptureInput input, Object? response) {
  CaptureReview rejected(CaptureIssueCode code, String message) =>
      CaptureReview(input: input, issues: [CaptureIssue(code, message)]);

  final object = _modelObject(response);
  if (object?['version'] == 2 && object!['version'] is int) {
    return _validateModelEnrichment(input, object);
  }
  if (object == null ||
      !_keysMatch(object, const {
        'version',
        'captureId',
        'sourceRevision',
        'contextRevision',
        'proposals',
      }) ||
      object['version'] is! int ||
      object['version'] != 1 ||
      object['captureId'] is! String ||
      object['sourceRevision'] is! int ||
      object['contextRevision'] is! int ||
      object['proposals'] is! List) {
    return rejected(
      CaptureIssueCode.invalidModelOutput,
      'Review the original capture text.',
    );
  }
  if (object['captureId'] != input.id ||
      object['sourceRevision'] != input.revision) {
    return rejected(
      CaptureIssueCode.staleSource,
      'The capture text has changed.',
    );
  }
  if (object['contextRevision'] != input.context.revision) {
    return rejected(
      CaptureIssueCode.staleContext,
      'The workspace has changed.',
    );
  }

  final verified = interpretCapture(input);
  final proposed = object['proposals']! as List;
  if (proposed.length != verified.proposals.length) {
    return rejected(
      CaptureIssueCode.invalidModelOutput,
      'Review which items to capture.',
    );
  }
  for (var index = 0; index < proposed.length; index++) {
    if (!_matchesProposal(
      input.text,
      proposed[index],
      verified.proposals[index],
    )) {
      return rejected(
        CaptureIssueCode.invalidModelOutput,
        'Review the extracted values against the capture text.',
      );
    }
  }
  return verified;
}

Map<String, Object?>? _modelObject(Object? value) {
  if (value is String) {
    if (value.length > 128 * 1024) return null;
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return _stringMap(value);
}

Map<String, Object?>? _stringMap(Object? value) =>
    value is Map<String, Object?> ? value : null;

bool _keysMatch(Map<String, Object?> input, Set<String> expected) =>
    input.length == expected.length && input.keys.every(expected.contains);

bool _matchesProposal(String source, Object? raw, CaptureProposal verified) {
  final proposal = _stringMap(raw);
  if (proposal == null ||
      !_keysMatch(proposal, const {'kind', 'span', 'fields'}) ||
      proposal['kind'] != verified.draft.kind.name) {
    return false;
  }
  final offsets = _stringMap(proposal['span']);
  if (offsets == null ||
      !_keysMatch(offsets, const {'start', 'end'}) ||
      offsets['start'] is! int ||
      offsets['end'] is! int) {
    return false;
  }
  final span = CaptureSpan(offsets['start']! as int, offsets['end']! as int);
  if (!span.isWithin(source) || span != verified.span) return false;

  final fields = _stringMap(proposal['fields']);
  if (fields == null) return false;
  final expected = _modelFields(verified.draft);
  if (!_keysMatch(fields, expected.keys.toSet())) return false;
  for (final entry in expected.entries) {
    final value = fields[entry.key];
    if (value.runtimeType != entry.value.runtimeType || value != entry.value) {
      return false;
    }
  }
  return true;
}

Map<String, Object> _modelFields(CaptureDraft draft) => {
  'title': draft.title,
  'category': ?draft.category,
  ...switch (draft) {
    CaptureTaskDraft(:final dueDate) => {
      if (dueDate != null) 'dueDate': _isoDate(dueDate),
    },
    CaptureEventDraft(
      :final date,
      :final start,
      :final end,
      :final startTime,
      :final endTime,
      :final duration,
      :final allDay,
      :final location,
    ) =>
      {
        'allDay': allDay,
        if (date != null) 'date': _isoDate(date),
        if (start != null) 'start': start.toIso8601String(),
        if (end != null) 'end': end.toIso8601String(),
        if (startTime != null && start == null)
          'startTime': _isoClock(startTime),
        if (endTime != null && end == null) 'endTime': _isoClock(endTime),
        if (duration != null) 'durationMinutes': duration.inMinutes,
        'location': ?location,
      },
    CaptureNoteDraft(:final body, :final noteToSelf) => {
      'body': body,
      'noteToSelf': noteToSelf,
    },
    CaptureWorkoutDraft(:final details) => {'details': details},
    CaptureMealDraft(:final description) => {'description': description},
    CaptureCompleteTaskDraft(:final targetId, :final expectedRevision) => {
      'targetId': targetId,
      'expectedRevision': expectedRevision,
    },
  },
};

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String _isoClock(CaptureClock clock) =>
    '${clock.hour.toString().padLeft(2, '0')}:'
    '${clock.minute.toString().padLeft(2, '0')}';
