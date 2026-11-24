import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy/capture/capture_interpreter.dart';

const _seed = 261124;
const _rounds = 10000;
const _mutations = [
  'wrongCapture',
  'staleSource',
  'staleContext',
  'unknownVersion',
  'mixedProposalBatch',
  'wrongKind',
  'wrongSpanStart',
  'wrongSpanEnd',
  'wrongTitle',
  'wrongCategory',
  'inventedDeadline',
  'unknownField',
  'wrongFieldType',
];

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/benchmark/capture_validation_fuzz.dart OUTPUT_JSON',
    );
    exitCode = 2;
    return;
  }
  final rng = Random(_seed);
  final sampled = {for (final mutation in _mutations) mutation: 0};
  final started = Stopwatch()..start();
  for (var index = 0; index < _rounds; index++) {
    final payload = _fixture(rng, index);
    final before = validateModelCapture(
      payload.input,
      jsonEncode(payload.wire),
    );
    if (before.issues.isNotEmpty || before.proposals.length != 2) {
      throw StateError('Control rejected at seed $_seed, iteration $index.');
    }

    final mutation = _mutations[rng.nextInt(_mutations.length)];
    sampled[mutation] = sampled[mutation]! + 1;
    _mutate(payload.wire, mutation);
    final after = validateModelCapture(payload.input, jsonEncode(payload.wire));
    if (after.proposals.isNotEmpty || after.issues.length != 1) {
      throw StateError('$mutation accepted at seed $_seed, iteration $index.');
    }
  }
  started.stop();
  final evidence = {
    'run_at_utc': DateTime.now().toUtc().toIso8601String(),
    'seed': _seed,
    'rounds': _rounds,
    'valid_batches': _rounds,
    'withheld_mutated_batches': _rounds,
    'mutation_counts': sampled,
    'wall_ms': started.elapsedMicroseconds / 1000,
  };
  File(args.single).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
  );
  stdout.writeln('$_rounds valid controls and $_rounds rejected mutations.');
}

({CaptureInput input, Map<String, Object?> wire}) _fixture(
  Random rng,
  int index,
) {
  const categories = ['work', 'study', 'personal', 'gym', 'health'];
  final category = categories[rng.nextInt(categories.length)];
  final detail = rng.nextBool() ? 'draft 📄 $index' : 'draft $index';
  final input = CaptureInput(
    id: 'validation-$index',
    revision: rng.nextInt(191) + 1,
    text:
        '$category: task: Send the $detail tomorrow; work: note: Ready for review',
    context: CaptureContext(
      anchor: DateTime(2026, 11, 24, 11),
      revision: rng.nextInt(1000) + 1,
      focusCategory: categories[rng.nextInt(categories.length)],
    ),
  );
  final verified = interpretCapture(input);
  final wire = <String, Object?>{
    'version': 1,
    'captureId': input.id,
    'sourceRevision': input.revision,
    'contextRevision': input.context.revision,
    'proposals': [
      for (final proposal in verified.proposals)
        <String, Object?>{
          'kind': proposal.draft.kind.name,
          'span': <String, Object?>{
            'start': proposal.span.start,
            'end': proposal.span.end,
          },
          'fields': <String, Object?>{
            'title': proposal.draft.title,
            'category': proposal.draft.category,
            if (proposal.draft is CaptureTaskDraft) 'dueDate': '2026-11-25',
            if (proposal.draft case final CaptureNoteDraft note) ...{
              'body': note.body,
              'noteToSelf': note.noteToSelf,
            },
          },
        },
    ],
  };
  return (input: input, wire: wire);
}

void _mutate(Map<String, Object?> wire, String mutation) {
  final proposals = (wire['proposals']! as List).cast<Map<String, Object?>>();
  final task = proposals.first;
  final span = task['span']! as Map<String, Object?>;
  final fields = task['fields']! as Map<String, Object?>;
  switch (mutation) {
    case 'wrongCapture':
      wire['captureId'] = 'different-source';
    case 'staleSource':
      wire['sourceRevision'] = (wire['sourceRevision']! as int) - 1;
    case 'staleContext':
      wire['contextRevision'] = (wire['contextRevision']! as int) - 1;
    case 'unknownVersion':
      wire['version'] = 2;
    case 'mixedProposalBatch':
      proposals.removeLast();
    case 'wrongKind':
      task['kind'] = 'event';
    case 'wrongSpanStart':
      span['start'] = (span['start']! as int) + 1;
    case 'wrongSpanEnd':
      span['end'] = (span['end']! as int) - 1;
    case 'wrongTitle':
      fields['title'] = 'Send a different draft';
    case 'wrongCategory':
      fields['category'] = fields['category'] == 'health' ? 'work' : 'health';
    case 'inventedDeadline':
      fields['dueDate'] = '2026-11-28';
    case 'unknownField':
      fields['additional'] = true;
    case 'wrongFieldType':
      fields['title'] = 9;
  }
}
