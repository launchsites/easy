part 'search_latin.dart';

typedef SearchToken = ({String value, int start, int end});

final _wordPattern = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
final _foldedLatin = <int, String>{
  for (final group in _latinAccents.entries)
    for (final code in group.value.runes) code: group.key,
  0x00df: 'ss',
  0x00e6: 'ae',
  0x0153: 'oe',
  0x00f8: 'o',
  0x0142: 'l',
  0x0131: 'i',
};

Iterable<SearchToken> searchTokens(String text) sync* {
  for (final match in _wordPattern.allMatches(text)) {
    final start = match.start;
    final end = match.end;
    var pendingStart = start;
    var cursor = start;
    while (cursor < end) {
      final first = text.codeUnitAt(cursor);
      final wide = first >= 0xd800 && first <= 0xdbff && cursor + 1 < end;
      final rune = wide
          ? 0x10000 +
                ((first - 0xd800) << 10) +
                (text.codeUnitAt(cursor + 1) - 0xdc00)
          : first;
      final next = cursor + (wide ? 2 : 1);
      if (_isEastAsian(rune)) {
        if (cursor > pendingStart) {
          yield (
            value: _token(text, pendingStart, cursor),
            start: pendingStart,
            end: cursor,
          );
        }
        yield (
          value: String.fromCharCode(rune).toLowerCase(),
          start: cursor,
          end: next,
        );
        pendingStart = next;
      }
      cursor = next;
    }
    if (pendingStart < end) {
      yield (
        value: _token(text, pendingStart, end),
        start: pendingStart,
        end: end,
      );
    }
  }
}

String _token(String text, int start, int end) {
  const tokenUnits = 96;
  var cut = end;
  if (end - start > tokenUnits) {
    cut = start + tokenUnits;
    final boundary = text.codeUnitAt(cut - 1);
    if (boundary >= 0xd800 && boundary <= 0xdbff) cut--;
  }
  final lower = text.substring(start, cut).toLowerCase();
  var ascii = true;
  for (final code in lower.codeUnits) {
    if (code > 127) {
      ascii = false;
      break;
    }
  }
  if (ascii) return lower;
  final result = StringBuffer();
  var afterLatin = false;
  for (final rune in lower.runes) {
    final folded = _foldedLatin[rune];
    if (folded != null) {
      result.write(folded);
      afterLatin = true;
    } else if (!(afterLatin && rune >= 0x0300 && rune <= 0x036f)) {
      result.writeCharCode(rune);
      afterLatin = rune >= 0x61 && rune <= 0x7a;
    }
  }
  return result.toString();
}

bool _isEastAsian(int rune) =>
    (rune >= 0x2e80 && rune <= 0x9fff) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);
