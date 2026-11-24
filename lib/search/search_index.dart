import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'search_models.dart';
import 'search_text.dart';

const _title = 1;
const _body = 2;
const _category = 4;
const _everyField = _title | _body | _category;
const _postingShift = 3;
const _prefixLimit = 128;
const _queryTermLimit = 32;

typedef _Term = ({String value, int fields});

typedef _Query = ({
  List<_Term> terms,
  Set<SearchRecordKind> kinds,
  bool impossible,
});

final _querySyntax = RegExp(
  r'(?:(title|body|category|type):)?(?:"([^"]*)"|([^\s"]+))',
  caseSensitive: false,
);

_Query _parse(String input) {
  final terms = <_Term>{};
  final kinds = <SearchRecordKind>{};
  var impossible = false;
  final source = input.length <= 4000 ? input : input.substring(0, 4000);
  for (final match in _querySyntax.allMatches(source)) {
    final modifier = match.group(1)?.toLowerCase();
    final value = match.group(2) ?? match.group(3) ?? '';
    if (modifier == 'type') {
      final kind = SearchRecordKind.values
          .asNameMap()[value.trim().toLowerCase()];
      if (kind == null) {
        impossible = true;
      } else {
        kinds.add(kind);
      }
      continue;
    }
    if (terms.length >= _queryTermLimit) continue;
    final fields = switch (modifier) {
      'title' => _title,
      'body' => _body,
      'category' => _category,
      _ => _everyField,
    };
    for (final token in searchTokens(value)) {
      if (token.value.isNotEmpty) {
        terms.add((value: token.value, fields: fields));
      }
      if (terms.length >= _queryTermLimit) break;
    }
  }
  return (terms: terms.toList(), kinds: kinds, impossible: impossible);
}

class SearchIndex {
  SearchIndex._(
    this._documents,
    this._keyPositions,
    this._titlePhrases,
    this._postings,
    this._vocabulary,
    this.kinds,
    this.pinnedKeys,
  );

  factory SearchIndex.build(Iterable<SearchDocument> source) {
    final documents = <SearchDocument>[];
    final positions = <SearchKey, int>{};
    final titles = <String>[];
    final postings = <String, List<int>>{};
    final kinds = <SearchRecordKind>{};
    final pinned = <SearchKey>[];
    for (final document in source) {
      if (positions.containsKey(document.key)) continue;
      final index = documents.length;
      documents.add(document);
      positions[document.key] = index;
      kinds.add(document.key.kind);
      if (document.pinned) pinned.add(document.key);

      final titleTerms = searchTokens(document.title)
          .map((token) => token.value)
          .toList();
      titles.add(titleTerms.join(' '));
      final fields = <String, int>{
        for (final token in titleTerms)
          if (token.isNotEmpty) token: _title,
      };
      void indexText(String value, int flag) {
        for (final token in searchTokens(value)) {
          final key = token.value;
          if (key.isNotEmpty) fields[key] = (fields[key] ?? 0) | flag;
        }
      }

      indexText(document.body, _body);
      if (document.categoryId case final value?) indexText(value, _category);
      if (document.categoryName case final value?) indexText(value, _category);
      for (final term in fields.entries) {
        (postings[term.key] ??= []).add((index << _postingShift) | term.value);
      }
    }
    pinned.sort(
      (a, b) =>
          _compareDocument(documents[positions[a]!], documents[positions[b]!]),
    );
    return SearchIndex._(
      List.unmodifiable(documents),
      Map.unmodifiable(positions),
      List.unmodifiable(titles),
      Map.unmodifiable(
        postings.map(
          (term, entries) => MapEntry(term, Uint32List.fromList(entries)),
        ),
      ),
      List.unmodifiable(postings.keys.toList()..sort()),
      Set.unmodifiable(kinds),
      List.unmodifiable(pinned),
    );
  }

  final List<SearchDocument> _documents;
  final Map<SearchKey, int> _keyPositions;
  final List<String> _titlePhrases;
  final Map<String, Uint32List> _postings;
  final List<String> _vocabulary;
  final Set<SearchRecordKind> kinds;
  final List<SearchKey> pinnedKeys;

  int get documentCount => _documents.length;

  SearchDocument? document(SearchKey key) {
    final slot = _keyPositions[key];
    return slot == null ? null : _documents[slot];
  }

  bool includes(
    SearchDocument document,
    WorkspaceSearchQuery query, {
    Set<SearchKey> favourites = const {},
  }) =>
      (query.kinds?.contains(document.key.kind) ?? true) &&
      (query.allowedCategories?.contains(document.categoryId) ?? true) &&
      (!query.favouritesOnly || favourites.contains(document.key));

  List<SearchHit> search(
    WorkspaceSearchQuery query, {
    int limit = 50,
    Set<SearchKey> favourites = const {},
  }) {
    if (limit < 1) return const [];
    final maximum = math.min(limit, 100);
    final parsed = _parse(query.text);
    if (parsed.impossible ||
        (parsed.terms.isEmpty &&
            parsed.kinds.isEmpty &&
            query.text.trim().isNotEmpty)) {
      return const [];
    }
    bool allowed(int slot) {
      final document = _documents[slot];
      return (parsed.kinds.isEmpty ||
              parsed.kinds.contains(document.key.kind)) &&
          includes(document, query, favourites: favourites);
    }

    final parsedTerms = parsed.terms.toList()
      ..sort(
        (a, b) => (_postings[a.value]?.length ?? 0).compareTo(
          _postings[b.value]?.length ?? 0,
        ),
      );
    final scored = parsedTerms.isEmpty
        ? null
        : _scoreTerms(parsedTerms, allowed);
    if (scored?.slots.isEmpty ?? false) return const [];

    final phrase = parsed.terms.every((term) => term.fields & _title != 0)
        ? parsed.terms.map((term) => term.value).join(' ')
        : '';
    int compare(({int slot, int score}) a, ({int slot, int score}) b) {
      final compared = b.score.compareTo(a.score);
      if (compared != 0) return compared;
      final docs = _compareDocument(_documents[a.slot], _documents[b.slot]);
      return docs != 0 ? docs : a.slot.compareTo(b.slot);
    }

    final ranking = SplayTreeSet<({int slot, int score})>(compare);
    Iterable<int> unranked() sync* {
      for (var slot = 0; slot < _documents.length; slot++) {
        if (allowed(slot)) yield slot;
      }
    }

    for (final slot in scored?.slots ?? unranked()) {
      final document = _documents[slot];
      final normalizedTitle = _titlePhrases[slot];
      var value = scored?.scores[slot] ?? 0;
      if (phrase.isNotEmpty) {
        if (normalizedTitle == phrase) {
          value += 38;
        } else if (normalizedTitle.startsWith(phrase)) {
          value += 16;
        }
      }
      if (document.pinned) value += 2;
      if (favourites.contains(document.key)) value += 2;
      final candidate = (slot: slot, score: value);
      if (ranking.length == maximum && compare(candidate, ranking.last) >= 0) {
        continue;
      }
      ranking.add(candidate);
      if (ranking.length > maximum) ranking.remove(ranking.last);
    }
    final terms = {
      for (final term in parsed.terms)
        if (term.fields & _body != 0) term.value,
    };
    return [
      for (final ranked in ranking)
        SearchHit(
          document: _documents[ranked.slot],
          score: ranked.score,
          snippet: searchSnippet(_documents[ranked.slot].body, match: terms),
        ),
    ];
  }

  ({List<int> slots, Uint16List scores}) _scoreTerms(
    List<_Term> terms,
    bool Function(int slot) allowed,
  ) {
    final firstStart = _firstVocabularyMatch(terms.first.value);
    if (firstStart == null) return (slots: const [], scores: Uint16List(0));
    final scores = Uint16List(_documents.length);
    final matches = Uint16List(_documents.length);
    var slots = <int>[];
    for (final (position, term) in terms.indexed) {
      final first = position == 0;
      final prior = slots;
      slots = <int>[];
      for (final key in _matchingTermKeys(
        term.value,
        first ? firstStart : null,
      )) {
        final postings = _postings[key]!;
        final bonus = key == term.value ? 5 : 1;
        void score(int slot, int packed) {
          final fields = packed & _everyField & term.fields;
          if (fields == 0) return;
          final previous = matches[slot];
          if (previous == 0) slots.add(slot);
          final candidate = _fieldScore(fields) + bonus;
          if (candidate > previous) matches[slot] = candidate;
        }

        if (!first && prior.length * 18 < postings.length) {
          for (final slot in prior) {
            final value = _findPosting(postings, slot);
            if (value != null) score(slot, value);
          }
        } else {
          for (final value in postings) {
            final slot = value >> _postingShift;
            if (first ? allowed(slot) : scores[slot] != 0) score(slot, value);
          }
        }
      }
      if (slots.isEmpty) break;
      for (final slot in prior) {
        if (matches[slot] == 0) scores[slot] = 0;
      }
      for (final slot in slots) {
        scores[slot] += matches[slot];
        matches[slot] = 0;
      }
    }
    return (slots: slots, scores: scores);
  }

  int? _firstVocabularyMatch(String prefix) {
    var start = 0;
    var end = _vocabulary.length;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (_vocabulary[middle].compareTo(prefix) < 0) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    return start < _vocabulary.length && _vocabulary[start].startsWith(prefix)
        ? start
        : null;
  }

  Iterable<String> _matchingTermKeys(String prefix, int? start) sync* {
    final first = start ?? _firstVocabularyMatch(prefix);
    if (first == null) return;
    final end = math.min(_vocabulary.length, first + _prefixLimit);
    for (var index = first; index < end; index++) {
      final key = _vocabulary[index];
      if (!key.startsWith(prefix)) break;
      yield key;
    }
  }
}

int? _findPosting(Uint32List postings, int slot) {
  var start = 0;
  var end = postings.length;
  while (start < end) {
    final middle = (start + end) ~/ 2;
    final value = postings[middle];
    final candidate = value >> _postingShift;
    if (candidate == slot) return value;
    if (candidate < slot) {
      start = middle + 1;
    } else {
      end = middle;
    }
  }
  return null;
}

int _fieldScore(int flags) => switch (flags) {
  int value when value & _title != 0 => 15,
  int value when value & _category != 0 => 8,
  _ => 4,
};

int _compareDocument(SearchDocument first, SearchDocument second) {
  final a = first.date;
  final b = second.date;
  if (a != null && b != null) {
    final compared = b.compareTo(a);
    if (compared != 0) return compared;
  } else if ((a == null) != (b == null)) {
    return a == null ? 1 : -1;
  }
  final kind = first.key.kind.index.compareTo(second.key.kind.index);
  return kind == 0 ? first.key.id.compareTo(second.key.id) : kind;
}

String searchSnippet(String body, {Set<String> match = const {}}) {
  if (body.isEmpty) return '';
  const length = 156;
  const scan = 12000;
  var first = 0;
  if (match.isNotEmpty) {
    final window = body.length > scan
        ? body.substring(0, _safeEnd(body, scan))
        : body;
    for (final token in searchTokens(window)) {
      if (match.any((term) => token.value.startsWith(term))) {
        first = math.max(0, token.start - 44);
        break;
      }
    }
  }
  if (first > 0) {
    final code = body.codeUnitAt(first);
    if (code >= 0xdc00 && code <= 0xdfff) first++;
  }
  final last = _safeEnd(body, math.min(body.length, first + length));
  final content = body
      .substring(first, last)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (content.isEmpty) return '';
  return '${first == 0 ? '' : '…'}$content${last == body.length ? '' : '…'}';
}

int _safeEnd(String value, int end) {
  if (end < value.length && end > 0) {
    final last = value.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) return end - 1;
  }
  return end;
}
