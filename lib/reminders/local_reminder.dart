import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:timezone/data/latest_all.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import '../tasks/recurring_task.dart';

const localReminderIdPrefix = 'easy-local-reminder-';
const localReminderHorizonDays = 30;
const localReminderPendingLimit = 48;

enum ReminderTargetKind { task, event, plannedBlock }

class ReminderTarget {
  ReminderTarget({
    required this.kind,
    required this.recordId,
    this.occurrenceId,
  }) {
    if (recordId.trim().isEmpty || occurrenceId?.trim().isEmpty == true) {
      throw ArgumentError('Choose an existing reminder target.');
    }
  }

  factory ReminderTarget.fromJson(Map<String, Object?> json) => ReminderTarget(
    kind: ReminderTargetKind.values.byName(json['kind'] as String),
    recordId: json['recordId'] as String,
    occurrenceId: json['occurrenceId'] as String?,
  );

  final ReminderTargetKind kind;
  final String recordId;
  final String? occurrenceId;

  late final String notificationId =
      '$localReminderIdPrefix${sha256.convert(utf8.encode(jsonEncode([kind.name, recordId, occurrenceId])))}';

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'recordId': recordId,
    if (occurrenceId != null) 'occurrenceId': occurrenceId,
  };
}

class LocalReminder {
  LocalReminder({required this.target, required DateTime at, this.recordTitle})
    : at = _nextWholeSecond(at);

  final ReminderTarget target;
  final DateTime at;
  final String? recordTitle;

  String get id => target.notificationId;

  LocalReminderRequest request({
    required bool showRecordTitle,
    String appName = 'Easy',
  }) {
    final title = recordTitle?.trim();
    return LocalReminderRequest(
      id: id,
      at: at,
      title: showRecordTitle && title != null && title.isNotEmpty
          ? String.fromCharCodes(title.runes.take(160))
          : String.fromCharCodes(appName.runes.take(160)),
      body: switch (target.kind) {
        ReminderTargetKind.task => 'Task reminder',
        ReminderTargetKind.event => 'Calendar reminder',
        ReminderTargetKind.plannedBlock => 'Planned block reminder',
      },
    );
  }
}

class LocalReminderRequest {
  LocalReminderRequest({
    required this.id,
    required DateTime at,
    required this.title,
    required this.body,
    this.armed = true,
  }) : at = _nextWholeSecond(at).toUtc() {
    if (!isLocalReminderId(id) || title.trim().isEmpty || body.trim().isEmpty) {
      throw ArgumentError('Invalid local reminder request.');
    }
  }

  factory LocalReminderRequest.fromJson(Map<String, Object?> json) =>
      LocalReminderRequest(
        id: json['id'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(
          json['atMilliseconds'] as int,
          isUtc: true,
        ),
        title: json['title'] as String,
        body: json['body'] as String,
        armed: json['armed'] as bool? ?? true,
      );

  final String id;
  final DateTime at;
  final String title;
  final String body;
  final bool armed;

  Map<String, Object?> toJson() => {
    'id': id,
    'atMilliseconds': at.millisecondsSinceEpoch,
    'title': title,
    'body': body,
  };

  @override
  bool operator ==(Object other) =>
      other is LocalReminderRequest &&
      other.id == id &&
      other.at == at &&
      other.title == title &&
      other.body == body &&
      other.armed == armed;

  @override
  int get hashCode => Object.hash(id, at, title, body, armed);
}

final _reminderId = RegExp('^$localReminderIdPrefix[a-f0-9]{64}\$');

bool isLocalReminderId(String value) => _reminderId.hasMatch(value);

/// An explicit user choice on a single task, event or planned block.
class RecordReminderPreference {
  RecordReminderPreference.absolute({
    required this.target,
    required DateTime at,
  }) : at = at.toUtc(),
       minutesBeforeStart = null;

  RecordReminderPreference.relative({
    required this.target,
    required int minutesBeforeStart,
  }) : minutesBeforeStart = minutesBeforeStart,
       at = null {
    if (minutesBeforeStart < 0 || minutesBeforeStart > 7 * 24 * 60) {
      throw ArgumentError('Choose a whole number of minutes within one week.');
    }
  }

  factory RecordReminderPreference.fromJson(Map<String, Object?> json) {
    final target = ReminderTarget.fromJson(
      json['target'] as Map<String, Object?>,
    );
    final at = json['at'] as String?;
    final lead = json['minutesBeforeStart'] as int?;
    if ((at == null) == (lead == null)) {
      throw const FormatException('Choose one reminder time.');
    }
    if (at == null) {
      return RecordReminderPreference.relative(
        target: target,
        minutesBeforeStart: lead!,
      );
    }
    final time = DateTime.tryParse(at);
    if (time == null || !time.isUtc || time.toIso8601String() != at) {
      throw const FormatException('Invalid reminder timestamp.');
    }
    return RecordReminderPreference.absolute(target: target, at: time);
  }

  final ReminderTarget target;
  final DateTime? at;
  final int? minutesBeforeStart;

  Map<String, Object?> toJson() => {
    'target': target.toJson(),
    if (at != null) 'at': at!.toIso8601String(),
    if (minutesBeforeStart != null) 'minutesBeforeStart': minutesBeforeStart,
  };

  LocalReminder? resolve({DateTime? start, String? title, bool active = true}) {
    if (!active) return null;
    final time = at ?? start?.subtract(Duration(minutes: minutesBeforeStart!));
    return time == null
        ? null
        : LocalReminder(target: target, at: time, recordTitle: title);
  }
}

class LocalReminderSettings {
  const LocalReminderSettings({
    this.enabled = false,
    this.showRecordTitles = false,
  });

  factory LocalReminderSettings.fromJson(Map<String, Object?> json) =>
      LocalReminderSettings(
        enabled: json['enabled'] as bool? ?? false,
        showRecordTitles: json['showRecordTitles'] as bool? ?? false,
      );

  final bool enabled;
  final bool showRecordTitles;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'showRecordTitles': showRecordTitles,
  };
}

List<LocalReminder> remindersForRecurringTasks(
  Iterable<RecurringTaskSeries> series, {
  required DateTime now,
  Duration horizon = const Duration(days: localReminderHorizonDays),
}) {
  _checkHorizon(horizon);
  final nowUtc = now.toUtc();
  final limit = nowUtc.add(horizon);
  final first = _civil(nowUtc).subtract(const Duration(days: 2));
  final result = <LocalReminder>[];
  for (final taskSeries in series) {
    final lead = taskSeries.maximumReminderLeadDays;
    if (lead == null) continue;
    final last = _civil(limit).add(Duration(days: lead + 3));
    var start = first;
    while (start.isBefore(last)) {
      final next = start.add(const Duration(days: 366));
      final end = next.isBefore(last) ? next : last;
      for (final occurrence in taskSeries.occurrences(
        windowStart: start,
        windowEnd: end,
      )) {
        final fireAt = occurrence.reminderAt;
        if (fireAt == null ||
            !fireAt.isAfter(nowUtc) ||
            fireAt.isAfter(limit)) {
          continue;
        }
        result.add(
          LocalReminder(
            target: ReminderTarget(
              kind: ReminderTargetKind.task,
              recordId: taskSeries.id,
              occurrenceId: occurrence.id,
            ),
            at: fireAt,
            recordTitle: occurrence.task.title,
          ),
        );
      }
      start = end;
    }
  }
  result.sort((a, b) {
    final byTime = a.at.compareTo(b.at);
    return byTime == 0 ? a.id.compareTo(b.id) : byTime;
  });
  return List.unmodifiable(result);
}

/// Resolves typed civil fields without normalizing a date or DST gap. A
/// repeated time chooses the earlier instant unless the later was selected.
DateTime? resolveReminderClock(
  DateTime civil, {
  String? timeZoneId,
  bool laterFold = false,
}) {
  final wall = DateTime.utc(
    civil.year,
    civil.month,
    civil.day,
    civil.hour,
    civil.minute,
    civil.second,
  );
  final zone = timeZoneId == null ? null : _zone(timeZoneId);
  DateTime local(DateTime at) =>
      zone == null ? at.toLocal() : timezone.TZDateTime.from(at, zone);
  final offsets = {
    for (final day in [-2, 0, 2])
      local(wall.add(Duration(days: day))).timeZoneOffset,
  };
  DateTime? resolved;
  for (final offset in offsets) {
    final instant = wall.subtract(offset);
    final actual = local(instant);
    if (actual.year == wall.year &&
        actual.month == wall.month &&
        actual.day == wall.day &&
        actual.hour == wall.hour &&
        actual.minute == wall.minute &&
        actual.second == wall.second &&
        (resolved == null ||
            (laterFold
                ? instant.isAfter(resolved)
                : instant.isBefore(resolved)))) {
      resolved = instant;
    }
  }
  return resolved;
}

timezone.Location _zone(String name) {
  if (timezone.timeZoneDatabase.locations.isEmpty) {
    timezone_data.initializeTimeZones();
  }
  return timezone.timeZoneDatabase.locations[name] ??
      (throw ArgumentError('Choose a valid IANA time zone.'));
}

DateTime _civil(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _nextWholeSecond(DateTime value) {
  final micros = value.microsecondsSinceEpoch;
  final remainder = micros % Duration.microsecondsPerSecond;
  return DateTime.fromMicrosecondsSinceEpoch(
    remainder == 0
        ? micros
        : micros + Duration.microsecondsPerSecond - remainder,
    isUtc: true,
  );
}

void _checkHorizon(Duration duration) {
  if (duration <= Duration.zero ||
      duration > const Duration(days: localReminderHorizonDays)) {
    throw ArgumentError('Choose a reminder horizon of up to 30 days.');
  }
}
