import 'dart:convert';
import 'dart:io';

import 'package:easy/calendar_sources/ics_calendar.dart';
import 'package:easy/calendar_sources/ics_zone_support.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    final name = row['name'] as String;
    final zone = ianaCalendarZone(name);
    if (zone == null) {
      stdout.writeln('null');
      continue;
    }
    if (row['export'] == true) {
      final calendar = IcsCalendar(
        events: [
          IcsEvent(
            uid: 'zone-probe',
            start: IcsDateTime.zoned(DateTime.utc(2037, 7, 1, 12), name),
          ),
        ],
      );
      stdout.writeln(
        jsonEncode(calendar.encode(timestamp: DateTime.utc(2026))),
      );
      continue;
    }
    final samples = (row['samples'] as List<dynamic>).cast<int>();
    stdout.writeln(
      jsonEncode([
        for (final seconds in samples)
          zone.offsetAt(
            DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
          ),
      ]),
    );
  }
}
