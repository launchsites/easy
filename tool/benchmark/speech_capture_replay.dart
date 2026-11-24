import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easy/capture/capture_interpreter.dart';

const _focuses = {
  'work_deadline': 'gym',
  'coffee_range': 'work',
  'timed_appointment': 'work',
  'study_note': 'gym',
  'cardio': 'work',
  'strength': 'study',
  'personal_note': 'gym',
  'destructive_request': 'gym',
};

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: speech_capture_replay SPEECH_REPORT SOURCE_REVISION OUTPUT_JSON',
    );
    exitCode = 2;
    return;
  }
  final raw = File(args[0]).readAsBytesSync();
  final speech = _object(jsonDecode(utf8.decode(raw)));
  final clips = <String, Map<String, dynamic>>{
    for (final row in _rows(speech['clips'])) row['id'] as String: row,
  };
  final typed = <String, Map<String, Object?>>{};
  for (final clip in clips.values) {
    final input = _object(clip['case']);
    final caseId = input['id'] as String;
    typed.putIfAbsent(caseId, () => _parse(caseId, input['text'] as String));
  }
  final results = <Map<String, Object?>>[];
  for (final profile in _rows(speech['profiles'])) {
    if ((profile['cpu_affinity'] as List).length != 4) continue;
    final batch = _object(profile['warm_batch']);
    final cases = <Map<String, Object?>>[];
    for (final transcript in _rows(batch['transcriptions'])) {
      final clipId = transcript['clip_id'] as String;
      final clip = clips[clipId]!;
      final caseId = _object(clip['case'])['id'] as String;
      final parsed = _parse(caseId, transcript['transcript'] as String);
      final factsPassed = transcript['fact_pass'] == true;
      final typedHasDraft = (typed[caseId]!['proposals'] as List).isNotEmpty;
      cases.add({
        'clip': clipId,
        'voice': clip['voice'],
        'condition': clip['condition'],
        'speech_facts_passed': factsPassed,
        'parsed': parsed,
        'same_draft_as_reference':
            typedHasDraft && jsonEncode(typed[caseId]) == jsonEncode(parsed),
      });
    }
    final projections = cases.map((row) => _object(row['parsed']));
    results.add({
      'model': profile['model'],
      'clips': cases.length,
      'with_drafts': projections
          .where((row) => (row['proposals'] as List).isNotEmpty)
          .length,
      'with_ready_drafts': projections
          .where((row) => (row['ready'] as int) > 0)
          .length,
      'with_ready_drafts_and_missing_speech_facts': cases
          .where(
            (row) =>
                row['speech_facts_passed'] == false &&
                (_object(row['parsed'])['ready'] as int) > 0,
          )
          .length,
      'same_draft_as_reference': cases
          .where((row) => row['same_draft_as_reference'] == true)
          .length,
      'cases': cases,
    });
  }
  if (results.isEmpty) {
    throw const FormatException(
      'The report contains no four-CPU speech batches.',
    );
  }
  final report = {
    'tested_at_utc': DateTime.now().toUtc().toIso8601String(),
    'capture_source_revision': args[1],
    'speech_report_sha256': sha256.convert(raw).toString(),
    'context_anchor': '2026-11-24T15:00:00 Europe/London',
    'case_focuses': _focuses,
    'reference_text_projections': typed,
    'profiles': results,
  };
  File(args[2]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  for (final result in results) {
    stdout.writeln(
      '${result['model']} ${result['with_ready_drafts']}/${result['clips']} clips produced a ready draft.',
    );
  }
}

Map<String, Object?> _parse(String caseId, String text) {
  final review = interpretCapture(
    CaptureInput(
      id: 'synthetic-speech-$caseId',
      revision: 1,
      text: text,
      context: CaptureContext(
        anchor: DateTime(2026, 11, 24, 15),
        timezone: 'Europe/London',
        focusCategory: _focuses[caseId],
      ),
    ),
  );
  return {
    'proposals': review.proposals.map(_projection).toList(),
    'ready': review.proposals.where((proposal) => proposal.isReady).length,
    'issues': review.issues.map((issue) => issue.code.name).toList(),
  };
}

Map<String, Object?> _projection(CaptureProposal proposal) {
  final draft = proposal.draft;
  return {
    'kind': draft.kind.name,
    'title': _words(draft.title),
    'category': draft.category,
    'suggested_category': proposal.suggestedCategory,
    'missing': proposal.missingRequired,
    'issues': proposal.issues.map((issue) => issue.code.name).toList(),
    if (draft is CaptureTaskDraft) 'date': draft.dueDate?.toIso8601String(),
    if (draft is CaptureEventDraft) ...{
      'date': draft.date?.toIso8601String(),
      'start': draft.start?.toIso8601String(),
      'end': draft.end?.toIso8601String(),
      'start_clock': _clock(draft.startTime),
      'end_clock': _clock(draft.endTime),
      'duration_min': draft.duration?.inMinutes,
      'all_day': draft.allDay,
    },
    if (draft is CaptureNoteDraft) 'body': _words(draft.body),
    if (draft is CaptureWorkoutDraft) 'details': _words(draft.details),
  };
}

String? _clock(CaptureClock? clock) =>
    clock == null ? null : '${clock.hour}:${clock.minute}';

String _words(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

Map<String, dynamic> _object(Object? raw) => raw as Map<String, dynamic>;

Iterable<Map<String, dynamic>> _rows(Object? raw) =>
    (raw as List).cast<Map<String, dynamic>>();
