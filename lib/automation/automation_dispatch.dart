part of 'automation_models.dart';

enum AutomationDispatchStatus {
  disabled,
  background,
  unsupported,
  stale,
  future,
  expired,
  replayed,
  unmatched,
  capacity,
  queued,
}

class AutomationDispatch {
  AutomationDispatch._(
    this.data,
    this.status, [
    Iterable<AutomationDraft> added = const [],
  ]) : addedDrafts = List.unmodifiable(added);

  final AutomationData data;
  final AutomationDispatchStatus status;
  final List<AutomationDraft> addedDrafts;
}

class _AutomationReceipt {
  _AutomationReceipt(this.key, this.occurredAt, this.revision) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) || revision < 0) {
      throw const FormatException('Invalid automation receipt.');
    }
  }

  factory _AutomationReceipt.fromJson(Map<String, dynamic> json) =>
      _AutomationReceipt(
        _string(json['key']),
        _instant(json['occurredAt']),
        _integer(json['revision']),
      );

  final String key;
  final DateTime occurredAt;
  final int revision;

  Map<String, Object?> toJson() => {
    'key': key,
    'occurredAt': occurredAt.toIso8601String(),
    'revision': revision,
  };
}

class AutomationData {
  AutomationData({List<AutomationRule> rules = const []})
    : this._(rules: rules);

  AutomationData._({
    List<AutomationRule> rules = const [],
    List<AutomationDraft> drafts = const [],
    List<_AutomationReceipt> receipts = const [],
    DateTime? enabledSince,
    DateTime? lastDispatchAt,
  }) : rules = List.unmodifiable(rules),
       drafts = List.unmodifiable(drafts),
       _receipts = {for (final receipt in receipts) receipt.key: receipt},
       enabledSince = enabledSince?.toUtc(),
       lastDispatchAt = lastDispatchAt?.toUtc() {
    if (rules.length > maxRules ||
        rules.map((rule) => rule.id).toSet().length != rules.length ||
        drafts.map((draft) => draft.id).toSet().length != drafts.length ||
        pending.length > maxPending ||
        drafts.length > maxPending + maxReviewed ||
        receipts.length > maxReceipts ||
        receipts.length != _receipts.length) {
      throw const FormatException('Invalid automation rules or history.');
    }
  }

  factory AutomationData.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported automation version.');
    }
    return AutomationData._(
      rules: _list(json['rules'])
          .map((rule) => AutomationRule.fromJson(_object(rule)))
          .toList(),
      drafts: _list(json['drafts'])
          .map((draft) => AutomationDraft.fromJson(_object(draft)))
          .toList(),
      receipts: _list(json['receipts'])
          .map((receipt) => _AutomationReceipt.fromJson(_object(receipt)))
          .toList(),
      enabledSince: _optionalInstant(json['enabledSince']),
      lastDispatchAt: _optionalInstant(json['lastDispatchAt']),
    );
  }

  factory AutomationData.decode(String raw) =>
      AutomationData.fromJson(_object(jsonDecode(raw)));

  static const maxRules = 256;
  static const maxPending = 128;
  static const maxReviewed = 512;
  static const maxReceipts = 4096;
  static const replayHorizon = Duration(days: 30);
  static const startFallbackWindow = Duration(minutes: 15);

  final List<AutomationRule> rules;
  final List<AutomationDraft> drafts;
  final Map<String, _AutomationReceipt> _receipts;
  final DateTime? enabledSince;
  final DateTime? lastDispatchAt;

  bool get enabled => enabledSince != null;
  Iterable<AutomationDraft> get pending =>
      drafts.where((draft) => draft.status == AutomationDraftStatus.pending);

  AutomationData withEnabled(bool value, DateTime now) => AutomationData._(
    rules: rules,
    drafts: drafts,
    receipts: _receipts.values.toList(),
    enabledSince: value ? enabledSince ?? now : null,
    lastDispatchAt: lastDispatchAt,
  );

  AutomationData withRule(AutomationRule rule) => AutomationData._(
    rules: [
      for (final item in rules)
        if (item.id != rule.id) item,
      rule,
    ],
    drafts: drafts,
    receipts: _receipts.values.toList(),
    enabledSince: enabledSince,
    lastDispatchAt: lastDispatchAt,
  );

  AutomationData withoutRule(String id) => AutomationData._(
    rules: rules.where((rule) => rule.id != id).toList(),
    drafts: drafts,
    receipts: _receipts.values.toList(),
    enabledSince: enabledSince,
    lastDispatchAt: lastDispatchAt,
  );

  AutomationDraft? draftById(String id) =>
      drafts.where((draft) => draft.id == id).firstOrNull;

  AutomationData reviewDraft(
    String id, {
    required AutomationDraftStatus status,
    required DateTime now,
    int? currentSourceRevision,
  }) {
    final draft = draftById(id);
    if (draft == null || status == AutomationDraftStatus.pending) {
      throw const FormatException('Choose an available automation draft.');
    }
    if (draft.status == status) return this;
    if (draft.status != AutomationDraftStatus.pending) {
      throw const FormatException('This draft has already been reviewed.');
    }
    if (status == AutomationDraftStatus.accepted &&
        currentSourceRevision != null &&
        currentSourceRevision != draft.event.sourceRevision) {
      throw const FormatException(
        'The source changed. Review its current state.',
      );
    }
    final time = now.isBefore(draft.createdAt) ? draft.createdAt : now.toUtc();
    final next = draft._reviewed(status, time);
    final reviewed = [
      for (final item in drafts)
        if (item.id != id && item.status != AutomationDraftStatus.pending) item,
      next,
    ]..sort((a, b) => b.reviewedAt!.compareTo(a.reviewedAt!));
    return AutomationData._(
      rules: rules,
      drafts: [
        ...pending.where((item) => item.id != id),
        ...reviewed.take(maxReviewed),
      ],
      receipts: _receipts.values.toList(),
      enabledSince: enabledSince,
      lastDispatchAt: lastDispatchAt,
    );
  }

  /// Pure evaluation. Persist [AutomationDispatch.data] in the same operation
  /// as the event transition, or retry with its same occurrence identity.
  AutomationDispatch dispatch(
    AutomationEvent event, {
    required int? currentSourceRevision,
    required DateTime now,
    required bool foreground,
    Set<AutomationTrigger>? enabledTriggers,
  }) {
    AutomationDispatch issue(AutomationDispatchStatus status) =>
        AutomationDispatch._(this, status);
    final since = enabledSince;
    if (since == null) return issue(AutomationDispatchStatus.disabled);
    if (!foreground) return issue(AutomationDispatchStatus.background);
    if (event.origin == AutomationOrigin.automation ||
        !(enabledTriggers?.contains(event.trigger) ?? true)) {
      return issue(AutomationDispatchStatus.unsupported);
    }
    final clockFloor = lastDispatchAt;
    final clock = clockFloor != null && now.isBefore(clockFloor)
        ? clockFloor
        : now.toUtc();
    if (event.occurredAt.isAfter(now)) {
      return issue(AutomationDispatchStatus.future);
    }
    if (event.occurredAt.isBefore(since)) {
      return issue(AutomationDispatchStatus.expired);
    }
    final cutoff = clock.subtract(replayHorizon);
    if (event.occurredAt.isBefore(cutoff)) {
      return issue(AutomationDispatchStatus.expired);
    }
    if (event.trigger == AutomationTrigger.acceptedEventStarted &&
        !clock.isBefore(
          event.eligibleUntil ?? event.occurredAt.add(startFallbackWindow),
        )) {
      return issue(AutomationDispatchStatus.expired);
    }
    final key = event.key;
    if (_receipts.containsKey(key) ||
        drafts.any((draft) => draft.event.key == key)) {
      return issue(AutomationDispatchStatus.replayed);
    }
    if (currentSourceRevision == null ||
        currentSourceRevision != event.sourceRevision) {
      return issue(AutomationDispatchStatus.stale);
    }
    final matched = rules.where((rule) => rule.matches(event)).toList();
    if (matched.isEmpty) return issue(AutomationDispatchStatus.unmatched);
    final recent = _receipts.values
        .where((receipt) => !receipt.occurredAt.isBefore(cutoff))
        .toList();
    if (pending.length + matched.length > maxPending ||
        recent.length >= maxReceipts) {
      return issue(AutomationDispatchStatus.capacity);
    }
    final additions = [
      for (final rule in matched)
        AutomationDraft._(
          id: _key([key, rule.id]),
          event: event,
          ruleId: rule.id,
          ruleName: rule.name,
          action: rule.action,
          createdAt: clock,
        ),
    ];
    return AutomationDispatch._(
      AutomationData._(
        rules: rules,
        drafts: [...drafts, ...additions],
        receipts: [
          ...recent,
          _AutomationReceipt(key, event.occurredAt, event.sourceRevision),
        ],
        enabledSince: enabledSince,
        lastDispatchAt: clock,
      ),
      AutomationDispatchStatus.queued,
      additions,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabledSince': enabledSince?.toIso8601String(),
    'lastDispatchAt': lastDispatchAt?.toIso8601String(),
    'rules': [for (final rule in rules) rule.toJson()],
    'drafts': [for (final draft in drafts) draft.toJson()],
    'receipts': [for (final receipt in _receipts.values) receipt.toJson()],
  };

  String encode() => jsonEncode(toJson());
}
