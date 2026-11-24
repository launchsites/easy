/// Read-only input captured at one source and workspace revision.
class CaptureInput {
  const CaptureInput({
    required this.id,
    required this.revision,
    required this.text,
    required this.context,
  });

  final String id;
  final int revision;
  final String text;
  final CaptureContext context;
}

const _defaultCategories = {
  'work': 'Work',
  'personal': 'Personal',
  'study': 'Study',
  'gym': 'Gym',
  'health': 'Health',
};

class CaptureContext {
  CaptureContext({
    required this.anchor,
    this.revision = 0,
    this.focusCategory,
    Map<String, String>? categories,
    List<CaptureRecordRef> records = const [],
    this.selectedRecordId,
    this.timezone,
  }) : categories = Map.unmodifiable(categories ?? _defaultCategories),
       records = List.unmodifiable(records);

  /// The capture's local wall-clock reading supplied by the caller.
  /// Its calendar components, rather than a host-timezone conversion, anchor
  /// relative dates. [timezone] is review context, not an offset resolver.
  final DateTime anchor;
  final String? timezone;
  final int revision;
  final String? focusCategory;
  final Map<String, String> categories;
  final List<CaptureRecordRef> records;
  final String? selectedRecordId;
}

enum CaptureIntentKind { task, event, note, workout, meal, completeTask }

class CaptureRecordRef {
  const CaptureRecordRef({
    required this.id,
    required this.kind,
    required this.title,
    required this.revision,
    this.category,
    this.completed = false,
    this.archived = false,
  });

  final String id;
  final CaptureIntentKind kind;
  final String title;
  final int revision;
  final String? category;
  final bool completed;
  final bool archived;
}

/// Offsets are UTF-16 code units, matching Dart's String.substring.
class CaptureSpan {
  const CaptureSpan(this.start, this.end);

  final int start;
  final int end;

  bool isWithin(String text) =>
      0 <= start &&
      start < end &&
      end <= text.length &&
      !_splitsSurrogatePair(text, start) &&
      !_splitsSurrogatePair(text, end);

  String textFrom(String text) => text.substring(start, end);

  static bool _splitsSurrogatePair(String text, int offset) {
    if (offset == 0 || offset == text.length) return false;
    final previous = text.codeUnitAt(offset - 1);
    final next = text.codeUnitAt(offset);
    return previous >= 0xd800 &&
        previous <= 0xdbff &&
        next >= 0xdc00 &&
        next <= 0xdfff;
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureSpan && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

enum CaptureProvenance { explicit, derived, context }

class CaptureEvidence {
  const CaptureEvidence({required this.provenance, this.span});

  final CaptureProvenance provenance;
  final CaptureSpan? span;
}

enum CaptureIssueCode {
  emptyInput,
  unrecognizedIntent,
  unsupportedCommand,
  unknownCategory,
  ambiguousCategory,
  invalidDate,
  ambiguousTime,
  invalidSchedule,
  missingTarget,
  ambiguousTarget,
  unavailableTarget,
  staleSource,
  staleContext,
  invalidModelOutput,
}

class CaptureIssue {
  const CaptureIssue(this.code, this.message, {this.span});

  final CaptureIssueCode code;
  final String message;
  final CaptureSpan? span;
}

sealed class CaptureDraft {
  const CaptureDraft({required this.title, this.category});

  final String title;
  final String? category;
  CaptureIntentKind get kind;
}

class CaptureTaskDraft extends CaptureDraft {
  const CaptureTaskDraft({required super.title, super.category, this.dueDate});

  final DateTime? dueDate;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.task;
}

class CaptureClock {
  const CaptureClock(this.hour, this.minute);

  final int hour;
  final int minute;
}

class CaptureEventDraft extends CaptureDraft {
  const CaptureEventDraft({
    required super.title,
    super.category,
    this.date,
    this.start,
    this.end,
    this.startTime,
    this.endTime,
    this.duration,
    this.allDay = false,
    this.location,
  });

  final DateTime? date;
  final DateTime? start;
  final DateTime? end;
  final CaptureClock? startTime;
  final CaptureClock? endTime;
  final Duration? duration;
  final bool allDay;
  final String? location;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.event;
}

class CaptureNoteDraft extends CaptureDraft {
  const CaptureNoteDraft({
    required super.title,
    super.category,
    this.body = '',
    this.noteToSelf = false,
  });

  final String body;
  final bool noteToSelf;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.note;
}

class CaptureWorkoutDraft extends CaptureDraft {
  const CaptureWorkoutDraft({
    required super.title,
    super.category,
    required this.details,
  });

  final String details;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.workout;
}

class CaptureMealDraft extends CaptureDraft {
  const CaptureMealDraft({
    required super.title,
    super.category,
    required this.description,
  });

  final String description;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.meal;
}

class CaptureCompleteTaskDraft extends CaptureDraft {
  const CaptureCompleteTaskDraft({
    required super.title,
    super.category,
    required this.targetId,
    required this.expectedRevision,
    this.selectedReference = false,
  });

  final String targetId;
  final int expectedRevision;
  final bool selectedReference;

  @override
  CaptureIntentKind get kind => CaptureIntentKind.completeTask;
}

class CaptureProposal {
  CaptureProposal({
    required this.draft,
    required this.span,
    Map<String, CaptureEvidence> evidence = const {},
    List<String> missingRequired = const [],
    this.suggestedCategory,
    List<CaptureIssue> issues = const [],
  }) : evidence = Map.unmodifiable(evidence),
       missingRequired = List.unmodifiable(missingRequired),
       issues = List.unmodifiable(issues);

  final CaptureDraft draft;
  final CaptureSpan span;
  final Map<String, CaptureEvidence> evidence;
  final List<String> missingRequired;
  final String? suggestedCategory;
  final List<CaptureIssue> issues;

  bool get isReady => missingRequired.isEmpty && issues.isEmpty;
}

class CaptureReview {
  CaptureReview({
    required this.input,
    List<CaptureProposal> proposals = const [],
    List<CaptureIssue> issues = const [],
  }) : proposals = List.unmodifiable(proposals),
       issues = List.unmodifiable(issues);

  final CaptureInput input;
  final List<CaptureProposal> proposals;
  final List<CaptureIssue> issues;

  /// Checks the source, the caller's workspace revision, and target revisions
  /// immediately before a reviewed proposal leaves the interpretation layer.
  bool isCurrentFor(CaptureInput current) {
    if (input.id != current.id ||
        input.revision != current.revision ||
        input.text != current.text ||
        input.context.revision != current.context.revision ||
        input.context.anchor != current.context.anchor ||
        input.context.timezone != current.context.timezone ||
        input.context.focusCategory != current.context.focusCategory ||
        input.context.selectedRecordId != current.context.selectedRecordId ||
        !_sameCategories(
          input.context.categories,
          current.context.categories,
        )) {
      return false;
    }
    for (final proposal in proposals) {
      if (proposal.draft case final CaptureCompleteTaskDraft completion) {
        final targets = current.context.records.where(
          (record) => record.id == completion.targetId,
        );
        if (targets.length != 1 ||
            targets.single.revision != completion.expectedRevision ||
            targets.single.kind != CaptureIntentKind.task ||
            targets.single.title != completion.title ||
            (completion.category != null &&
                targets.single.category != completion.category) ||
            targets.single.completed ||
            targets.single.archived) {
          return false;
        }
        if (!completion.selectedReference &&
            current.context.records.where((record) {
                  return _recordTitle(record.title) ==
                          _recordTitle(completion.title) &&
                      (completion.category == null ||
                          record.category == completion.category);
                }).length !=
                1) {
          return false;
        }
      }
    }
    return true;
  }

  static bool _sameCategories(
    Map<String, String> before,
    Map<String, String> after,
  ) =>
      before.length == after.length &&
      before.entries.every((entry) => after[entry.key] == entry.value);

  static String _recordTitle(String title) =>
      title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}
