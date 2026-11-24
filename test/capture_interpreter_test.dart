import 'package:easy/capture/capture_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'mixed intents keep source evidence, Unicode, and explicit categories',
    () {
      final input = _input(
        'Work task: Send the café brief by tomorrow; '
        'event in Personal: Brunch tomorrow 10–11am; '
        'Note to self: “Réunion 🚀; call Ana\nNo new date.”; '
        'Workout: bench press 50 kg × 8; '
        'Meal: porridge with 🍌 #health',
      );
      final review = interpretCapture(input);
      expect(review.issues, isEmpty);
      expect(review.proposals.map((item) => item.draft.kind), [
        CaptureIntentKind.task,
        CaptureIntentKind.event,
        CaptureIntentKind.note,
        CaptureIntentKind.workout,
        CaptureIntentKind.meal,
      ]);
      expect(review.proposals.every((item) => item.isReady), true);

      final first = review.proposals.first;
      final task = first.draft as CaptureTaskDraft;
      expect(task.title, 'Send the café brief');
      expect(task.dueDate, DateTime(2026, 11, 24));
      expect(task.category, 'work');
      expect(first.suggestedCategory, isNull);
      expect(first.evidence['category']!.span!.textFrom(input.text), 'Work');

      final event = review.proposals[1].draft as CaptureEventDraft;
      expect(event.category, 'personal');
      expect(event.start, DateTime(2026, 11, 24, 10));
      expect(event.end, DateTime(2026, 11, 24, 11));

      final note = review.proposals[2].draft as CaptureNoteDraft;
      expect(note.title, 'Réunion 🚀; call Ana');
      expect(note.body, 'No new date.');
      expect(note.noteToSelf, true);
      expect(
        review.proposals[2].evidence['title']!.span!.textFrom(input.text),
        note.title,
      );
      final workout = review.proposals[3];
      expect(
        (workout.draft as CaptureWorkoutDraft).details,
        'bench press 50 kg × 8',
      );
      expect(workout.draft.category, isNull);
      expect(workout.suggestedCategory, 'gym');
      expect(
        workout.evidence['suggestedCategory']!.provenance,
        CaptureProvenance.context,
      );
      final meal = review.proposals[4].draft as CaptureMealDraft;
      expect(meal.description, 'porridge with 🍌');
      expect(meal.category, 'health');
      expect(
        review.proposals.every((item) => item.span.isWithin(input.text)),
        true,
      );
    },
  );

  test(
    'conjunctions separate explicit actions and preserve item lists and notes',
    () {
      final review = interpretCapture(
        _input(
          'I need to finish the mockup by tomorrow, and I need to buy bread and milk; '
          'Note: First line\nThis is still my note.\nTask: Read the brief',
        ),
      );
      expect(review.issues, isEmpty);
      expect(review.proposals.map((item) => item.draft.title), [
        'finish the mockup',
        'buy bread and milk',
        'First line',
        'Read the brief',
      ]);
      expect(
        (review.proposals[2].draft as CaptureNoteDraft).body,
        'This is still my note.',
      );
    },
  );

  test(
    'Unicode category IDs resolve by name and incompatible scopes abstain',
    () {
      final categories = {
        'études': 'Étude',
        'work': 'Work',
        'personal': 'Personal',
      };
      final review = interpretCapture(
        _input(
          'Task: Lire le café #ÉTUDE; Work: Note: Revision #personal; '
          'Task: Research #missing',
          context: _context(categories: categories),
        ),
      );
      expect(review.proposals.first.draft.category, 'études');
      expect(review.proposals.first.isReady, true);
      expect(review.proposals[1].draft.category, isNull);
      expect(
        review.proposals[1].issues.single.code,
        CaptureIssueCode.ambiguousCategory,
      );
      expect(review.proposals[2].suggestedCategory, isNull);
      expect(
        review.proposals[2].issues.single.code,
        CaptureIssueCode.unknownCategory,
      );
      expect(review.proposals[2].isReady, false);
    },
  );

  test('spoken note scopes preserve literal text across the active focus', () {
    const text =
        'Add a note for Étude. Chapter four uses the same lemma twice.; '
        'For the Personal note, Call Ana\nKeep her morning free.; '
        'Note for Étude, Send the reading list; '
        'For a Note note, File under notes; '
        'Gym: Add a note for Étude. Check the outline';
    final input = _input(
      text,
      context: _context(
        categories: {
          'study': 'Étude',
          'personal': 'Personal',
          'notebook': 'Note',
          'gym': 'Gym',
        },
      ),
    );
    final review = interpretCapture(input);
    expect(review.input.text, text);
    expect(review.issues, isEmpty);
    expect(
      review.proposals.map((item) => item.draft.kind),
      everyElement(CaptureIntentKind.note),
    );
    expect(review.proposals.map((item) => item.draft.title), [
      'Chapter four uses the same lemma twice.',
      'Call Ana',
      'Send the reading list',
      'File under notes',
      'Check the outline',
    ]);
    expect(review.proposals.map((item) => item.draft.category), [
      'study',
      'personal',
      'study',
      'notebook',
      null,
    ]);
    expect(
      review.proposals.map((item) => item.suggestedCategory),
      everyElement(isNull),
    );
    expect(
      (review.proposals[1].draft as CaptureNoteDraft).body,
      'Keep her morning free.',
    );
    expect(
      review.proposals[0].evidence['category']!.span!.textFrom(text),
      'Étude',
    );
    final repeatedLabel = review.proposals[3].evidence['category']!.span!;
    expect(repeatedLabel.start, text.indexOf('Note note'));
    expect(
      review.proposals.last.issues.single.code,
      CaptureIssueCode.ambiguousCategory,
    );
  });

  test('complete numeric dates resolve only when the order is unambiguous', () {
    final input = _input(
      'Task: Send the brief by 25/11/2026; '
      'Event: Design review on 11/25/2026 10–11am; '
      'Task: Submit on 2028/02/29; '
      'Task: Submit on 04/04/2028; '
      'Task: Submit by 03/04/2028; '
      'Task: Submit by 31/04/2028; '
      'Task: Submit by 25/11; '
      'Task: Submit by 03/04 and 2028-04-10',
    );
    final review = interpretCapture(input);
    expect(review.input.text, input.text);
    expect(review.issues, isEmpty);
    expect(review.proposals.take(4).every((item) => item.isReady), true);
    final task = review.proposals.first.draft as CaptureTaskDraft;
    expect(task.title, 'Send the brief');
    expect(task.dueDate, DateTime(2026, 11, 25));
    final event = review.proposals[1].draft as CaptureEventDraft;
    expect(event.start, DateTime(2026, 11, 25, 10));
    expect(event.end, DateTime(2026, 11, 25, 11));
    expect(
      (review.proposals[2].draft as CaptureTaskDraft).dueDate,
      DateTime(2028, 2, 29),
    );
    expect(
      (review.proposals[3].draft as CaptureTaskDraft).dueDate,
      DateTime(2028, 4, 4),
    );
    for (final item in review.proposals.skip(4)) {
      expect(item.isReady, false);
      expect((item.draft as CaptureTaskDraft).dueDate, isNull);
      expect(
        item.issues.map((issue) => issue.code),
        contains(CaptureIssueCode.invalidDate),
      );
    }
  });

  test('events preserve an explicit time without inventing a date or end', () {
    final review = interpretCapture(
      _input(
        'Event: Dinner 7–8pm; Event: Coffee tomorrow at 10am; Event: Picnic all day tomorrow',
      ),
    );
    final dinner = review.proposals.first;
    expect(dinner.missingRequired, ['date']);
    final draft = dinner.draft as CaptureEventDraft;
    expect(draft.date, isNull);
    expect(draft.start, isNull);
    expect(draft.startTime!.hour, 19);
    expect(draft.endTime!.hour, 20);
    expect(review.proposals[1].missingRequired, ['end']);
    final picnic = review.proposals[2].draft as CaptureEventDraft;
    expect(picnic.start, DateTime(2026, 11, 24));
    expect(picnic.end, DateTime(2026, 11, 25));
  });

  test('ambiguous dates, unsupported timezones, and negative or destructive requests stop', () {
    final dates = interpretCapture(
      _input(
        'Task: Send the invoice by 03/04; Event: Call Tuesday at 10am EST; '
        'Task: Submit by 2026-02-30',
      ),
    );
    expect(dates.proposals.every((item) => !item.isReady), true);
    expect(
      dates.proposals.first.issues.single.code,
      CaptureIssueCode.invalidDate,
    );
    expect((dates.proposals.first.draft as CaptureTaskDraft).dueDate, isNull);
    final timed = dates.proposals[1];
    expect(
      timed.issues.map((issue) => issue.code),
      contains(CaptureIssueCode.ambiguousTime),
    );
    expect((timed.draft as CaptureEventDraft).start, isNull);

    final blocked = interpretCapture(
      _input("I didn't go to the gym; Delete all tasks; Mark this done"),
    );
    expect(blocked.proposals, isEmpty);
    expect(blocked.issues.map((issue) => issue.code), [
      CaptureIssueCode.unsupportedCommand,
      CaptureIssueCode.unsupportedCommand,
      CaptureIssueCode.missingTarget,
    ]);
  });

  test('contextual completion requires one live exact target and stays revision-bound', () {
    const records = [
      CaptureRecordRef(
        id: 'work-1',
        kind: CaptureIntentKind.task,
        title: 'Café summary',
        category: 'work',
        revision: 4,
      ),
      CaptureRecordRef(
        id: 'personal-2',
        kind: CaptureIntentKind.task,
        title: 'Café summary',
        category: 'personal',
        revision: 5,
      ),
    ];
    final named = interpretCapture(
      _input('Mark “Café summary” done', context: _context(records: records)),
    );
    expect(named.proposals, isEmpty);
    expect(named.issues.single.code, CaptureIssueCode.ambiguousTarget);

    final input = _input(
      'Mark this done',
      context: _context(records: records, selected: 'personal-2'),
    );
    final review = interpretCapture(input);
    final target = review.proposals.single.draft as CaptureCompleteTaskDraft;
    expect(target.targetId, 'personal-2');
    expect(target.expectedRevision, 5);
    expect(target.category, isNull);
    expect(review.isCurrentFor(input), true);
    expect(
      review.isCurrentFor(
        _input(
          input.text,
          context: _context(records: records, selected: 'work-1'),
        ),
      ),
      false,
    );
    final staleContext = _context(
      selected: 'personal-2',
      records: [
        records.first,
        const CaptureRecordRef(
          id: 'personal-2',
          kind: CaptureIntentKind.task,
          title: 'Café summary',
          revision: 6,
          completed: true,
        ),
      ],
    );
    expect(
      review.isCurrentFor(_input(input.text, context: staleContext)),
      false,
    );
    final complete = interpretCapture(
      _input(input.text, context: staleContext),
    );
    expect(complete.proposals, isEmpty);
    expect(complete.issues.single.code, CaptureIssueCode.unavailableTarget);
  });

  test(
    'model output must match exact fields, whole spans, and current revisions',
    () {
      final input = _input('Work: Task: 🚀 Send the brief by tomorrow');
      Map<String, Object?> envelope() => {
        'version': 1,
        'captureId': input.id,
        'sourceRevision': input.revision,
        'contextRevision': input.context.revision,
        'proposals': [
          {
            'kind': 'task',
            'span': {'start': 0, 'end': input.text.length},
            'fields': {
              'title': '🚀 Send the brief',
              'category': 'work',
              'dueDate': '2026-11-24',
            },
          },
        ],
      };
      final accepted = validateModelCapture(input, envelope());
      expect(accepted.proposals.single.isReady, true);
      expect(
        accepted.proposals.single.evidence['category']!.span!.textFrom(
          input.text,
        ),
        'Work',
      );

      final staleSource = envelope()..['sourceRevision'] = input.revision - 1;
      final staleContext = envelope()
        ..['contextRevision'] = input.context.revision + 1;
      expect(
        validateModelCapture(input, staleSource).issues.single.code,
        CaptureIssueCode.staleSource,
      );
      expect(
        validateModelCapture(input, staleContext).issues.single.code,
        CaptureIssueCode.staleContext,
      );
      for (final invalid in [
        envelope()..['deleteAll'] = true,
        envelope()..['proposals'] = [],
        envelope()..['version'] = 1.0,
        envelope()
          ..['proposals'] = [
            {
              'kind': 'task',
              'span': {
                'start': input.text.indexOf('🚀') + 1,
                'end': input.text.length,
              },
              'fields': {
                'title': 'Send the brief',
                'category': 'gym',
                'dueDate': '2026-11-24',
              },
            },
          ],
        envelope()
          ..['proposals'] = [
            {
              'kind': 'task',
              'span': {'start': 0, 'end': input.text.length},
              'fields': {
                'title': '🚀 Send the brief',
                'category': 'work',
                'dueDate': '2026-11-25',
              },
            },
          ],
        '{invalid',
      ]) {
        final rejected = validateModelCapture(input, invalid);
        expect(rejected.input.text, input.text);
        expect(rejected.proposals, isEmpty);
        expect(
          rejected.issues.single.code,
          CaptureIssueCode.invalidModelOutput,
        );
      }
    },
  );

  test('model cannot inject a target or turn focus into a category', () {
    final input = _input('Task: Send the brief');
    final model = {
      'version': 1,
      'captureId': input.id,
      'sourceRevision': input.revision,
      'contextRevision': input.context.revision,
      'proposals': [
        {
          'kind': 'task',
          'span': {'start': 0, 'end': input.text.length},
          'fields': {
            'title': 'Send the brief',
            'category': 'gym',
            'targetId': 'forged',
          },
        },
      ],
    };
    expect(validateModelCapture(input, model).proposals, isEmpty);
    expect(interpretCapture(input).proposals.single.draft.category, isNull);
  });
}

CaptureContext _context({
  Map<String, String>? categories,
  List<CaptureRecordRef> records = const [],
  String? selected,
}) => CaptureContext(
  anchor: DateTime.utc(2026, 11, 23, 23, 58),
  timezone: 'Europe/London',
  revision: 7,
  focusCategory: 'gym',
  categories: categories,
  records: records,
  selectedRecordId: selected,
);

CaptureInput _input(String text, {CaptureContext? context}) => CaptureInput(
  id: 'test-capture',
  revision: 3,
  text: text,
  context: context ?? _context(),
);
