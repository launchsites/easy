import 'dart:convert';

import 'package:crypto/crypto.dart';

part 'automation_dispatch.dart';

enum AutomationTrigger {
  taskCompleted('Task completed'),
  acceptedEventStarted('Calendar event starts'),
  workoutFinished('Workout finished'),
  reviewSaved('Reflection saved');

  const AutomationTrigger(this.label);
  final String label;
}

enum AutomationOrigin { user, acceptedSchedule, automation }

enum AutomationActionKind {
  taskDraft('Task draft'),
  noteDraft('Note draft');

  const AutomationActionKind(this.label);
  final String label;
}

class AutomationAction {
  AutomationAction({required this.kind, required String text, this.category})
    : text = _input(text, 'draft text', max: 12000);

  factory AutomationAction.fromJson(Map<String, dynamic> json) =>
      AutomationAction(
        kind: _enum(AutomationActionKind.values, json['kind']),
        text: _string(json['text']),
        category: _optionalString(json['category']),
      );

  final AutomationActionKind kind;
  final String text;
  final String? category;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    'category': category,
  };
}

class AutomationCondition {
  AutomationCondition({
    this.category,
    Iterable<int> weekdays = const [],
    this.startMinute,
    this.endMinute,
  }) : weekdays = Set.unmodifiable(weekdays) {
    if (this.weekdays.any(
      (day) => day < DateTime.monday || day > DateTime.sunday,
    )) {
      throw const FormatException('Choose valid weekdays.');
    }
    final start = startMinute;
    final end = endMinute;
    if ((start == null) != (end == null) ||
        (start != null &&
            (start < 0 ||
                end! < 0 ||
                start >= 1440 ||
                end >= 1440 ||
                start == end))) {
      throw const FormatException('Choose two different times.');
    }
  }

  factory AutomationCondition.fromJson(Map<String, dynamic> json) =>
      AutomationCondition(
        category: _optionalString(json['category']),
        weekdays: _list(json['weekdays']).map(_integer),
        startMinute: json['startMinute'] == null
            ? null
            : _integer(json['startMinute']),
        endMinute: json['endMinute'] == null
            ? null
            : _integer(json['endMinute']),
      );

  final String? category;
  final Set<int> weekdays;
  final int? startMinute;
  final int? endMinute;

  bool matches(AutomationEvent event) {
    if (category != null && category != event.category) return false;
    var day = event.wallWeekday;
    final start = startMinute;
    final end = endMinute;
    final minute = event.wallMinute;
    if (start != null && end != null) {
      if (start < end) {
        if (minute < start || minute >= end) return false;
      } else {
        if (minute >= end && minute < start) return false;
        if (minute < end) {
          day = day == DateTime.monday ? DateTime.sunday : day - 1;
        }
      }
    }
    return weekdays.isEmpty || weekdays.contains(day);
  }

  Map<String, Object?> toJson() => {
    'category': category,
    'weekdays': weekdays.toList()..sort(),
    'startMinute': startMinute,
    'endMinute': endMinute,
  };
}

class AutomationEvent {
  AutomationEvent({
    required this.trigger,
    required String sourceId,
    required String occurrenceId,
    required this.sourceRevision,
    required DateTime occurredAt,
    DateTime? eligibleUntil,
    this.category,
    String? sourceTitle,
    this.origin = AutomationOrigin.user,
    int? wallWeekday,
    int? wallMinute,
  }) : sourceId = _input(sourceId, 'source ID'),
       occurrenceId = _input(occurrenceId, 'occurrence ID'),
       sourceTitle = _sourcePreview(sourceTitle),
       occurredAt = occurredAt.toUtc(),
       eligibleUntil = eligibleUntil?.toUtc(),
       wallWeekday = wallWeekday ?? occurredAt.toLocal().weekday,
       wallMinute =
           wallMinute ??
           (occurredAt.toLocal().hour * 60 + occurredAt.toLocal().minute) {
    if (sourceRevision < 0 ||
        this.wallWeekday < 1 ||
        this.wallWeekday > 7 ||
        this.wallMinute < 0 ||
        this.wallMinute >= 1440 ||
        (eligibleUntil != null && !eligibleUntil.isAfter(occurredAt))) {
      throw const FormatException('Invalid automation occurrence.');
    }
  }

  factory AutomationEvent.fromJson(Map<String, dynamic> json) =>
      AutomationEvent(
        trigger: _enum(AutomationTrigger.values, json['trigger']),
        sourceId: _string(json['sourceId']),
        occurrenceId: _string(json['occurrenceId']),
        sourceRevision: _integer(json['sourceRevision']),
        occurredAt: _instant(json['occurredAt']),
        eligibleUntil: _optionalInstant(json['eligibleUntil']),
        category: _optionalString(json['category']),
        sourceTitle: _optionalString(json['sourceTitle']),
        origin: _enum(AutomationOrigin.values, json['origin']),
        wallWeekday: _integer(json['wallWeekday']),
        wallMinute: _integer(json['wallMinute']),
      );

  final AutomationTrigger trigger;
  final String sourceId;
  final String occurrenceId;
  final int sourceRevision;
  final DateTime occurredAt;

  /// For accepted event starts, the event end bounds a foreground catch-up.
  final DateTime? eligibleUntil;
  final String? category;
  final String? sourceTitle;
  final AutomationOrigin origin;
  final int wallWeekday;
  final int wallMinute;

  String get key => _key([trigger.name, sourceId, occurrenceId]);

  Map<String, Object?> toJson() => {
    'trigger': trigger.name,
    'sourceId': sourceId,
    'occurrenceId': occurrenceId,
    'sourceRevision': sourceRevision,
    'occurredAt': occurredAt.toIso8601String(),
    'eligibleUntil': eligibleUntil?.toIso8601String(),
    'category': category,
    'sourceTitle': sourceTitle,
    'origin': origin.name,
    'wallWeekday': wallWeekday,
    'wallMinute': wallMinute,
  };
}

class AutomationRule {
  AutomationRule({
    required String id,
    required String name,
    required this.trigger,
    required this.condition,
    required this.action,
    DateTime? enabledSince,
  }) : id = _input(id, 'rule ID'),
       name = _input(name, 'rule name', max: 160),
       enabledSince = enabledSince?.toUtc();

  factory AutomationRule.fromJson(Map<String, dynamic> json) => AutomationRule(
    id: _string(json['id']),
    name: _string(json['name']),
    trigger: _enum(AutomationTrigger.values, json['trigger']),
    condition: AutomationCondition.fromJson(_object(json['condition'])),
    action: AutomationAction.fromJson(_object(json['action'])),
    enabledSince: _optionalInstant(json['enabledSince']),
  );

  final String id;
  final String name;
  final AutomationTrigger trigger;
  final AutomationCondition condition;
  final AutomationAction action;
  final DateTime? enabledSince;

  bool get enabled => enabledSince != null;

  AutomationRule withEnabled(bool value, DateTime now) => AutomationRule(
    id: id,
    name: name,
    trigger: trigger,
    condition: condition,
    action: action,
    enabledSince: value ? enabledSince ?? now : null,
  );

  bool matches(AutomationEvent event) {
    final since = enabledSince;
    return since != null &&
        !event.occurredAt.isBefore(since) &&
        trigger == event.trigger &&
        condition.matches(event);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'trigger': trigger.name,
    'condition': condition.toJson(),
    'action': action.toJson(),
    'enabledSince': enabledSince?.toIso8601String(),
  };
}

enum AutomationDraftStatus { pending, accepted, dismissed }

class AutomationDraft {
  AutomationDraft._({
    required this.id,
    required this.event,
    required this.ruleId,
    required this.ruleName,
    required this.action,
    required this.createdAt,
    this.status = AutomationDraftStatus.pending,
    this.reviewedAt,
  }) {
    if (id != _key([event.key, ruleId]) ||
        createdAt.isBefore(event.occurredAt) ||
        (reviewedAt == null) != (status == AutomationDraftStatus.pending) ||
        (reviewedAt?.isBefore(createdAt) ?? false)) {
      throw const FormatException('Invalid automation draft.');
    }
  }

  factory AutomationDraft.fromJson(Map<String, dynamic> json) =>
      AutomationDraft._(
        id: _string(json['id']),
        event: AutomationEvent.fromJson(_object(json['event'])),
        ruleId: _string(json['ruleId']),
        ruleName: _string(json['ruleName']),
        action: AutomationAction.fromJson(_object(json['action'])),
        createdAt: _instant(json['createdAt']),
        status: _enum(AutomationDraftStatus.values, json['status']),
        reviewedAt: _optionalInstant(json['reviewedAt']),
      );

  final String id;
  final AutomationEvent event;
  final String ruleId;
  final String ruleName;
  final AutomationAction action;
  final DateTime createdAt;
  final AutomationDraftStatus status;
  final DateTime? reviewedAt;

  AutomationDraft _reviewed(AutomationDraftStatus status, DateTime time) =>
      AutomationDraft._(
        id: id,
        event: event,
        ruleId: ruleId,
        ruleName: ruleName,
        action: action,
        createdAt: createdAt,
        status: status,
        reviewedAt: time,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'event': event.toJson(),
    'ruleId': ruleId,
    'ruleName': ruleName,
    'action': action.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'reviewedAt': reviewedAt?.toIso8601String(),
  };
}

String _key(List<String> components) =>
    sha256.convert(utf8.encode(jsonEncode(components))).toString();

String _string(Object? value) => value is String
    ? value
    : throw const FormatException('Expected automation text.');

String? _optionalString(Object? value) => value == null ? null : _string(value);

String? _sourcePreview(String? title) {
  const limit = 480;
  if (title == null || title.length <= limit) return title;
  final boundary = title.codeUnitAt(limit - 2);
  final end = boundary >= 0xd800 && boundary <= 0xdbff ? limit - 2 : limit - 1;
  return '${title.substring(0, end)}…';
}

String _input(String value, String label, {int max = 1500}) {
  if (value.trim().isEmpty || value.length > max) {
    throw FormatException('Enter a $label of at most $max characters.');
  }
  return value;
}

int _integer(Object? value) => value is int
    ? value
    : throw const FormatException('Expected an automation integer.');

DateTime _instant(Object? value) {
  final time = DateTime.tryParse(_string(value));
  if (time == null || !time.isUtc) {
    throw const FormatException('Expected a UTC automation timestamp.');
  }
  return time;
}

DateTime? _optionalInstant(Object? value) =>
    value == null ? null : _instant(value);

List<dynamic> _list(Object? value) => value is List<dynamic>
    ? value
    : throw const FormatException('Expected automation records.');

Map<String, dynamic> _object(Object? value) => value is Map<String, dynamic>
    ? value
    : throw const FormatException('Expected an automation record.');

T _enum<T extends Enum>(List<T> values, Object? name) =>
    values.where((value) => value.name == name).firstOrNull ??
    (throw const FormatException('Unsupported automation type.'));
