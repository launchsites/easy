import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = CaptureInput(
    id: 'source',
    revision: 2,
    text: 'Write launch notes; Study: task: Read chapter 8; Garden bench paint ideas; Coffee tomorrow at 10:00; Delete all notes',
    context: CaptureContext(
      anchor: DateTime(2026, 11, 24),
      revision: 4,
      focusCategory: 'gym',
      categories: {'work': 'Work', 'study': 'Study', 'personal': 'Personal'},
    ),
  );
  Map<String, Object?> reply(List<Object?> suggestions) => {
    'version': 2,
    'captureId': 'source',
    'sourceRevision': 2,
    'contextRevision': 4,
    'suggestions': suggestions,
  };

  test(
    'model selects bounded literal suggestions without rewriting a record',
    () {
      final choices = captureEnrichmentChoices(source);
      expect(choices.map((choice) => choice['clause']), [0, 2]);
      final review = validateModelCapture(
        source,
        reply([
          {'clause': 0, 'kind': 'category', 'category': 'work'},
          {'clause': 2, 'kind': 'note', 'category': 'personal'},
        ]),
      );
      expect(review.proposals.map((proposal) => proposal.draft.title), [
        'Write launch notes',
        'Read chapter 8',
        'Garden bench paint ideas',
        'Coffee',
      ]);
      final first = review.proposals.first;
      expect(first.draft.category, 'work');
      expect(first.requiresSelection, isTrue);
      expect(first.evidence['category']?.provenance, CaptureProvenance.model);
      expect(review.proposals[1].draft.category, 'study');
      expect(review.proposals[1].requiresSelection, isFalse);
      expect(review.proposals[2].requiresSelection, isTrue);
      expect(
        (review.proposals[2].draft as CaptureNoteDraft).body,
        'Garden bench paint ideas',
      );
      expect(review.proposals.last.missingRequired, contains('end'));
    },
  );

  test(
    'unsupported suggestions, duplicates and stale context withhold the batch',
    () {
      const accepted = {'clause': 0, 'kind': 'category', 'category': 'work'};
      for (final suggestion in [
        {'clause': 1, 'kind': 'category', 'category': 'work'},
        {'clause': 3, 'kind': 'note', 'category': null},
        {'clause': 4, 'kind': 'task', 'category': 'work'},
        {'clause': 0, 'kind': 'category', 'category': 'unknown'},
        {'clause': 2, 'kind': 'task', 'category': null, 'dueDate': 'tomorrow'},
        {'clause': 2.0, 'kind': 'note', 'category': null},
      ]) {
        final reviewed = validateModelCapture(
          source,
          reply([accepted, suggestion]),
        );
        expect(reviewed.proposals, isEmpty, reason: suggestion.toString());
        expect(
          reviewed.issues.single.code,
          CaptureIssueCode.invalidModelOutput,
        );
      }
      expect(
        validateModelCapture(
          source,
          reply([accepted, accepted]),
        ).issues.single.code,
        CaptureIssueCode.invalidModelOutput,
      );
      final stale = reply([accepted])..['contextRevision'] = 3;
      expect(
        validateModelCapture(source, stale).issues.single.code,
        CaptureIssueCode.staleContext,
      );
    },
  );

  test('an empty model response leaves deterministic proposals intact', () {
    final reviewed = validateModelCapture(source, reply([]));
    expect(
      reviewed.proposals.map((proposal) => proposal.draft.title),
      interpretCapture(source).proposals
          .map((proposal) => proposal.draft.title),
    );
  });
}
