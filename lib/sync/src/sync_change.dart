import 'dart:convert';

import 'sync_wire.dart';

const _changeVersion = 1;
const _maximumFields = 128;
const _maximumFieldDepth = 18;
const _maximumItems = 2048;
const _maximumStringLength = 64 * 1024;

final _workspaceIdPattern = RegExp(r'^[a-f0-9]{32}$');
final _recordIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:@+\-]{0,199}$');
final _fieldNamePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

final class SyncWorkspaceId {
  SyncWorkspaceId(String value) : value = _validate(value);

  factory SyncWorkspaceId.generate() =>
      SyncWorkspaceId(syncHex(syncRandomBytes(16)));

  final String value;

  static String _validate(String value) {
    if (!syncMatches(_workspaceIdPattern, value)) {
      throw const FormatException('Invalid sync workspace ID.');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is SyncWorkspaceId && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// An immutable, contiguous applied watermark for each device.
final class SyncVersionVector {
  const SyncVersionVector.empty() : counters = const {};

  factory SyncVersionVector(Map<String, int> counters) {
    if (counters.length > maxSyncDevices) {
      throw const FormatException('Too many devices in sync history.');
    }
    final ordered = counters.keys.toList()..sort();
    for (final deviceId in ordered) {
      final count = counters[deviceId]!;
      if (!syncMatches(syncDeviceIdPattern, deviceId) ||
          count < 1 ||
          count > maxSyncCounter) {
        throw const FormatException('Invalid sync history watermark.');
      }
    }
    return SyncVersionVector._(
      Map.unmodifiable({
        for (final deviceId in ordered) deviceId: counters[deviceId]!,
      }),
    );
  }

  const SyncVersionVector._(this.counters);

  final Map<String, int> counters;

  int operator [](String deviceId) => counters[deviceId] ?? 0;

  bool covers(SyncVersionVector other) =>
      other.counters.entries.every((entry) => this[entry.key] >= entry.value);

  bool contains(SyncDot dot) => this[dot.deviceId] >= dot.counter;

  SyncVersionVector missingFrom(SyncVersionVector available) =>
      SyncVersionVector({
        for (final entry in counters.entries)
          if (available[entry.key] < entry.value) entry.key: entry.value,
      });
}

typedef SyncDot = ({String deviceId, int counter});
typedef SyncRecordKey = ({SyncRecordKind kind, String id});

enum SyncRecordKind {
  task,
  calendarEvent,
  note,
  capture,
  gymSession,
  workoutPlan,
  meal,
}

enum SyncChangeKind { patch, delete, restore }

/// One record mutation. Nested JSON objects and lists are immutable and are
/// merged as whole field values so each competing value stays recoverable.
final class SyncChange {
  factory SyncChange({
    required SyncWorkspaceId workspaceId,
    required SyncDot dot,
    required SyncVersionVector context,
    required SyncRecordKey record,
    required SyncChangeKind kind,
    Map<String, Object?> fields = const {},
  }) {
    if (!syncMatches(syncDeviceIdPattern, dot.deviceId) ||
        dot.counter != context[dot.deviceId] + 1 ||
        dot.counter > maxSyncCounter) {
      throw const FormatException('Invalid sync change counter.');
    }
    if (!syncMatches(_recordIdPattern, record.id)) {
      throw const FormatException('Invalid sync record ID.');
    }
    if (fields.length > _maximumFields ||
        (kind == SyncChangeKind.patch && fields.isEmpty) ||
        (kind == SyncChangeKind.delete && fields.isNotEmpty)) {
      throw const FormatException('Invalid fields for this sync change.');
    }
    final keys = fields.keys.toList()..sort();
    final budget = _FieldBudget();
    final safeFields = <String, Object?>{};
    for (final key in keys) {
      if (!syncMatches(_fieldNamePattern, key)) {
        throw const FormatException('Invalid sync field name.');
      }
      budget.use(key.length);
      safeFields[key] = budget.copy(fields[key], 1);
    }
    final canonical = jsonEncode({
      'version': _changeVersion,
      'workspace': workspaceId.value,
      'device': dot.deviceId,
      'counter': dot.counter,
      'context': context.counters,
      'recordKind': record.kind.name,
      'recordId': record.id,
      'kind': kind.name,
      'fields': safeFields,
    });
    final byteLength = utf8.encode(canonical).length;
    if (byteLength > maxSyncChangeBytes) {
      throw const FormatException('Sync change exceeds its size limit.');
    }
    return SyncChange._(
      workspaceId: workspaceId,
      dot: dot,
      context: context,
      record: record,
      kind: kind,
      fields: Map.unmodifiable(safeFields),
      canonical: canonical,
      byteLength: byteLength,
    );
  }

  const SyncChange._({
    required this.workspaceId,
    required this.dot,
    required this.context,
    required this.record,
    required this.kind,
    required this.fields,
    required this.canonical,
    required this.byteLength,
  });

  factory SyncChange.decode(String canonical) {
    final json = syncDecodeJson(canonical, maxChars: maxSyncChangeBytes);
    if (json is! Map<String, dynamic> || json['version'] != _changeVersion) {
      throw const FormatException('Unsupported sync change format.');
    }
    final workspace = json['workspace'];
    final device = json['device'];
    final counter = json['counter'];
    final context = json['context'];
    final id = json['recordId'];
    final recordKind = SyncRecordKind.values
        .where((kind) => kind.name == json['recordKind'])
        .firstOrNull;
    final kind = SyncChangeKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    final fields = json['fields'];
    if (workspace is! String ||
        device is! String ||
        counter is! int ||
        context is! Map<String, dynamic> ||
        context.values.any((value) => value is! int) ||
        id is! String ||
        recordKind == null ||
        kind == null ||
        fields is! Map<String, dynamic>) {
      throw const FormatException('Invalid sync change fields.');
    }
    final change = SyncChange(
      workspaceId: SyncWorkspaceId(workspace),
      dot: (deviceId: device, counter: counter),
      context: SyncVersionVector(context.cast<String, int>()),
      record: (kind: recordKind, id: id),
      kind: kind,
      fields: fields,
    );
    if (change.canonical != canonical) {
      throw const FormatException('Sync change uses noncanonical encoding.');
    }
    return change;
  }

  final SyncWorkspaceId workspaceId;
  final SyncDot dot;
  final SyncVersionVector context;
  final SyncRecordKey record;
  final SyncChangeKind kind;
  final Map<String, Object?> fields;
  final String canonical;
  final int byteLength;
}

class _FieldBudget {
  var _remaining = maxSyncChangeBytes;

  void use(int size) {
    _remaining -= size;
    if (_remaining < 0) {
      throw const FormatException('Sync field values exceed their size limit.');
    }
  }

  Object? copy(Object? value, int depth) {
    use(1);
    if (depth > _maximumFieldDepth) {
      throw const FormatException('A sync field is nested too deeply.');
    }
    switch (value) {
      case null || bool():
        return value;
      case num()
          when value.isFinite &&
              value >= -maxSyncCounter &&
              value <= maxSyncCounter:
        use(1);
        // Native and browser JSON writers format integral decimals differently.
        final integral = value.toInt();
        return value == integral ? integral : value;
      case String() when value.length <= _maximumStringLength:
        use(value.length);
        return value;
      case List() when value.length <= _maximumItems:
        return List<Object?>.unmodifiable([
          for (final item in value) copy(item, depth + 1),
        ]);
      case Map() when value.length <= _maximumItems:
        final keys = <String>[];
        for (final key in value.keys) {
          if (key is! String || key.length > 200) {
            throw const FormatException('Invalid sync field object key.');
          }
          use(key.length + 1);
          keys.add(key);
        }
        keys.sort();
        return Map<String, Object?>.unmodifiable({
          for (final key in keys) key: copy(value[key], depth + 1),
        });
      default:
        throw const FormatException('Invalid sync field value.');
    }
  }
}
