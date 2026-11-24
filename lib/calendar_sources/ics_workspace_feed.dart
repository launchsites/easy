import 'package:flutter/foundation.dart';

import 'ics_workspace.dart';

class IcsWorkspaceFeed extends ChangeNotifier {
  List<WorkspaceIcsCalendar> _calendars = const [];
  List<IcsWorkspaceEvent> _events = const [];
  DateTime? _day;
  DateTime? _start;
  DateTime? _end;
  int _generation = 0;
  bool _disposed = false;
  bool _loading = false;
  String? _problem;

  List<IcsWorkspaceEvent> get events => _events;
  String? get problem => _problem;

  bool covers(DateTime day) =>
      _start != null &&
      _end != null &&
      !day.isBefore(_start!) &&
      day.isBefore(_end!);

  Future<void> refresh({
    required DateTime day,
    required List<WorkspaceIcsCalendar> calendars,
  }) async {
    if (_disposed) return;
    _day = day;
    final changed = !listEquals(calendars, _calendars);
    if (calendars.isEmpty) {
      if (changed) {
        _calendars = const [];
        _events = const [];
        _start = _end = null;
        _problem = null;
        _generation++;
        _loading = false;
        notifyListeners();
      }
      return;
    }
    final covered =
        covers(day) &&
        day.difference(_start!).inDays >= 4 &&
        _end!.difference(day).inDays >= 4;
    if (!changed && (_loading || covered)) return;
    final generation = ++_generation;
    _calendars = List.unmodifiable(calendars);
    _loading = true;
    if (changed) {
      _events = const [];
      _start = _end = null;
      _problem = null;
      notifyListeners();
    }

    final start = DateTime(day.year, day.month, day.day - 21);
    final end = DateTime(day.year, day.month, day.day + 22);
    try {
      final next = await compute(expandWorkspaceIcs, (
        calendars: _calendars,
        start: start,
        end: end,
      ));
      if (!_active(generation)) return;
      _events = next;
      _start = start;
      _end = end;
      _problem = null;
    } catch (_) {
      if (!_active(generation)) return;
      _problem = 'Imported calendars could not be displayed for these dates.';
      _start = start;
      _end = end;
    } finally {
      if (_active(generation)) {
        _loading = false;
        notifyListeners();
      }
    }
    if (_active(generation) && _day != null && !covers(_day!)) {
      await refresh(day: _day!, calendars: _calendars);
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
