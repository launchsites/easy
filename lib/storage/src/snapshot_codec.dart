import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../activities/activity_model.dart';
import '../../capture/capture_archive.dart';
import '../../notes/note_model.dart';
import '../../nutrition/nutrition_model.dart';
import '../../workout_plan.dart';
import 'contracts.dart';

const _maximumSnapshotBytes = 64 * 1024 * 1024;
const workspaceBackupByteLimit = 192 * 1024 * 1024;
const _maximumDepth = 64;
const _backupFormat = 'easy.workspace-backup';
const _backupVersion = 1;

final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

String digestText(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, Object> snapshotFields(WorkspaceSnapshot snapshot) => {
  'workspace': snapshot.workspaceJson,
  'gymSessions': snapshot.gymSessionJson,
  'workoutPlans': snapshot.workoutPlanJson,
};

WorkspaceSnapshot snapshotFromFields(Map<String, dynamic> fields) {
  return WorkspaceSnapshot(
    workspaceJson: stringField(fields, 'workspace'),
    gymSessionJson: _serializedRecords(fields, 'gymSessions'),
    workoutPlanJson: _serializedRecords(fields, 'workoutPlans'),
  );
}

String mutationFingerprint(WorkspaceMutation mutation) => digestText(
  jsonEncode(switch (mutation) {
    SetWorkspace(:final json) => ['workspace', json],
    SetGymSessions(:final json) => ['gymSessions', json],
    SetWorkoutPlans(:final json) => ['workoutPlans', json],
    ReplaceWorkspace(:final snapshot) => ['replace', snapshotFields(snapshot)],
  }),
);

String? validateOperationId(String? id) {
  if (id != null && (id.trim().isEmpty || id.length > 200)) {
    throw ArgumentError('Use an operation ID of 1 to 200 characters.');
  }
  return id;
}

void verifyRevision(int? expected, int actual) {
  if (expected != null && expected != actual) {
    throw WorkspaceRevisionConflict(expected: expected, actual: actual);
  }
}

bool snapshotsEqual(WorkspaceSnapshot a, WorkspaceSnapshot b) =>
    a.workspaceJson == b.workspaceJson &&
    _stringsEqual(a.gymSessionJson, b.gymSessionJson) &&
    _stringsEqual(a.workoutPlanJson, b.workoutPlanJson);

bool _stringsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

WorkspaceRecordCounts validateSnapshot(WorkspaceSnapshot snapshot) {
  var size = 0;
  for (final document in [
    snapshot.workspaceJson,
    ...snapshot.gymSessionJson,
    ...snapshot.workoutPlanJson,
  ]) {
    if (document.length > _maximumSnapshotBytes - size) {
      throw const FormatException('The workspace snapshot is too large.');
    }
    size += utf8.encode(document).length;
    if (size > _maximumSnapshotBytes) {
      throw const FormatException('The workspace snapshot is too large.');
    }
  }

  final workspace = jsonObject(
    decodeJson(snapshot.workspaceJson, 'workspace'),
    'workspace',
  );
  final events = _records(workspace, 'events');
  final tasks = _records(workspace, 'tasks');
  final notes = _records(workspace, 'notes');
  final captures = workspace['captures'] == null
      ? const <Map<String, dynamic>>[]
      : _records(workspace, 'captures');

  for (final event in events) {
    stringField(event, 'title');
    stringField(event, 'category');
    _dateField(event, 'start');
    _dateField(event, 'end');
    _boolField(event, 'allDay');
    _optionalString(event, 'location');
    _optionalString(event, 'plannedTaskId');
    _optionalString(event, 'description');
  }
  for (final task in tasks) {
    stringField(task, 'title');
    stringField(task, 'category');
    _boolField(task, 'done');
    if (task['date'] != null) _dateField(task, 'date');
    if (task['completedAt'] != null) _dateField(task, 'completedAt');
    _optionalInt(task, 'estimatedMinutes');
    _optionalString(task, 'priority');
    _optionalString(task, 'parentId');
    _optionalString(task, 'notes');
    if (task['earliestStart'] != null) _dateField(task, 'earliestStart');
    if (task['dueAt'] != null) _dateField(task, 'dueAt');
    if (task['prerequisiteIds'] != null) {
      _serializedRecords(task, 'prerequisiteIds');
    }
    if (task['allowSplit'] != null) _boolField(task, 'allowSplit');
    _optionalInt(task, 'minimumChunkMinutes');
  }
  for (final note in notes) {
    _validateRecord('note', () => NoteItem.fromJson(note));
  }
  for (final capture in captures) {
    _validateRecord('capture', () => CaptureArchiveEntry.fromJson(capture));
  }
  final nutrition = workspace['nutrition'] == null
      ? null
      : _validateRecord(
          'nutrition',
          () => NutritionData.fromJson(
            jsonObject(workspace['nutrition'], 'nutrition'),
          ),
        );
  final activities = workspace['activities'] == null
      ? null
      : _validateRecord(
          'activities',
          () => ActivityData.fromJson(
            jsonObject(workspace['activities'], 'activities'),
          ),
        );

  final sessionStarts = <DateTime>{};
  for (final text in snapshot.gymSessionJson) {
    final session = jsonObject(decodeJson(text, 'gym session'), 'gym session');
    final startedAt = _dateField(session, 'startedAt');
    if (!sessionStarts.add(startedAt)) {
      throw const FormatException('Duplicate gym session start.');
    }
    _boolField(session, 'planned');
    if (session['finishedAt'] != null) _dateField(session, 'finishedAt');
    _optionalString(session, 'planId');
    _optionalString(session, 'planName');
    for (final entry in _records(session, 'entries')) {
      stringField(entry, 'title');
      _dateField(entry, 'loggedAt');
      _optionalString(entry, 'actual');
      _optionalString(entry, 'exerciseId');
    }
    final exercises = session['exercises'] == null
        ? const <Map<String, dynamic>>[]
        : _records(session, 'exercises');
    final progressKeys = <String>{};
    try {
      for (final exercise in exercises) {
        final parsed = WorkoutExercise.fromJson(exercise);
        progressKeys.add(jsonEncode([parsed.id]));
        final setIds = <String>{};
        for (final set in parsed.sets) {
          if (!setIds.add(set.id)) {
            throw const FormatException('Duplicate exercise set.');
          }
          progressKeys.add(jsonEncode([parsed.id, set.id]));
        }
      }
    } on ArgumentError {
      throw const FormatException('Invalid gym exercise.');
    }
    if (session['progress'] case final value?) {
      const statuses = {'pending', 'done', 'skipped'};
      if (jsonObject(value, 'gym progress').entries.any(
        (entry) =>
            !progressKeys.contains(entry.key) ||
            !statuses.contains(entry.value),
      )) {
        throw const FormatException('Gym progress has an invalid exercise.');
      }
    }
  }

  final planIds = <String>{};
  for (final text in snapshot.workoutPlanJson) {
    final WorkoutPlan plan;
    try {
      plan = WorkoutPlan.fromJson(
        jsonObject(decodeJson(text, 'workout plan'), 'workout plan'),
      );
    } on ArgumentError {
      throw const FormatException('Invalid workout plan fields.');
    }
    if (!planIds.add(plan.id)) {
      throw const FormatException('Duplicate workout plan ID.');
    }
  }

  return WorkspaceRecordCounts(
    events: events.length,
    tasks: tasks.length,
    notes: notes.length,
    gymSessions: snapshot.gymSessionJson.length,
    workoutPlans: snapshot.workoutPlanJson.length,
    captures: captures.length,
    meals: nutrition?.meals.length ?? 0,
    foods: nutrition?.foods.length ?? 0,
    activities: activities?.records.length ?? 0,
    routines: activities?.routines.length ?? 0,
  );
}

T _validateRecord<T>(String label, T Function() parse) {
  try {
    return parse();
  } on FormatException {
    throw FormatException('Invalid $label record.');
  } on TypeError {
    throw FormatException('Invalid $label record.');
  } on ArgumentError {
    throw FormatException('Invalid $label record.');
  }
}

Uint8List encodeBackup(WorkspaceRevision revision) {
  final payload = jsonEncode({
    'revision': revision.revision,
    ...snapshotFields(revision.snapshot),
  });
  final backup = utf8.encode(
    jsonEncode({
      'format': _backupFormat,
      'version': _backupVersion,
      'sha256': digestText(payload),
      'payload': payload,
    }),
  );
  if (backup.length > workspaceBackupByteLimit) {
    throw const FormatException('The workspace backup is too large.');
  }
  return Uint8List.fromList(backup);
}

WorkspaceBackupPreview decodeBackup(Uint8List bytes) {
  if (bytes.length > workspaceBackupByteLimit) {
    throw const FormatException('The workspace backup is too large.');
  }
  final text = utf8.decode(bytes);
  final envelope = jsonObject(decodeJson(text, 'backup'), 'backup');
  if (envelope['format'] != _backupFormat ||
      envelope['version'] != _backupVersion) {
    throw const FormatException('Unsupported workspace backup format.');
  }
  final payload = stringField(envelope, 'payload');
  final checksum = stringField(envelope, 'sha256');
  if (!_sha256Pattern.hasMatch(checksum) || digestText(payload) != checksum) {
    throw const FormatException('The workspace backup checksum is invalid.');
  }
  final fields = jsonObject(decodeJson(payload, 'backup payload'), 'backup');
  final revision = positiveRevision(fields['revision']);
  final snapshot = snapshotFromFields(fields);
  return WorkspaceBackupPreview(
    snapshot: snapshot,
    sourceRevision: revision,
    counts: validateSnapshot(snapshot),
  );
}

int positiveRevision(Object? value) {
  if (value is! int || value <= 0) {
    throw const FormatException('Invalid workspace revision.');
  }
  return value;
}

Object? decodeJson(String text, String label) {
  var inString = false;
  var escape = false;
  var depth = 0;
  for (final code in text.codeUnits) {
    if (inString) {
      if (escape) {
        escape = false;
      } else if (code == 92) {
        escape = true;
      } else if (code == 34) {
        inString = false;
      }
    } else if (code == 34) {
      inString = true;
    } else if (code == 123 || code == 91) {
      if (++depth > _maximumDepth) {
        throw FormatException('The $label JSON is nested too deeply.');
      }
    } else if (code == 125 || code == 93) {
      depth--;
    }
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    throw FormatException('Invalid $label JSON.');
  }
}

Map<String, dynamic> jsonObject(Object? value, String name) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('Invalid $name object.');
  }
  return value;
}

String stringField(Map<String, dynamic> record, String name) {
  final value = record[name];
  if (value is! String) throw FormatException('Invalid $name field.');
  return value;
}

void _optionalString(Map<String, dynamic> record, String name) {
  if (record[name] != null) stringField(record, name);
}

void _boolField(Map<String, dynamic> record, String name) {
  if (record[name] is! bool) throw FormatException('Invalid $name field.');
}

void _optionalInt(Map<String, dynamic> record, String name) {
  final value = record[name];
  if (value != null && value is! int) {
    throw FormatException('Invalid $name field.');
  }
}

DateTime _dateField(Map<String, dynamic> record, String name) {
  final parsed = DateTime.tryParse(stringField(record, name));
  if (parsed == null) throw FormatException('Invalid $name date.');
  return parsed;
}

List<Map<String, dynamic>> _records(Map<String, dynamic> data, String key) {
  final values = data[key];
  if (values is! List<dynamic>) throw FormatException('Invalid $key list.');
  final ids = <String>{};
  return [for (final value in values) _record(value, ids, key)];
}

Map<String, dynamic> _record(Object? value, Set<String> ids, String key) {
  final record = jsonObject(value, key);
  final id = stringField(record, 'id');
  if (id.isEmpty || !ids.add(id)) throw FormatException('Invalid $key ID.');
  return record;
}

List<String> _serializedRecords(Map<String, dynamic> data, String key) {
  final list = data[key];
  if (list is! List<dynamic> || list.any((value) => value is! String)) {
    throw FormatException('Invalid $key list.');
  }
  return list.cast<String>();
}
