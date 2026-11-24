import 'package:easy/capture/capture_interpreter.dart';
import 'package:easy/capture/task_category_hint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const choices = {'health', 'gym', 'work', 'study', 'personal'};

  test('fast category hints match clear task intent across focus modes', () {
    expect(taskCategoryHint('Go for a run before lunch', choices), 'gym');
    expect(taskCategoryHint('Find website leads', choices), 'work');
    expect(taskCategoryHint('Make social media plan', choices), 'work');
    expect(taskCategoryHint('Biology homework', choices), 'study');
    expect(taskCategoryHint('Run website tests', choices), isNull);
    expect(taskCategoryHint('Go for a run', {'work'}), isNull);
  });

  test('review keeps explicit categories and grounds workout speech', () {
    final review = interpretCapture(
      CaptureInput(
        id: 'typed',
        revision: 1,
        text: 'Go for a run; Work: task: Go for a run; After the treadmill I stretched; After that I did bench press 60kg x8,8,6; After that I did not do bench press',
        context: CaptureContext(
          anchor: DateTime(2026, 11, 24),
          focusCategory: 'study',
        ),
      ),
    );
    expect(review.proposals.map((proposal) => proposal.draft.kind), [
      CaptureIntentKind.task,
      CaptureIntentKind.task,
      CaptureIntentKind.workout,
      CaptureIntentKind.workout,
    ]);
    expect(review.proposals[0].draft.category, 'gym');
    expect(
      review.proposals[0].evidence['category']?.provenance,
      CaptureProvenance.derived,
    );
    expect(review.proposals[1].draft.category, 'work');
    expect(
      review.proposals[1].evidence['category']?.provenance,
      CaptureProvenance.explicit,
    );
    expect(review.proposals[3].draft.title, contains('60kg x8,8,6'));
    expect(review.issues, isNotEmpty);
  });
}
