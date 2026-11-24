import 'dart:convert';
import 'dart:io';

import 'package:easy/search/search_index.dart';
import 'package:easy/search/search_models.dart';

void main() {
  const families = ['Client handoff', 'Studio review', 'Workshop notes'];
  final documents = [
    for (var entry = 0; entry < 100000; entry++)
      SearchDocument(
        key: SearchKey(SearchRecordKind.values[entry % 3], 'item-$entry'),
        title: 'Project ${entry % 41} ${families[entry % 3]}',
        body:
            'Review the prototype after the morning session. Check reference $entry before the deadline.',
        categoryId: entry.isEven ? 'work' : 'study',
        categoryName: entry.isEven ? 'Work' : 'Study',
        date: DateTime(2026, 11, 24 - entry % 365),
      ),
  ];
  final build = Stopwatch()..start();
  final index = SearchIndex.build(documents);
  build.stop();
  Map<String, Object> timed(String search, int expected) {
    final query = WorkspaceSearchQuery(search);
    if (index.search(query).length != expected) {
      throw StateError('Unexpected search results.');
    }
    final durations = <double>[];
    for (var sample = 0; sample < 51; sample++) {
      final watch = Stopwatch()..start();
      final matches = index.search(query);
      durations.add(watch.elapsedMicroseconds / 1000);
      if (matches.length != expected) {
        throw StateError('Unexpected search results.');
      }
    }
    durations.sort();
    return {
      'p50_ms': durations[25],
      'p95_ms': durations[48],
      'result_count': expected,
    };
  }

  stdout.writeln(
    jsonEncode({
      'documents': index.documentCount,
      'build_ms': build.elapsedMicroseconds / 1000,
      'query_repetitions': 51,
      'scoped': timed('body:"reference 96701" type:note', 1),
      'broad': timed('title:project category:work', 50),
      'missing': timed('qualifiedmissingrecord2026', 0),
      'rss_mib': (ProcessInfo.currentRss / (1 << 20)).round(),
    }),
  );
}
