import 'dart:convert';

import '../capture_text.dart';
import 'capture_models.dart';
import 'task_category_hint.dart';

export 'capture_models.dart';

part 'capture_validation.dart';
part 'capture_enrichment.dart';

final _whitespace = RegExp(r'\s+');
final _separators = RegExp(
  r'[\r\n;•]+|(?:,\s*)?\s*\b(?:and\s+then|and|then|also|but)\b\s+|,\s+',
  caseSensitive: false,
);
final _kindPrefix = RegExp(
  r'^(?:(?:add|create|log)\s+(?:an?\s+)?)?'
  r'(task|to[- ]?do|(?:calendar\s+)?event|note(?:\s+to\s+self)?|workout|meal)'
  r'(?:\s*:\s*|\s+[-–—]\s+|\s+|$)',
  caseSensitive: false,
);
final _scopePrefix = RegExp(
  r'^(?:(?:category|space|mode)\s+([^:]+):|(?:in|for)\s+([^,:]+)[:,])\s*',
  caseSensitive: false,
);
final _commaScope = RegExp(r'^(?:in|for)\s+[^,:]+$', caseSensitive: false);
final _kindScopePrefix = RegExp(
  r'^(task|event|note(?:\s+to\s+self)?|workout|meal)\s+(?:in|for)\s+([^:]+):\s*',
  caseSensitive: false,
);
final _scopeKindPrefix = RegExp(
  r'^([^:]+?)\s+(task|event|note(?:\s+to\s+self)?|workout|meal):\s*',
  caseSensitive: false,
);
final _spokenNoteKindScope = RegExp(
  r'^(?:(?:add|create)\s+(?:an?\s+)?)?'
  r'(note(?:\s+to\s+self)?)\s+(?:for|in)\s+([^.;,:\r\n]+?)\s*(?:[.,:]\s*|$)',
  caseSensitive: false,
);
final _spokenNoteScopeKind = RegExp(
  r'^for\s+(?:(?:an?|the)\s+)?([^.;,:\r\n]+?)\s+'
  r'(note(?:\s+to\s+self)?)\s*(?:[.,:]\s*|$)',
  caseSensitive: false,
);
final _hashtag = RegExp(r'\s+#([\p{L}\p{M}\p{N}_-]+)\.?$', unicode: true);
final _spaceSuffix = RegExp(
  r'\s+in\s+(?:the\s+)?([^;\r\n:#]+)\s+(?:space|category|mode)\.?$',
  caseSensitive: false,
);
final _scopeConnector = RegExp(r'\s+(?:for|in)\s+', caseSensitive: false);
final _hardSeparator = RegExp(r'[\r\n;•]');
final _taskPhrase = RegExp(
  r'^(?:(?:i\s+)?(?:need|have)\s+to|remind\s+me\s+to|remember\s+to)\s+',
  caseSensitive: false,
);
final _taskVerb = RegExp(
  r'^(?:buy|call|check|choose|draft|email|finish|follow\s+up|order|pick\s+up|'
  r'find|go\s+for\s+(?:a\s+)?(?:run|jog)|make|prepare|read|research|return|review|send|submit|take|update|write)\b',
  caseSensitive: false,
);
final _eventPhrase = RegExp(
  r'^(?:schedule|book|plan\s+an?\s+event)\s+',
  caseSensitive: false,
);
final _meetingPhrase = RegExp(
  r'^(?:meet(?:ing)?|appointment|call\s+with)\b',
  caseSensitive: false,
);
final _notePhrase = RegExp(
  r'^(?:write\s+(?:a\s+)?note|note\s+that)\s*:?[ \t]*',
  caseSensitive: false,
);
final _loggedExercise = RegExp(
  r'^(?:(?:after|following)\s+.{1,100}?[ ,]+)?(?:(?:i\s+)?did\s+(?:the\s+)?|(?:i\s+)?logged\s+(?:the\s+)?)(?!not\b).{0,45}?\b(?:treadmill|bench press|pull[- ]?ups?|squats?|cable row|dips|deadlifts?)\b',
  caseSensitive: false,
);
final _loggedStretch = RegExp(
  r'^(?:(?:after|following)\s+.{1,100}?[ ,]+)?i\s+stretched[.!]?$',
  caseSensitive: false,
);
final _mealPhrase = RegExp(r'^i\s+ate\s+', caseSensitive: false);
final _completion = RegExp(
  r'^mark\s+(.+?)\s+(?:as\s+)?(?:done|complete)\s*[.!]?\s*$',
  caseSensitive: false,
);
final _markPrefix = RegExp(r'^mark\s+', caseSensitive: false);
final _rejectedCommand = RegExp(
  r'^(?:(?:(?:i\s+)?did\s+not|(?:i\s+)?didn[\x27’]t|do\s+not|don[\x27’]t|never)\b|'
  r'(?:delete|remove|erase|reschedule|move|overwrite|ignore\s+previous|mark)\b)',
  caseSensitive: false,
);
final _numericDate = RegExp(
  r'\b(?:on|by|due(?:\s+on)?)\s+(\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)\b'
  r'|\s(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s*[.!]?$',
  caseSensitive: false,
);
final _dateCue = RegExp(
  r'\b(?:due(?:\s+(?:on|by))?\s+|by\s+|on\s+)(?:tomorrow|today|yesterday|'
  r'next\s+\w+|this\s+\w+|\d{1,4}[-/]|(?:mon|tue|wed|thu|fri|sat|sun)\w*)\b',
  caseSensitive: false,
);
final _clockCue = RegExp(
  r'\b(?:\d{1,2}:\d{2}|\d{1,2}\s*[ap]\.?m\.?|at\s+(?:noon|midnight))\b',
  caseSensitive: false,
);
final _uncertainTime = RegExp(
  r'\b(?:daylight\s+saving|clocks\s+(?:go|move)\s+(?:back|forward)|DST)\b'
  r'|\b(?:\d{1,2}:\d{2}|\d{1,2}\s*[ap]\.?m\.?)\s+(?:UTC|GMT|BST|EST|EDT|CET|CEST|PST|PDT)\b',
  caseSensitive: false,
);

/// Interprets supported, explicit capture language without mutating any record.
CaptureReview interpretCapture(CaptureInput input) {
  final source = _Slice(input.text, 0, input.text.length).trim();
  if (source.start == source.end) {
    return CaptureReview(
      input: input,
      issues: const [
        CaptureIssue(
          CaptureIssueCode.emptyInput,
          'Enter something to capture.',
        ),
      ],
    );
  }
  final names = _CategoryNames(input.context.categories);
  final proposals = <CaptureProposal>[];
  final issues = <CaptureIssue>[];
  for (final clause in _split(source, names)) {
    final scope = _readScope(clause, names);
    final lead = _readLead(scope.body, forced: scope.forcedKind);
    if (lead == null || lead.blocked) {
      issues.add(
        CaptureIssue(
          lead?.blocked == true
              ? CaptureIssueCode.unsupportedCommand
              : CaptureIssueCode.unrecognizedIntent,
          lead?.blocked == true
              ? 'Use the record’s own controls for this action.'
              : 'Choose a task, event, note, workout, or meal for this text.',
          span: clause.span,
        ),
      );
      issues.addAll(scope.issues);
      continue;
    }
    final result = _makeProposal(input, clause, lead, scope, names);
    if (result case final CaptureProposal proposal) {
      proposals.add(proposal);
    } else {
      issues.addAll(scope.issues);
      issues.add(result as CaptureIssue);
    }
  }
  if (proposals.isEmpty && issues.isEmpty) {
    issues.add(
      CaptureIssue(
        CaptureIssueCode.unrecognizedIntent,
        'Choose an item to capture.',
        span: source.span,
      ),
    );
  }
  return CaptureReview(input: input, proposals: proposals, issues: issues);
}

class _Slice {
  const _Slice(this.source, this.start, this.end);

  final String source;
  final int start;
  final int end;

  String get text => source.substring(start, end);
  CaptureSpan get span => CaptureSpan(start, end);

  _Slice trim() {
    final original = text;
    final leading = original.length - original.trimLeft().length;
    return _Slice(
      source,
      start + leading,
      start + original.trimRight().length,
    )._ordered();
  }

  _Slice _ordered() => start <= end ? this : _Slice(source, start, start);

  _Slice skip(int count) => _Slice(source, start + count, end).trim();
  _Slice take(int count) => _Slice(source, start, start + count).trim();
}

class _CategoryNames {
  _CategoryNames(Map<String, String> categories) {
    for (final entry in categories.entries) {
      for (final value in {_normalize(entry.key), _normalize(entry.value)}) {
        if (value.isNotEmpty) {
          (_ids[value] ??= {}).add(entry.key);
        }
      }
    }
  }

  final _ids = <String, Set<String>>{};

  Set<String> resolve(String label) => _ids[_normalize(label)] ?? const {};
}

String _normalize(String text) =>
    text.trim().toLowerCase().replaceAll(_whitespace, ' ');

class _Scope {
  const _Scope({
    required this.body,
    this.forcedKind,
    this.category,
    this.categorySpan,
    this.issues = const [],
  });

  final _Slice body;
  final String? forcedKind;
  final String? category;
  final CaptureSpan? categorySpan;
  final List<CaptureIssue> issues;
}

_Scope _readScope(_Slice clause, _CategoryNames names) {
  var body = clause;
  String? forcedKind;
  final marks = <({String label, CaptureSpan span})>[];

  void addMark(RegExpMatch match, int group, {int? beforeGroup}) {
    final text = match[group]!;
    final matched = match[0]!;
    final suffix = beforeGroup == null ? null : match[beforeGroup]!;
    final limit = suffix == null ? matched.length : matched.lastIndexOf(suffix);
    final at =
        body.start +
        match.start +
        matched.substring(0, limit).lastIndexOf(text);
    marks.add((label: text, span: CaptureSpan(at, at + text.length)));
  }

  // Two leading scopes are sufficient to recognise and flag a conflict.
  for (var index = 0; index < 2; index++) {
    final text = body.text;
    if (_kindScopePrefix.firstMatch(text) case final match?) {
      forcedKind ??= match[1];
      addMark(match, 2);
      body = body.skip(match.end);
    } else if (_spokenNoteKindScope.firstMatch(text) case final match?
        when names.resolve(match[2]!).isNotEmpty) {
      forcedKind ??= match[1];
      addMark(match, 2);
      body = body.skip(match.end);
    } else if (_spokenNoteScopeKind.firstMatch(text) case final match?
        when names.resolve(match[1]!).isNotEmpty) {
      forcedKind ??= match[2];
      addMark(match, 1, beforeGroup: 2);
      body = body.skip(match.end);
    } else if (_scopePrefix.firstMatch(text) case final match?) {
      addMark(match, match[1] == null ? 2 : 1);
      body = body.skip(match.end);
    } else if (_scopeKindPrefix.firstMatch(text) case final match?
        when names.resolve(match[1]!).isNotEmpty) {
      forcedKind ??= match[2];
      addMark(match, 1, beforeGroup: 2);
      body = body.skip(match.end);
    } else {
      final colon = text.indexOf(':');
      if (colon <= 0 || names.resolve(text.substring(0, colon)).isEmpty) {
        break;
      }
      marks.add((
        label: text.substring(0, colon),
        span: CaptureSpan(body.start, body.start + colon),
      ));
      body = body.skip(colon + 1);
    }
  }

  for (var index = 0; index < 2; index++) {
    final text = body.text;
    final suffix = _hashtag.firstMatch(text) ?? _spaceSuffix.firstMatch(text);
    if (suffix != null && _outsideQuotes(text, suffix.start)) {
      addMark(suffix, 1);
      body = body.take(suffix.start);
      continue;
    }
    final connector = _scopeConnector.allMatches(text).lastOrNull;
    if (connector == null || !_outsideQuotes(text, connector.start)) break;
    final label = text
        .substring(connector.end)
        .replaceFirst(RegExp(r'\.$'), '');
    if (names.resolve(label).isEmpty) break;
    marks.add((
      label: label,
      span: CaptureSpan(
        body.start + connector.end,
        body.start + connector.end + label.length,
      ),
    ));
    body = body.take(connector.start);
  }

  final ids = <String>{};
  final issues = <CaptureIssue>[];
  for (final mark in marks) {
    final options = names.resolve(mark.label);
    if (options.isEmpty) {
      issues.add(
        CaptureIssue(
          CaptureIssueCode.unknownCategory,
          'Choose an existing category for “${mark.label.trim()}”.',
          span: mark.span,
        ),
      );
    }
    ids.addAll(options);
  }
  if (ids.length > 1) {
    issues.add(
      CaptureIssue(
        CaptureIssueCode.ambiguousCategory,
        'Choose one category for this item.',
        span: clause.span,
      ),
    );
  }
  return _Scope(
    body: body,
    forcedKind: forcedKind,
    category: ids.length == 1 && issues.isEmpty ? ids.single : null,
    categorySpan: marks.firstOrNull?.span,
    issues: issues,
  );
}

class _Lead {
  const _Lead(this.kind, this.body, {this.noteToSelf = false});
  const _Lead.rejected(this.body) : kind = null, noteToSelf = false;

  final CaptureIntentKind? kind;
  final _Slice body;
  final bool noteToSelf;
  bool get blocked => kind == null;
}

_Lead _namedLead(String label, _Slice body) {
  final name = _normalize(label);
  if (name.startsWith('note')) {
    return _Lead(
      CaptureIntentKind.note,
      body,
      noteToSelf: name == 'note to self',
    );
  }
  return _Lead(switch (name) {
    'event' || 'calendar event' => CaptureIntentKind.event,
    'workout' => CaptureIntentKind.workout,
    'meal' => CaptureIntentKind.meal,
    _ => CaptureIntentKind.task,
  }, body);
}

_Lead? _readLead(_Slice body, {String? forced, bool impliedEvent = true}) {
  final text = body.text;
  if (forced != null) return _namedLead(forced, body);
  if (_kindPrefix.firstMatch(text) case final match?) {
    return _namedLead(match[1]!, body.skip(match.end));
  }
  if (_completion.firstMatch(text) case final match?) {
    final content = match[1]!;
    final start = body.start + _markPrefix.firstMatch(text)!.end;
    return _Lead(
      CaptureIntentKind.completeTask,
      _Slice(body.source, start, start + content.length).trim(),
    );
  }
  if (_rejectedCommand.hasMatch(text)) return _Lead.rejected(body);
  if (_notePhrase.firstMatch(text) case final match?) {
    return _Lead(CaptureIntentKind.note, body.skip(match.end));
  }
  if (_eventPhrase.firstMatch(text) case final match?) {
    return _Lead(CaptureIntentKind.event, body.skip(match.end));
  }
  if (_mealPhrase.firstMatch(text) case final match?) {
    return _Lead(CaptureIntentKind.meal, body.skip(match.end));
  }
  if (_loggedExercise.hasMatch(text) || _loggedStretch.hasMatch(text)) {
    return _Lead(CaptureIntentKind.workout, body);
  }
  if (_taskPhrase.firstMatch(text) case final match?) {
    return _Lead(CaptureIntentKind.task, body.skip(match.end));
  }
  if (_taskVerb.hasMatch(text) ||
      taskCategoryHint(text, const {'gym', 'study', 'work'}) != null) {
    return _Lead(CaptureIntentKind.task, body);
  }
  if (_meetingPhrase.hasMatch(text) ||
      (impliedEvent && _clockCue.hasMatch(text))) {
    return _Lead(CaptureIntentKind.event, body);
  }
  return null;
}

Iterable<_Slice> _split(_Slice source, _CategoryNames names) sync* {
  final text = source.text;
  var from = 0;
  bool? noteClause;
  final quote = _Quotes(text);
  for (final match in _separators.allMatches(text)) {
    if (quote.insideAt(match.start)) continue;
    final hard = match[0]!.contains(_hardSeparator);
    var limit = (match.end + 256).clamp(0, text.length);
    if (limit < text.length && (text.codeUnitAt(limit) & 0xfc00) == 0xdc00) {
      limit++;
    }
    final nextHard = _hardSeparator.firstMatch(
      text.substring(match.end, limit),
    );
    if (nextHard != null) limit = match.end + nextHard.start;
    final next = _Slice(
      source.source,
      source.start + match.end,
      source.start + limit,
    ).trim();
    final scope = _readScope(next, names);
    final nextLead = _readLead(
      scope.body,
      forced: scope.forcedKind,
      impliedEvent: hard,
    );
    if (!hard && nextLead == null) continue;
    final clause = _Slice(
      source.source,
      source.start + from,
      source.start + match.start,
    ).trim();
    if (match[0]!.startsWith(',')) {
      if (_commaScope.hasMatch(clause.text)) continue;
      final previous = _readScope(clause, names);
      if (previous.forcedKind != null && previous.body.text.isEmpty) continue;
    }
    if (nextLead == null) {
      if (noteClause == null) {
        final previous = _readScope(clause, names);
        noteClause =
            _readLead(previous.body, forced: previous.forcedKind)?.kind ==
            CaptureIntentKind.note;
      }
      if (noteClause) continue;
    }
    if (clause.start < clause.end) yield clause;
    from = match.end;
    noteClause = null;
  }
  final last = source.skip(from);
  if (last.start < last.end) yield last;
}

class _Quotes {
  _Quotes(this.text);

  final String text;
  int _checked = 0;
  int? _close;

  bool insideAt(int offset) {
    while (_checked < offset) {
      final index = _checked++;
      final code = text.codeUnitAt(index);
      if (_close != null) {
        if (code == 0x5c && (_close == 0x22 || _close == 0x27)) {
          _checked++;
        } else if (_close == code) {
          _close = null;
        }
        continue;
      }
      _close = switch (code) {
        0x22 => 0x22,
        0x201c => 0x201d,
        0x2018 => 0x2019,
        0xab => 0xbb,
        0x27 when index == 0 || ': ([\t\n'.contains(text[index - 1]) => 0x27,
        _ => null,
      };
    }
    return _close != null;
  }
}

bool _outsideQuotes(String text, int offset) => !_Quotes(text).insideAt(offset);

Match? _unquotedMatch(RegExp pattern, String text) {
  final quotes = _Quotes(text);
  return pattern
      .allMatches(text)
      .where((match) => !quotes.insideAt(match.start))
      .firstOrNull;
}

String _unquote(String value) {
  final text = value.trim();
  if (text.length < 2) return text;
  final closes = {'"': '"', "'": "'", '“': '”', '‘': '’', '«': '»'};
  return closes[text[0]] == text[text.length - 1]
      ? text.substring(1, text.length - 1).trim()
      : text;
}

String _title(String value) =>
    _unquote(value).replaceFirst(RegExp(r'[.!]$'), '').trim();

DateTime _day(DateTime civil, [int offset = 0]) =>
    DateTime(civil.year, civil.month, civil.day + offset);

DateTime _wallClock(DateTime civil) => DateTime(
  civil.year,
  civil.month,
  civil.day,
  civil.hour,
  civil.minute,
  civil.second,
);

Object _makeProposal(
  CaptureInput input,
  _Slice clause,
  _Lead lead,
  _Scope scope,
  _CategoryNames names,
) {
  final context = input.context;
  final anchor = _wallClock(context.anchor);
  final body = lead.body;
  final text = body.text;
  final knownCategory =
      lead.kind == CaptureIntentKind.task && scope.categorySpan == null
      ? taskCategoryHint(text, context.categories.keys)
      : null;
  final category = scope.category ?? knownCategory;
  final issues = [...scope.issues];
  final missing = <String>[];
  final evidence = <String, CaptureEvidence>{};
  final focus = context.focusCategory == null
      ? const <String>{}
      : names.resolve(context.focusCategory!);
  final suggested =
      category == null && scope.categorySpan == null && focus.length == 1
      ? focus.single
      : null;

  void addEvidence(
    String field,
    CaptureProvenance provenance, [
    String? literal,
  ]) {
    if (body.start == body.end) return;
    final at = literal == null || literal.isEmpty ? -1 : text.indexOf(literal);
    evidence[field] = CaptureEvidence(
      provenance: provenance,
      span: at < 0
          ? body.span
          : CaptureSpan(body.start + at, body.start + at + literal!.length),
    );
  }

  if (category != null) {
    evidence['category'] = CaptureEvidence(
      provenance: knownCategory == null
          ? CaptureProvenance.explicit
          : CaptureProvenance.derived,
      span: scope.categorySpan ?? body.span,
    );
  } else if (suggested != null) {
    evidence['suggestedCategory'] = const CaptureEvidence(
      provenance: CaptureProvenance.context,
    );
  }

  CaptureDraft draft;
  switch (lead.kind!) {
    case CaptureIntentKind.task:
      final parsed = parseTaskCapture(text, date: anchor, now: anchor);
      var due = parsed.dueDate;
      if (_hasUnresolvedNumericDate(text) ||
          due == null && _unquotedMatch(_dateCue, text) != null) {
        due = null;
        issues.add(_dateIssue(body.span));
      }
      if (_unquotedMatch(_clockCue, text) != null) {
        issues.add(
          CaptureIssue(
            CaptureIssueCode.ambiguousTime,
            'Clarify whether this time is a deadline or a calendar slot.',
            span: body.span,
          ),
        );
      }
      if (due != null) addEvidence('dueDate', CaptureProvenance.derived);
      draft = CaptureTaskDraft(
        title: _title(parsed.title),
        category: category,
        dueDate: due,
      );
    case CaptureIntentKind.event:
      final fallback = _day(anchor);
      final parsed = parseEventCapture(text, date: fallback, now: anchor);
      final dateExplicit =
          parsed.date != fallback ||
          parseEventCapture(text, date: _day(anchor, 1), now: anchor).date ==
              parsed.date;
      var date = dateExplicit ? parsed.date : null;
      if (_hasUnresolvedNumericDate(text)) {
        date = null;
        issues.add(_dateIssue(body.span));
      }
      final unknownZone = _unquotedMatch(_uncertainTime, text) != null;
      if (unknownZone) {
        issues.add(
          CaptureIssue(
            CaptureIssueCode.ambiguousTime,
            'Confirm the event’s local date, time, and timezone.',
            span: body.span,
          ),
        );
      }
      if (parsed.error case final error?) {
        issues.add(
          CaptureIssue(
            CaptureIssueCode.invalidSchedule,
            error,
            span: body.span,
          ),
        );
      }
      final parsedStart = unknownZone || parsed.error != null
          ? null
          : parsed.start;
      final parsedEnd = unknownZone || parsed.error != null ? null : parsed.end;
      final validDate = unknownZone || parsed.error != null ? null : date;
      final start = validDate == null
          ? null
          : parsed.allDay
          ? validDate
          : parsedStart;
      final end = validDate == null
          ? null
          : parsed.allDay
          ? _day(validDate, 1)
          : parsedEnd;
      if (date == null) missing.add('date');
      if (!parsed.allDay && parsedStart == null) missing.add('start');
      if (!parsed.allDay && parsedEnd == null && parsed.duration == null) {
        missing.add('end');
      }
      if (date != null) addEvidence('date', CaptureProvenance.derived);
      if (parsed.allDay) addEvidence('allDay', CaptureProvenance.explicit);
      if (parsedStart != null || start != null) {
        addEvidence('start', CaptureProvenance.derived);
      }
      if (parsedEnd != null || end != null) {
        addEvidence('end', CaptureProvenance.derived);
      }
      if (parsed.duration != null) {
        addEvidence('duration', CaptureProvenance.explicit);
      }
      if (parsed.location != null) {
        addEvidence('location', CaptureProvenance.explicit, parsed.location);
      }
      draft = CaptureEventDraft(
        title: _title(parsed.title),
        category: category,
        date: date,
        start: start,
        end: end,
        startTime: parsedStart == null
            ? null
            : CaptureClock(parsedStart.hour, parsedStart.minute),
        endTime: parsedEnd == null
            ? null
            : CaptureClock(parsedEnd.hour, parsedEnd.minute),
        duration: parsed.duration,
        allDay: parsed.allDay,
        location: parsed.location,
      );
    case CaptureIntentKind.note:
      final content = _unquote(text);
      final newline = content.indexOf('\n');
      final title = newline < 0
          ? content
          : content.substring(0, newline).trim();
      final note = newline < 0 ? '' : content.substring(newline + 1).trim();
      if (note.isNotEmpty) {
        addEvidence('body', CaptureProvenance.explicit, note);
      }
      if (lead.noteToSelf) {
        evidence['noteToSelf'] = CaptureEvidence(
          provenance: CaptureProvenance.explicit,
          span: clause.span,
        );
      }
      draft = CaptureNoteDraft(
        title: title,
        category: category,
        body: note,
        noteToSelf: lead.noteToSelf,
      );
    case CaptureIntentKind.workout:
      final details = _unquote(text);
      addEvidence('details', CaptureProvenance.explicit, details);
      draft = CaptureWorkoutDraft(
        title: details,
        category: category,
        details: details,
      );
    case CaptureIntentKind.meal:
      final description = _unquote(text);
      addEvidence('description', CaptureProvenance.explicit, description);
      draft = CaptureMealDraft(
        title: description,
        category: category,
        description: description,
      );
    case CaptureIntentKind.completeTask:
      final target = _resolveCompletion(context, body, category);
      if (target is CaptureIssue) return target;
      final record = target as CaptureRecordRef;
      evidence['targetId'] = CaptureEvidence(
        provenance: CaptureProvenance.context,
        span: body.span,
      );
      evidence['expectedRevision'] = const CaptureEvidence(
        provenance: CaptureProvenance.context,
      );
      draft = CaptureCompleteTaskDraft(
        title: record.title,
        category: category,
        targetId: record.id,
        expectedRevision: record.revision,
        selectedReference: _isSelectedReference(body.text),
      );
  }

  if (draft.title.isEmpty) {
    missing.insert(0, 'title');
  } else {
    addEvidence(
      'title',
      draft is CaptureCompleteTaskDraft
          ? CaptureProvenance.context
          : CaptureProvenance.explicit,
      draft.title,
    );
  }
  return CaptureProposal(
    draft: draft,
    span: clause.span,
    evidence: evidence,
    missingRequired: missing,
    suggestedCategory: draft is CaptureCompleteTaskDraft ? null : suggested,
    issues: issues,
  );
}

bool _hasUnresolvedNumericDate(String text) {
  final quotes = _Quotes(text);
  return _numericDate
      .allMatches(text)
      .any(
        (match) =>
            !quotes.insideAt(match.start) &&
            parseCaptureNumericDate((match[1] ?? match[2])!) == null,
      );
}

CaptureIssue _dateIssue(CaptureSpan span) => CaptureIssue(
  CaptureIssueCode.invalidDate,
  'Use a named month or a full ISO date.',
  span: span,
);

Object _resolveCompletion(
  CaptureContext context,
  _Slice body,
  String? category,
) {
  final target = _unquote(body.text);
  final selected = _isSelectedReference(target);
  final matches = [
    for (final record in context.records)
      if (selected
          ? record.id == context.selectedRecordId
          : _normalize(record.title) == _normalize(target))
        if (category == null || record.category == category) record,
  ];
  if (matches.isEmpty) {
    return CaptureIssue(
      CaptureIssueCode.missingTarget,
      'Select a task or enter its exact title.',
      span: body.span,
    );
  }
  if (matches.length != 1) {
    return CaptureIssue(
      CaptureIssueCode.ambiguousTarget,
      'Choose which task to mark done.',
      span: body.span,
    );
  }
  final record = matches.single;
  if (record.kind != CaptureIntentKind.task ||
      record.completed ||
      record.archived) {
    return CaptureIssue(
      CaptureIssueCode.unavailableTarget,
      'Choose an open task.',
      span: body.span,
    );
  }
  return record;
}

bool _isSelectedReference(String target) => {
  'it',
  'this',
  'that',
  'the selected task',
}.contains(_normalize(_unquote(target)));
