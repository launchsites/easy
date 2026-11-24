import 'dart:math' as math;

/// A start-ordered snapshot of events for calendar window lookups.
///
/// The maximum end in each tree branch lets a query skip events that finished
/// before the window, including histories with an occasional long event.
class CalendarEventIndex<E> {
  CalendarEventIndex(
    Iterable<E> events, {
    required DateTime Function(E) startOf,
    required DateTime Function(E) endOf,
  }) {
    _entries =
        [
          for (final (order, event) in events.indexed)
            _IndexedEvent(event, startOf(event), endOf(event), order),
        ]..sort((first, second) {
          final byStart = first.start.compareTo(second.start);
          return byStart == 0 ? first.order.compareTo(second.order) : byStart;
        });

    var leafCount = 1;
    while (leafCount < _entries.length) {
      leafCount *= 2;
    }
    _leafCount = leafCount;
    _maximumEnd = List<int>.filled(leafCount * 2, 0);
    for (var index = 0; index < _entries.length; index++) {
      _maximumEnd[leafCount + index] = _entries[index].end;
    }
    for (var node = leafCount - 1; node > 0; node--) {
      _maximumEnd[node] = math.max(
        _maximumEnd[node * 2],
        _maximumEnd[node * 2 + 1],
      );
    }
  }

  static const _dayCacheLimit = 64;

  late final List<_IndexedEvent<E>> _entries;
  late final int _leafCount;
  late final List<int> _maximumEnd;
  final _dayCache = <DateTime, List<E>>{};

  /// Events present on this local calendar day, in start order.
  ///
  /// Events with an empty or reversed span appear on their start day.
  List<E> onDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final cached = _dayCache.remove(start);
    if (cached != null) {
      _dayCache[start] = cached;
      return cached;
    }
    final events = overlapping(
      start,
      DateTime(day.year, day.month, day.day + 1),
    );
    if (_dayCache.length == _dayCacheLimit) {
      _dayCache.remove(_dayCache.keys.first);
    }
    _dayCache[start] = events;
    return events;
  }

  /// Events overlapping the half-open interval [start, end), in start order.
  List<E> overlapping(DateTime start, DateTime end) {
    if (!end.isAfter(start) || _entries.isEmpty) return const [];

    final limit = _firstStartingAtOrAfter(end.microsecondsSinceEpoch);
    final events = <E>[];
    _collect(1, 0, _leafCount, limit, start.microsecondsSinceEpoch, events);
    return List.unmodifiable(events);
  }

  int _firstStartingAtOrAfter(int end) {
    var low = 0;
    var high = _entries.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_entries[middle].start < end) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  void _collect(
    int node,
    int left,
    int right,
    int limit,
    int start,
    List<E> events,
  ) {
    if (left >= limit || _maximumEnd[node] <= start) return;
    if (right - left == 1) {
      events.add(_entries[left].event);
      return;
    }
    final middle = (left + right) ~/ 2;
    _collect(node * 2, left, middle, limit, start, events);
    _collect(node * 2 + 1, middle, right, limit, start, events);
  }
}

class _IndexedEvent<E> {
  _IndexedEvent(this.event, DateTime start, DateTime end, this.order)
    : start = start.microsecondsSinceEpoch,
      end = end.isAfter(start)
          ? end.microsecondsSinceEpoch
          : start.microsecondsSinceEpoch + 1;

  final E event;
  final int start;
  final int end;
  final int order;
}
