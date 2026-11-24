import 'package:easy/capture/capture_interpreter.dart';
import 'package:easy/capture/task_category_hint.dart';
import 'package:easy/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'family transport from Gym keeps its original intention and missing time',
    () {
      final input = CaptureInput(
        id: 'family-capture',
        revision: 0,
        text: 'I need to take my sister to the game.',
        context: CaptureContext(
          anchor: DateTime(2026, 11, 24),
          focusCategory: 'gym',
        ),
      );
      final proposal = interpretCapture(input).proposals.single;
      expect(proposal.isReady, isTrue);
      final draft = proposal.draft as CaptureTaskDraft;
      expect(draft.category, 'personal');
      expect(draft.dueDate, isNull);
      expect(
        taskSchedulingHoldHint(draft.title)?.reason,
        TaskSchedulingHoldReason.appointmentTime,
      );
      expect(proposal.span.textFrom(input.text), input.text);
    },
  );

  test('self exercise and ordinary errands remain free of inferred holds', () {
    expect(taskSchedulingHoldHint('Go for a run'), isNull);
    expect(taskCategoryHint('Go for a run', ['gym', 'personal']), 'gym');
    expect(taskSchedulingHoldHint('Take a notebook to the studio'), isNull);
    expect(
      taskSchedulingHoldHint('Pick up my brother from hockey practice'),
      isNotNull,
    );
    expect(taskCategoryHint('Take my cousin to the game', ['gym']), isNull);
  });
}
