import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../calendar_sources/calendar_directory.dart';
import 'focus_mode.dart';

/// An accepted schedule input without title, notes or location.
class FocusSuggestionEvent {
  const FocusSuggestionEvent.local({
    required String this.id,
    required String this.category,
    required this.start,
    required this.end,
    this.calendar,
    this.accepted = true,
    this.allDay = false,
  }) : _source = null;

  const FocusSuggestionEvent.sourced({
    required CalendarOccurrenceIdentity id,
    required this.start,
    required this.end,
    required this.accepted,
    this.allDay = false,
  }) : id = null,
       _source = id,
       category = null,
       calendar = null;

  final String? id;
  final CalendarOccurrenceIdentity? _source;
  final String? category;
  final CalendarIdentity? calendar;
  final DateTime start;
  final DateTime end;
  final bool accepted;
  final bool allDay;

  Object get _key => _source ?? id!;

  String get _fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode(switch (_source) {
            final source? => [
              'calendar',
              source.calendar.accountId,
              source.calendar.calendarId,
              source.eventId,
              source.recurrenceId,
            ],
            null => ['local', id],
          }),
        ),
      )
      .toString();
}

class FocusSuggestion {
  const FocusSuggestion._({
    required this.mode,
    required this.fingerprint,
    required this.activeFrom,
    required this.activeUntil,
  });

  final FocusMode mode;

  /// Opaque for persistence. Repeated events have distinct occurrence keys.
  final String fingerprint;
  final DateTime activeFrom;
  final DateTime activeUntil;

  bool matches(FocusSuggestion other) =>
      fingerprint == other.fingerprint &&
      mode.id == other.mode.id &&
      mode.name == other.mode.name &&
      activeFrom.isAtSameMomentAs(other.activeFrom) &&
      activeUntil.isAtSameMomentAs(other.activeUntil);
}

class FocusSuggestionPreferences {
  FocusSuggestionPreferences({this.enabled = false}) : _dismissed = const [];

  FocusSuggestionPreferences._(this.enabled, Iterable<String> dismissed)
    : _dismissed = List.unmodifiable(dismissed);

  factory FocusSuggestionPreferences.fromJson(Map<String, Object?> json) {
    final raw = json['dismissed'];
    if (json['version'] != 1 ||
        json['enabled'] is! bool ||
        raw is! List ||
        raw.length > _dismissalLimit ||
        raw.any(
          (value) =>
              value is! String ||
              value.length != 64 ||
              !_fingerprint.hasMatch(value),
        )) {
      throw const FormatException('Invalid focus suggestion settings.');
    }
    return FocusSuggestionPreferences._(
      json['enabled'] as bool,
      raw.cast<String>().toSet(),
    );
  }

  static const _dismissalLimit = 64;
  static final _fingerprint = RegExp(r'^[a-f0-9]{64}$');

  final bool enabled;
  final List<String> _dismissed;

  FocusSuggestionPreferences withEnabled(bool value) =>
      value == enabled ? this : FocusSuggestionPreferences._(value, _dismissed);

  FocusSuggestionPreferences dismissing(FocusSuggestion suggestion) =>
      FocusSuggestionPreferences._(
        enabled,
        [
          suggestion.fingerprint,
          for (final previous in _dismissed)
            if (previous != suggestion.fingerprint) previous,
        ].take(_dismissalLimit),
      );

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'dismissed': _dismissed,
  };
}

/// One eligible occurrence and exactly one visible destination are needed.
/// The result is an action proposal. Applying it is the caller's user gesture.
FocusSuggestion? suggestFocusMode({
  required FocusSuggestionPreferences preferences,
  required Iterable<FocusMode> modes,
  required Iterable<FocusSuggestionEvent> events,
  required DateTime now,
  CalendarModeMemberships? memberships,
  String? currentModeId,
  bool activityInProgress = false,
  bool workoutInProgress = false,
  bool Function(FocusMode, String)? matchesLocalCategory,
}) {
  if (!preferences.enabled || activityInProgress || workoutInProgress) {
    return null;
  }
  final visible = {for (final mode in modes) mode.id: mode};
  if (visible.isEmpty) return null;
  FocusSuggestionEvent? selectedEvent;
  FocusMode? selectedMode;
  for (final event in events) {
    if (!event.accepted ||
        event.allDay ||
        !event.end.isAfter(event.start) ||
        now.isBefore(event.start) ||
        !now.isBefore(event.end) ||
        (event._source?.eventId ?? event.id!).trim().isEmpty) {
      continue;
    }
    final targets = visible.values
        .where((mode) {
          if (event._source case final source?) {
            return memberships?.forMode(mode.id).contains(source.calendar) ??
                false;
          }
          final ownCalendar = event.calendar;
          if (ownCalendar != null &&
              memberships != null &&
              !memberships.forMode(mode.id).contains(ownCalendar)) {
            return false;
          }
          return mode.categories != null &&
              (matchesLocalCategory?.call(mode, event.category!) ??
                  mode.includes(event.category));
        })
        .take(2)
        .toList();
    if (targets.isEmpty) continue;
    if (targets.length != 1) return null;
    if (selectedEvent != null) {
      if (event._key == selectedEvent._key &&
          targets.single.id == selectedMode!.id &&
          event.start.isAtSameMomentAs(selectedEvent.start) &&
          event.end.isAtSameMomentAs(selectedEvent.end)) {
        continue;
      }
      return null;
    }
    selectedEvent = event;
    selectedMode = targets.single;
  }
  if (selectedEvent == null ||
      selectedMode == null ||
      selectedMode.id == currentModeId) {
    return null;
  }
  final fingerprint = selectedEvent._fingerprint;
  if (preferences._dismissed.contains(fingerprint)) return null;
  return FocusSuggestion._(
    mode: selectedMode,
    fingerprint: fingerprint,
    activeFrom: selectedEvent.start,
    activeUntil: selectedEvent.end,
  );
}
