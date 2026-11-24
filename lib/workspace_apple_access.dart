part of 'main.dart';

extension _WorkspaceAppleAccess on _WorkspaceState {
  bool _isAppleProjection(Object? record) =>
      record is CalendarEvent &&
      record.isReadOnly &&
      record.id.startsWith('apple:');

  CalendarEvent? _currentAppleProjection(CalendarEvent record) {
    if (!_allows(EasyFeature.externalCalendars) ||
        !_appleFeed.hasVerifiedAccess) {
      return null;
    }
    final CalendarOccurrenceIdentity ref;
    try {
      final value = jsonDecode(record.id.substring('apple:'.length));
      if (value
          case [
            final String account,
            final String calendar,
            final String event,
            final String? recurrence,
          ]
          when account.isNotEmpty && calendar.isNotEmpty && event.isNotEmpty) {
        ref = CalendarOccurrenceIdentity(
          calendar: CalendarIdentity(accountId: account, calendarId: calendar),
          eventId: event,
          recurrenceId: recurrence,
        );
      } else {
        return null;
      }
    } on FormatException {
      return null;
    }
    if (!_appleFeed.sources.containsKey(ref.calendar) ||
        !_selectedAppleCalendars.contains(ref.calendar)) {
      return null;
    }
    final fresh = _appleFeed.events.where((item) => item.id == ref).firstOrNull;
    return fresh == null ? null : _fromApple(fresh);
  }

  Widget _appleDetailsWhileAllowed(
    Object record,
    Widget Function(Object) view,
  ) {
    if (!_isAppleProjection(record)) return view(record);
    return ListenableBuilder(
      listenable: _appleFeed,
      builder: (context, _) {
        final event = _currentAppleProjection(record as CalendarEvent);
        return event != null
            ? view(event)
            : Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 26),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('This Apple Calendar event is unavailable.'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
      },
    );
  }
}
