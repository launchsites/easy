import 'dart:convert';

import 'package:easy/capture/capture_archive.dart';
import 'package:easy/gym_session.dart';
import 'package:easy/workspace_data.dart';
import 'package:flutter_test/flutter_test.dart';

final _firstFold = DateTime.parse('2026-11-01T01:30:00.123456-04:00');
final _secondFold = DateTime.parse('2026-11-01T01:30:00.123456-05:00');

void main() {
  test(
    'stored workout instants distinguish both repeated wall-clock times',
    () {
      for (final instant in [_firstFold, _secondFold]) {
        final local = instant.toLocal();
        final log = GymLogEntry(id: 'entry', title: 'Stretch', loggedAt: local);
        final session = GymSession.loggedCapture(at: local, entry: log);
        final encoded = session.encode();
        final fields = jsonDecode(encoded) as Map<String, dynamic>;
        expect(fields['startedAt'], instant.toIso8601String());
        expect(fields['finishedAt'], instant.toIso8601String());
        expect(
          (fields['entries'] as List).single['loggedAt'],
          instant.toIso8601String(),
        );

        final saved = GymSession.decode(encoded);
        expect(saved.startedAt, local);
        expect(saved.startedAt.isUtc, isFalse);
        expect(saved.finishedAt, instant);
        expect(saved.entries.single.loggedAt, instant);
        expect(saved.encode(), encoded);
      }
      final workout = GymSession.decode(
        jsonEncode({
          'planned': false,
          'startedAt': _firstFold.toIso8601String(),
          'finishedAt': _secondFold.toIso8601String(),
          'entries': [],
        }),
      );
      expect(workout.finishedAt!.difference(workout.startedAt).inHours, 1);
    },
  );

  test(
    'workspace reload retains capture order and uses local review anchors',
    () {
      final captures = [
        for (final (index, instant) in [_firstFold, _secondFold].indexed)
          CaptureArchiveEntry(
            id: 'note-$index',
            text: 'Call tomorrow',
            capturedAt: instant.toLocal(),
          ),
      ];
      final encoded = WorkspaceData(
        events: [],
        tasks: [],
        notes: [],
        captures: captures,
      ).encode();
      final fields = jsonDecode(encoded) as Map<String, dynamic>;
      expect(
        (fields['captures'] as List).map((record) => record['capturedAt']),
        [_firstFold.toIso8601String(), _secondFold.toIso8601String()],
      );
      final review = WorkspaceData.decode(encoded).captures;
      expect(review[0].capturedAt, _firstFold.toLocal());
      expect(review[1].capturedAt, _secondFold.toLocal());
      expect(review.every((source) => !source.capturedAt.isUtc), isTrue);
      final updated = review[1].revised('Call later tomorrow').markApplied();
      expect(updated.toJson()['capturedAt'], _secondFold.toIso8601String());
      expect(updated.capturedAt.difference(review[0].capturedAt).inHours, 1);
    },
  );

  test('legacy wall-clock strings stay readable with their local meaning', () {
    final start = DateTime(2026, 1, 16, 9, 10, 30, 123, 456);
    final finish = start.add(const Duration(minutes: 45));
    final workout = GymSession.decode(
      jsonEncode({
        'planned': false,
        'startedAt': start.toIso8601String(),
        'finishedAt': finish.toIso8601String(),
        'entries': [
          {
            'id': 'entry',
            'title': 'Stretch',
            'loggedAt': start.toIso8601String(),
          },
        ],
      }),
    );
    expect(workout.startedAt, start);
    expect(workout.finishedAt, finish);
    expect(workout.entries.single.loggedAt, start);
    final rewritten = GymSession.decode(workout.encode());
    expect(rewritten.startedAt.isAtSameMomentAs(start), isTrue);
    expect(rewritten.finishedAt?.isAtSameMomentAs(finish), isTrue);

    final capture = CaptureArchiveEntry.fromJson({
      'id': 'old-note',
      'text': 'Legacy local capture',
      'capturedAt': start.toIso8601String(),
    });
    expect(capture.capturedAt, start);
    expect(capture.toJson()['capturedAt'], start.toUtc().toIso8601String());

    final rest = GymSession.start(now: start)
        .startRest(const Duration(minutes: 2), now: start);
    final restoredRest = GymSession.decode(rest.encode());
    expect(restoredRest.finished, isFalse);
    expect(
      restoredRest.restEndsAt,
      start.add(const Duration(minutes: 2)).toUtc(),
    );
  });
}
