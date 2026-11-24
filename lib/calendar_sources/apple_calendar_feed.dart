import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'calendar_directory.dart';
import 'event_kit_calendar_adapter.dart';

/// A bounded, unpersisted projection of calendars the user chose to read.
/// Changing a selection fences any previously running query.
class AppleCalendarFeed extends ChangeNotifier {
  AppleCalendarFeed({this._adapter = const EventKitCalendarAdapter()});

  final EventKitCalendarAdapter _adapter;
  Set<CalendarIdentity> _selected = const {};
  List<SourcedCalendarEvent<ExternalCalendarEvent>> _events = const [];
  Map<CalendarIdentity, CalendarSource> _sources = const {};
  DateTime? _start;
  DateTime? _end;
  DateTime? _anchor;
  StreamSubscription<void>? _changes;
  Timer? _refreshTimer;
  var _generation = 0;
  var _disposed = false;
  var _loading = false;
  var _verifiedAccess = false;
  var _watchFailed = false;
  String? _problem;

  List<SourcedCalendarEvent<ExternalCalendarEvent>> get events => _events;
  Map<CalendarIdentity, CalendarSource> get sources => _sources;
  bool get loading => _loading;
  String? get problem => _problem;
  bool get hasChosenCalendars => _selected.isNotEmpty;
  bool get hasVerifiedAccess => _verifiedAccess;
  bool get hasCurrentCoverage =>
      _verifiedAccess &&
      _problem == null &&
      !_loading &&
      !_watchFailed &&
      _refreshTimer?.isActive != true;

  bool covers(DateTime day) {
    final start = _start;
    final end = _end;
    return start != null &&
        end != null &&
        !day.isBefore(start) &&
        day.isBefore(end);
  }

  Future<void> refresh({
    required DateTime day,
    required Set<CalendarIdentity> selected,
    bool force = false,
  }) async {
    if (_disposed) return;
    final changed = !setEquals(_selected, selected);
    _anchor = day;
    if (selected.isEmpty) {
      if (_selected.isEmpty && _events.isEmpty && !_loading) return;
      _generation++;
      _selected = const {};
      _clearSnapshot();
      _problem = null;
      _loading = false;
      _stopWatching();
      notifyListeners();
      return;
    }
    if (!_adapter.isAvailable) {
      if (!changed && _problem != null) return;
      _generation++;
      _selected = Set.unmodifiable(selected);
      _clearSnapshot();
      _loading = false;
      _stopWatching();
      _problem = 'Apple calendars are unavailable on this device.';
      notifyListeners();
      return;
    }

    final covered =
        covers(day) &&
        day.difference(_start!).inDays >= 4 &&
        _end!.difference(day).inDays >= 4;
    if (!force && !changed && (_loading || covered)) return;
    final generation = ++_generation;
    _selected = Set.unmodifiable(selected);
    final requested = _selected;
    if (changed) _clearSnapshot();
    _loading = true;
    _problem = null;
    notifyListeners();

    final from = DateTime(day.year, day.month, day.day - 28);
    final until = DateTime(day.year, day.month, day.day + 29);
    try {
      final access = await _adapter.accessStatus();
      if (!_active(generation)) return;
      if (access != EventKitCalendarAccess.full) {
        _revokeAccess();
        return;
      }
      late final List<CalendarSource> sources;
      late final List<SourcedCalendarEvent<ExternalCalendarEvent>> events;
      // Future.wait preserves the original native permission exception.
      await Future.wait<void>([
        _adapter.calendars().then((value) => sources = value),
        _adapter
            .events(start: from, end: until, calendars: requested)
            .then((value) => events = value),
      ]);
      if (!_active(generation)) return;
      _sources = Map.unmodifiable({
        for (final source in sources)
          if (requested.contains(source.id)) source.id: source,
      });
      if (_sources.length != requested.length) {
        _problem = 'Some Apple calendars are unavailable.';
      }
      final unique =
          <
            CalendarOccurrenceIdentity,
            SourcedCalendarEvent<ExternalCalendarEvent>
          >{};
      for (final entry in events) {
        if (_sources.containsKey(entry.id.calendar)) {
          unique.putIfAbsent(entry.id, () => entry);
        }
      }
      _events = List.unmodifiable(unique.values);
      _start = from;
      _end = until;
      _verifiedAccess = true;
      _watch();
    } on PlatformException catch (error) {
      if (!_active(generation)) return;
      if (error.code == 'calendar_access') {
        _revokeAccess();
      } else {
        _problem = 'Apple calendars could not be refreshed.';
      }
    } catch (_) {
      if (!_active(generation)) return;
      _problem = 'Apple calendars could not be refreshed.';
    } finally {
      if (_active(generation) && _loading) {
        _loading = false;
        notifyListeners();
      }
    }
    final next = _anchor;
    if (_active(generation) &&
        _problem == null &&
        next != null &&
        !covers(next)) {
      await refresh(day: next, selected: _selected);
    }
  }

  bool _active(int generation) => !_disposed && generation == _generation;

  void _clearSnapshot() {
    _events = const [];
    _sources = const {};
    _start = _end = null;
    _verifiedAccess = false;
  }

  void _revokeAccess() {
    _clearSnapshot();
    _problem = 'Review Apple Calendar access in Settings.';
    _stopWatching();
  }

  void _watch() {
    if (_changes == null) _watchFailed = false;
    _changes ??= _adapter.changes.listen(
      (_) {
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 350), () {
          final day = _anchor;
          if (day != null) {
            unawaited(refresh(day: day, selected: _selected, force: true));
          }
        });
        notifyListeners();
      },
      onError: (Object _) => _watchEnded(),
      onDone: _watchEnded,
    );
  }

  void _watchEnded() {
    if (_disposed) return;
    _watchFailed = true;
    _stopWatching();
    notifyListeners();
  }

  void _stopWatching() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final changes = _changes;
    _changes = null;
    if (changes != null) unawaited(changes.cancel());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopWatching();
    super.dispose();
  }
}
