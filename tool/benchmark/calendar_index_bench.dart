import 'dart:convert';
import 'dart:io';

import 'package:easy/calendar_event_index.dart';

typedef _Event = ({String id, DateTime start, DateTime end});
typedef _Query = List<_Event> Function(DateTime day);

DateTime _midnight(DateTime date, [int offset = 0]) =>
    DateTime(date.year, date.month, date.day + offset);

CalendarEventIndex<_Event> _index(List<_Event> events) => CalendarEventIndex(
  events,
  startOf: (event) => event.start,
  endOf: (event) => event.end,
);

List<_Event> _scan(List<_Event> events, DateTime start) {
  final end = _midnight(start, 1);
  return events.where((event) {
    if (!event.end.isAfter(event.start)) {
      return _midnight(event.start.toLocal()) == start;
    }
    return event.start.isBefore(end) && event.end.isAfter(start);
  }).toList()..sort((first, second) => first.start.compareTo(second.start));
}

Map<String, Object> _timings(List<int> samples) {
  final ordered = samples.toList()..sort();
  return {
    'samples_us': samples,
    'median_ms': ordered[(ordered.length - 1) ~/ 2] / 1000,
    'p95_ms': ordered[(ordered.length * .95).ceil() - 1] / 1000,
  };
}

Map<String, Object> _benchmark(
  _Query query,
  List<DateTime> days,
  int expected,
  int rounds,
) {
  final samples = <int>[];
  for (var repeat = 0; repeat < rounds; repeat++) {
    var matched = 0;
    final clock = Stopwatch()..start();
    for (final day in days) {
      matched += query(day).length;
    }
    clock.stop();
    if (matched != expected) throw StateError('Query result count changed.');
    samples.add(clock.elapsedMicroseconds);
  }
  return _timings(samples);
}

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Give the benchmark fixture shared_preferences.json.');
  }
  final outer = jsonDecode(File(args.single).readAsStringSync()) as Map;
  final data = jsonDecode(outer['easy.workspace.v1'] as String) as Map;
  final events = [
    for (final event in data['events'] as List)
      (
        id: event['id'] as String,
        start: DateTime.parse(event['start'] as String),
        end: DateTime.parse(event['end'] as String),
      ),
  ];
  final anchor = events.last.start;
  final days = [
    for (var index = 29; index >= 0; index--) _midnight(anchor, -index),
  ];
  const rounds = 31;
  final builds = <int>[];
  late CalendarEventIndex<_Event> index;
  for (var repeat = 0; repeat < rounds; repeat++) {
    final clock = Stopwatch()..start();
    index = _index(events);
    clock.stop();
    builds.add(clock.elapsedMicroseconds);
  }

  List<_Event> search(DateTime day) =>
      index.overlapping(day, _midnight(day, 1));
  int matched = 0;
  for (final day in days) {
    final expected = _scan(events, day);
    final actual = search(day);
    if (jsonEncode(expected.map((event) => event.id).toList()) !=
        jsonEncode(actual.map((event) => event.id).toList())) {
      throw StateError('Index changed the events on $day.');
    }
    matched += index.onDay(day).length;
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'fixture_events': events.length,
      'queries_per_sample': days.length,
      'accepted_samples': rounds,
      'matched_events_per_sample': matched,
      'build': _timings(builds),
      'full_scan': _benchmark(
        (day) => _scan(events, day),
        days,
        matched,
        rounds,
      ),
      'uncached_index': _benchmark(search, days, matched, rounds),
      'cached_index': _benchmark(index.onDay, days, matched, rounds),
      'process_peak_rss_bytes': ProcessInfo.maxRss,
    }),
  );
}
