import 'dart:convert';
import 'dart:io';

import 'package:easy/ai/duration_evidence_estimate.dart';

import 'provider_estimate_bench.dart' show durationEvidenceForCase;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/benchmark/history_duration_replay.dart '
      'CASES_JSON OUTPUT_JSON SOURCE_REVISION',
    );
    exitCode = 2;
    return;
  }
  final raw = jsonDecode(await File(args[0]).readAsString()) as List;
  final cases = raw.cast<Map<String, Object?>>();
  final anchor = DateTime.utc(2026, 11, 24, 12);
  final decisions = <Map<String, Object?>>[];
  var evidenceCount = 0;
  var medianMatches = 0;
  var proposalCount = 0;
  var proposalMatches = 0;
  for (final item in cases) {
    final history = durationEvidenceForCase(item, anchor);
    final proposal = estimateFromConfirmedHistory(history);
    final actual = Duration(minutes: item['actual'] as int);
    final tolerance = Duration(minutes: item['tolerance'] as int);
    bool matches(Duration duration) => (duration - actual).abs() <= tolerance;

    if (history != null) {
      evidenceCount++;
      if (matches(history.median)) medianMatches++;
    }
    if (proposal != null) {
      proposalCount++;
      if (matches(proposal.duration)) proposalMatches++;
    }
    decisions.add({
      'id': item['id'],
      'holdout_minutes': actual.inMinutes,
      'tolerance_minutes': tolerance.inMinutes,
      'history': history?.optionalMetadata(),
      'raw_median_seconds': history?.median.inSeconds,
      'proposal_seconds': proposal?.duration.inSeconds,
      'proposal_within_tolerance':
          proposal != null && matches(proposal.duration),
    });
  }
  final report = {
    'source_revision': args[2],
    'fixture_cases': cases.length,
    'cases_with_history': evidenceCount,
    'raw_median_within_tolerance': medianMatches,
    'proposals': proposalCount,
    'proposals_within_tolerance': proposalMatches,
    'network_requests': 0,
    'decisions': decisions,
  };
  await File(args[1])
      .writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
}
