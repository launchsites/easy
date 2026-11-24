import 'package:flutter/foundation.dart';

typedef CalendarWindowInput<S> = ({
  List<S> sources,
  DateTime start,
  DateTime end,
});

/// Caches one bounded window of computed local occurrences.
class CalendarWindowFeed<S, E> extends ChangeNotifier {
  CalendarWindowFeed({
    required this._expand,
    required this._errorMessage,
  });

  final List<E> Function(CalendarWindowInput<S>) _expand;
  final String _errorMessage;
  List<S> _sources = const [];
  List<E> _events = const [];
  DateTime? _anchor;
  DateTime? _start;
  DateTime? _end;
  Future<void>? _loading;
  int _generation = 0;
  bool _disposed = false;
  String? _problem;

  List<E> get events => _events;
  String? get problem => _problem;

  bool covers(DateTime day) =>
      _start != null &&
      _end != null &&
      !day.isBefore(_start!) &&
      day.isBefore(_end!);

  Future<void> refresh({
    required DateTime day,
    required List<S> sources,
  }) async {
    if (_disposed) return;
    _anchor = day;
    final changed = !listEquals(sources, _sources);
    if (sources.isEmpty) {
      if (changed) {
        _sources = const [];
        _events = const [];
        _start = _end = null;
        _problem = null;
        _generation++;
        _loading = null;
        notifyListeners();
      }
      return;
    }
    final covered =
        covers(day) &&
        day.difference(_start!).inDays >= 4 &&
        _end!.difference(day).inDays >= 4;
    if (!changed) {
      final pending = _loading;
      if (pending != null) {
        await pending;
        return;
      }
      if (covered) return;
    }
    final generation = ++_generation;
    _sources = List.unmodifiable(sources);
    if (changed) {
      _events = const [];
      _start = _end = null;
      _problem = null;
      notifyListeners();
    }

    final start = DateTime(day.year, day.month, day.day - 21);
    final end = DateTime(day.year, day.month, day.day + 22);
    final job = _fill(generation, start, end, _sources);
    _loading = job;
    await job;
    if (!_active(generation)) return;
    _loading = null;
    final next = _anchor;
    if (next != null && !covers(next)) {
      await refresh(day: next, sources: _sources);
    }
  }

  Future<void> _fill(
    int generation,
    DateTime start,
    DateTime end,
    List<S> sources,
  ) async {
    try {
      final next = await compute(_expand, (
        sources: sources,
        start: start,
        end: end,
      ));
      if (!_active(generation)) return;
      _events = next;
      _problem = null;
    } catch (_) {
      if (!_active(generation)) return;
      _events = const [];
      _problem = _errorMessage;
    } finally {
      if (_active(generation)) {
        _start = start;
        _end = end;
        notifyListeners();
      }
    }
  }

  bool _active(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
