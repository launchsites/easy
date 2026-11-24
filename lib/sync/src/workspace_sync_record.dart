import 'dart:convert';

import '../../notes/note_model.dart';
import '../../task_model.dart';
import 'sync_change.dart';
import 'sync_replica.dart';

const workspaceRecordField = 'workspaceRecordV1';
const _recordByteLimit = 24 * 1024;
const _unsupported = FormatException(
  'This record uses an unsupported sync format.',
);

const workspaceRecordCollections = {
  SyncRecordKind.task: 'tasks',
  SyncRecordKind.calendarEvent: 'events',
  SyncRecordKind.note: 'notes',
};

/// One explicitly supported record, normalized to local days and UTC instants.
/// The journal stores one immutable value so a concurrent date and duration
/// edit never silently merges into a different event or task.
final class WorkspaceSyncRecord {
  WorkspaceSyncRecord._(this.key, this.document, this.references);

  factory WorkspaceSyncRecord.fromSaved(
    SyncRecordKind kind,
    Map<String, dynamic> json,
  ) => WorkspaceSyncRecord._parse(kind, json, portable: false);

  factory WorkspaceSyncRecord.fromJournal(SyncRecord record) {
    final versions = record.fields[workspaceRecordField];
    if (record.fields.length != 1 ||
        versions == null ||
        versions.isEmpty ||
        record.hasFieldConflict(workspaceRecordField)) {
      throw _unsupported;
    }
    final normalized = WorkspaceSyncRecord._parse(
      record.key.kind,
      _map(versions.first.value),
      portable: true,
    );
    if (normalized.key != record.key) throw _unsupported;
    return normalized;
  }

  factory WorkspaceSyncRecord._parse(
    SyncRecordKind kind,
    Map<String, dynamic> json, {
    required bool portable,
  }) {
    final id = _identifier(json['id']);
    final parsed = switch (kind) {
      SyncRecordKind.task => _task(json, portable),
      SyncRecordKind.calendarEvent => _event(json, portable),
      SyncRecordKind.note => _note(json, portable),
      _ => throw _unsupported,
    };
    final result = WorkspaceSyncRecord._(
      (kind: kind, id: id),
      Map.unmodifiable(parsed.document),
      List.unmodifiable(parsed.references),
    );
    if (utf8.encode(result.canonical).length > _recordByteLimit) {
      throw const FormatException(
        'This record is too large to stage for sync.',
      );
    }
    return result;
  }

  final SyncRecordKey key;
  final Map<String, Object?> document;
  final List<SyncRecordKey> references;

  late final String canonical = jsonEncode(document);
  String get title => document['title']! as String;
  Map<String, Object?> get journalFields => {workspaceRecordField: document};

  String get details => [
    switch (key.kind) {
      SyncRecordKind.task => 'Task',
      SyncRecordKind.calendarEvent => 'Calendar event',
      SyncRecordKind.note => 'Note',
      _ => throw _unsupported,
    },
    if (document['category'] case final String category
        when category.isNotEmpty)
      category,
    if (document['done'] case true) 'Completed',
    if (document['date'] case final String date) date,
    if (document['start'] case final String start)
      _displayDate(start, allDay: document['allDay'] == true),
    if (document['end'] case final String end)
      _displayDate(end, allDay: document['allDay'] == true),
    if (document['dueAt'] case final String due)
      'Due ${_displayDate(due, allDay: false)}',
    if (document['location'] case final String place) place,
    if (document['folder'] case final String folder) folder,
    if (references.isNotEmpty) '${references.length} linked records',
    if ((document['body'] ?? document['notes'] ?? document['description'])
        case final String text when text.trim().isNotEmpty)
      _snippet(text),
  ].join(' · ');

  Map<String, Object?> toSaved() {
    if (key.kind == SyncRecordKind.calendarEvent &&
        document['allDay'] == true) {
      return {
        ...document,
        for (final field in ['start', 'end'])
          field: '${document[field]}T00:00:00.000',
      };
    }
    if (key.kind == SyncRecordKind.task) {
      return {
        ...document,
        'date': document['date'] == null
            ? null
            : '${document['date']}T00:00:00.000',
      };
    }
    return document;
  }
}

typedef _Parsed = ({
  Map<String, Object?> document,
  List<SyncRecordKey> references,
});

_Parsed _task(Map<String, dynamic> json, bool portable) {
  _knownKeys(json, const {
    'id',
    'title',
    'category',
    'date',
    'done',
    'estimatedMinutes',
    'priority',
    'parentId',
    'notes',
    'earliestStart',
    'dueAt',
    'completedAt',
    'schedulingHold',
    'prerequisiteIds',
    'allowSplit',
    'minimumChunkMinutes',
  });
  final id = _identifier(json['id']);
  final date = json['date'] == null ? null : _day(json['date'], portable);
  final done = _bool(json['done']);
  final minutes = _positiveInt(json['estimatedMinutes']);
  final priority = _optionalText(json['priority'], 20);
  final parent = _optionalId(json['parentId']);
  final notes = _optionalText(json['notes'], _recordByteLimit);
  final start = _optionalInstant(json['earliestStart'], portable);
  final due = _optionalInstant(json['dueAt'], portable);
  final completed = _optionalInstant(json['completedAt'], portable);
  final prerequisites = _list(
    json['prerequisiteIds'],
    128,
  ).map(_identifier).toList();
  final split = json['allowSplit'] == null ? false : _bool(json['allowSplit']);
  final chunk =
      _positiveInt(json['minimumChunkMinutes']) ?? defaultTaskChunkMinutes;
  if (priority != null &&
          !TaskPriority.values.any((item) => item.name == priority) ||
      parent == id ||
      prerequisites.contains(id) ||
      prerequisites.toSet().length != prerequisites.length ||
      !done && completed != null ||
      start != null && due != null && start.isAfter(due) ||
      taskSplitIssue(
            allowSplit: split,
            minimumChunkMinutes: chunk,
            estimatedMinutes: minutes,
          ) !=
          null) {
    throw _unsupported;
  }
  final hold = _hold(json['schedulingHold']);
  return (
    document: {
      'id': id,
      'title': _text(json['title'], 512, nonEmpty: true),
      'category': _text(json['category'], 160),
      'done': done,
      'date': ?date,
      'estimatedMinutes': ?minutes,
      'priority': ?priority,
      'parentId': ?parent,
      'notes': ?notes,
      'earliestStart': ?start?.toIso8601String(),
      'dueAt': ?due?.toIso8601String(),
      'completedAt': ?completed?.toIso8601String(),
      if (hold != null) 'schedulingHold': Map.unmodifiable(hold.toJson()),
      if (prerequisites.isNotEmpty)
        'prerequisiteIds': List.unmodifiable(prerequisites),
      if (split) 'allowSplit': true,
      if (chunk != defaultTaskChunkMinutes) 'minimumChunkMinutes': chunk,
    },
    references: [
      if (parent != null) (kind: SyncRecordKind.task, id: parent),
      for (final prior in prerequisites) (kind: SyncRecordKind.task, id: prior),
    ],
  );
}

_Parsed _event(Map<String, dynamic> json, bool portable) {
  _knownKeys(json, const {
    'id',
    'title',
    'start',
    'end',
    'category',
    'allDay',
    'location',
    'description',
  });
  final allDay = _bool(json['allDay']);
  String time(Object? value) => allDay
      ? _day(value, portable)
      : _instant(value, portable).toIso8601String();
  final start = time(json['start']);
  final end = time(json['end']);
  if (!DateTime.parse(end).isAfter(DateTime.parse(start))) throw _unsupported;
  return (
    document: {
      'id': _identifier(json['id']),
      'title': _text(json['title'], 512, nonEmpty: true),
      'start': start,
      'end': end,
      'category': _text(json['category'], 160),
      'allDay': allDay,
      'location': ?_optionalText(json['location'], 1024),
      'description': ?_optionalText(json['description'], _recordByteLimit),
    },
    references: [],
  );
}

_Parsed _note(Map<String, dynamic> json, bool portable) {
  _knownKeys(json, const {
    'id',
    'title',
    'body',
    'updated',
    'category',
    'noteToSelf',
    'pinned',
    'folder',
    'tags',
    'links',
  });
  final tags = _list(
    json['tags'],
    100,
  ).map((tag) => _text(tag, 120, nonEmpty: true)).toList();
  final links = <Map<String, Object?>>[];
  final references = <SyncRecordKey>{};
  for (final item in _list(json['links'], 100)) {
    final row = _map(item);
    _knownKeys(row, const {'kind', 'id', 'title'});
    final parsed = NoteLink.fromJson(row);
    final target = _identifier(parsed.id);
    final kind = parsed.kind == NoteLinkKind.task
        ? SyncRecordKind.task
        : SyncRecordKind.calendarEvent;
    if (!references.add((kind: kind, id: target))) throw _unsupported;
    links.add(
      Map.unmodifiable({
        'id': target,
        'kind': parsed.kind.name,
        'title': ?_optionalText(parsed.title, 512),
      }),
    );
  }
  return (
    document: {
      'id': _identifier(json['id']),
      'title': _text(json['title'], 512, nonEmpty: true),
      'body': _text(json['body'], _recordByteLimit),
      'updated': _instant(json['updated'], portable).toIso8601String(),
      'category': ?_optionalText(json['category'], 160),
      if (json['noteToSelf'] != null && _bool(json['noteToSelf']))
        'noteToSelf': true,
      if (json['pinned'] != null && _bool(json['pinned'])) 'pinned': true,
      'folder': ?_optionalText(json['folder'], 240),
      if (tags.isNotEmpty) 'tags': List.unmodifiable(tags),
      if (links.isNotEmpty) 'links': List.unmodifiable(links),
    },
    references: references.toList(),
  );
}

TaskSchedulingHold? _hold(Object? value) {
  if (value == null) return null;
  final row = _map(value);
  _knownKeys(row, const {'reason', 'detail'});
  final reason = TaskSchedulingHoldReason.values
      .where((reason) => reason.name == row['reason'])
      .firstOrNull;
  if (reason == null) throw _unsupported;
  return TaskSchedulingHold(
    reason: reason,
    detail: _optionalText(row['detail'], maxTaskSchedulingHoldDetailLength),
  );
}

final _date = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})(?:T([0-2]\d):([0-5]\d)(?::([0-5]\d)(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})?)?$',
);

DateTime _dateTime(Object? value) {
  if (value is! String || value.length > 35) throw _unsupported;
  final match = _date.firstMatch(value);
  if (match == null || match.end != value.length) throw _unsupported;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final civil = DateTime.utc(year, month, day);
  if (year < 1 ||
      civil.year != year ||
      civil.month != month ||
      civil.day != day ||
      (int.tryParse(match.group(4) ?? '0') ?? 24) > 23) {
    throw _unsupported;
  }
  return DateTime.tryParse(value) ?? (throw _unsupported);
}

String _day(Object? value, bool portable) {
  _dateTime(value);
  final text = value! as String;
  final result = text.substring(0, 10);
  if (portable && text != result) throw _unsupported;
  return result;
}

DateTime _instant(Object? value, bool portable) {
  final parsed = _dateTime(value).toUtc();
  if (portable && parsed.toIso8601String() != value) throw _unsupported;
  return parsed;
}

DateTime? _optionalInstant(Object? value, bool portable) =>
    value == null ? null : _instant(value, portable);

String _displayDate(String text, {required bool allDay}) {
  if (allDay) return text;
  return DateTime.parse(text)
      .toLocal()
      .toIso8601String()
      .substring(0, 16)
      .replaceFirst('T', ' ');
}

String _snippet(String text) =>
    String.fromCharCodes(text.trim().runes.take(193));

String _identifier(Object? value) {
  if (value is! String ||
      !isValidSyncRecordId(value) ||
      value.startsWith('apple:') ||
      value.startsWith('ics:')) {
    throw _unsupported;
  }
  return value;
}

String? _optionalId(Object? value) => value == null ? null : _identifier(value);

String _text(Object? value, int limit, {bool nonEmpty = false}) {
  if (value is! String ||
      value.length > limit ||
      (nonEmpty && value.trim().isEmpty)) {
    throw _unsupported;
  }
  return value;
}

String? _optionalText(Object? value, int limit) =>
    value == null ? null : _text(value, limit);

int? _positiveInt(Object? value) {
  if (value == null) return null;
  if (value is! int || value <= 0 || value > 24 * 60 * 366) throw _unsupported;
  return value;
}

bool _bool(Object? value) => value is bool ? value : throw _unsupported;

List<Object?> _list(Object? value, int maximum) {
  if (value == null) return const [];
  if (value is! List || value.length > maximum) throw _unsupported;
  return value.cast<Object?>();
}

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : throw _unsupported;

void _knownKeys(Map<String, dynamic> value, Set<String> supported) {
  if (value.keys.any((key) => !supported.contains(key))) throw _unsupported;
}
