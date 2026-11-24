part of 'main.dart';

enum _AppleRecordAction {
  copy('Copy to Apple Calendar'),
  update('Update Apple copy'),
  recover('Save calendar link');

  const _AppleRecordAction(this.label);
  final String label;
}

extension _WorkspaceAppleUpdates on _WorkspaceState {
  _AppleRecordAction? _appleActionFor(Object? record) => switch (record) {
    CalendarEvent event when _canRecoverAppleCopy(event) =>
      _AppleRecordAction.recover,
    CalendarEvent event when _canUpdateAppleCopy(event) =>
      _AppleRecordAction.update,
    CalendarEvent event when _canCopyToApple(event) => _AppleRecordAction.copy,
    _ => null,
  };

  Future<void> _appleRecordAction(
    CalendarEvent event,
    _AppleRecordAction action,
  ) => switch (action) {
    _AppleRecordAction.copy => _copyToApple(event),
    _AppleRecordAction.update => _updateAppleCopy(event),
    _AppleRecordAction.recover => _recoverAppleCopy(event),
  };

  String? _appleCopyVersionFor(String localId) {
    if (_unsavedAppleCopies[localId] case final receipt?) {
      return receipt.revision;
    }
    final raw = _data.sections[_appleCopiesKey];
    if (raw is! Map<String, Object?>) return null;
    final entry = raw[localId];
    final version = entry is Map<String, Object?> ? entry['revision'] : null;
    return version is String && _appleCopyVersionFormat.hasMatch(version)
        ? version
        : null;
  }

  bool _canUpdateAppleCopy(Object? record) =>
      record is CalendarEvent &&
      !record.isReadOnly &&
      record.recurringSeriesId == null &&
      !_eventSeriesIds.contains(record.id) &&
      widget.calendarAdapter.isAvailable &&
      _allows(EasyFeature.externalCalendars) &&
      _appleCopyFor(record.id) != null &&
      _appleCopyVersionFor(record.id) != null &&
      !_unsavedAppleCopies.containsKey(record.id);

  bool _canRecoverAppleCopy(Object? record) =>
      record is CalendarEvent && _unsavedAppleCopies.containsKey(record.id);

  Future<void> _persistAppleReceipt(
    String id,
    EventKitCopyReceipt receipt,
  ) async {
    _unsavedAppleCopies[id] = receipt;
    _appleCopyRevision++;
    final previous = _data;
    final raw = previous.sections[_appleCopiesKey];
    final copies = <String, Object?>{
      if (raw is Map<String, Object?>) ...raw,
      id: {
        ...receipt.id.calendar.toJson(),
        'eventId': receipt.id.eventId,
        'revision': ?receipt.revision,
      },
    };
    await _commitReviewedData(
      previous,
      previous.withSection(_appleCopiesKey, copies),
    );
    if (identical(_unsavedAppleCopies[id], receipt)) {
      _unsavedAppleCopies.remove(id);
    }
  }

  Future<void> _recoverAppleCopy(CalendarEvent event) async {
    if (_copyingApple || _reviewSaving) return;
    final receipt = _unsavedAppleCopies[event.id];
    if (receipt == null ||
        !_data.events.any((value) => identical(value, event))) {
      return;
    }
    _copyingApple = true;
    try {
      await _persistAppleReceipt(event.id, receipt);
      if (mounted) _inform('Calendar link saved.');
    } catch (_) {
      if (mounted) _inform('The calendar link could not be saved.');
    } finally {
      _copyingApple = false;
    }
  }

  Future<void> _updateAppleCopy(CalendarEvent event) async {
    if (_copyingApple || _reviewSaving || !_canUpdateAppleCopy(event)) return;
    final id = _appleCopyFor(event.id)!;
    final revision = _appleCopyVersionFor(event.id)!;
    _copyingApple = true;
    var changedApple = false;
    try {
      final adapter = widget.calendarAdapter;
      if (await adapter.accessStatus() != EventKitCalendarAccess.full) {
        if (mounted) {
          _inform('Connect Apple Calendar in Settings before updating.');
        }
        return;
      }
      if (!mounted) return;
      final scope = await _chooseAppleUpdateScope();
      if (!mounted || scope == null) return;
      final review = await adapter.prepareUpdate(
        target: id,
        expectedRevision: revision,
        draft: EventKitEventDraft(
          title: event.title,
          start: event.start,
          end: event.end,
          allDay: event.allDay,
          location: event.location,
          notes: event.description,
        ),
        updateLocation: scope.location,
        updateNotes: scope.notes,
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => _AppleCopyDiff(review: review),
      );
      if (!mounted || approved != true) return;
      if (!_canUpdateAppleCopy(event) ||
          _appleCopyFor(event.id) != id ||
          _appleCopyVersionFor(event.id) != revision ||
          !_data.events.any((value) => identical(value, event))) {
        _inform('This event changed. Open it again to review the update.');
        return;
      }
      final receipt = await adapter.updateReviewedEvent(
        review,
        confirmed: true,
      );
      changedApple = true;
      if (!mounted) return;
      await _persistAppleReceipt(event.id, receipt);
      if (!mounted) return;
      _inform('Updated in ${review.destination.name}.');
      unawaited(_refreshExternalCalendars(force: true));
    } on PlatformException catch (error) {
      if (!mounted) return;
      _inform(
        changedApple
            ? 'Apple Calendar saved the update. Save its link again in Easy.'
            : switch (error.code) {
                'calendar_copy_changed' =>
                  'The Apple event changed. Review it in Apple Calendar.',
                'calendar_copy_missing' =>
                  'The linked event is unavailable in Apple Calendar.',
                'calendar_no_changes' =>
                  'The selected fields already match Apple Calendar.',
                _ => 'The update could not be confirmed. Check Apple Calendar before trying again.',
              },
      );
    } catch (_) {
      if (mounted) {
        _inform(
          changedApple
              ? 'Apple Calendar saved the update. Save its link again in Easy.'
              : 'The update could not be confirmed. Check Apple Calendar before trying again.',
        );
      }
    } finally {
      _copyingApple = false;
    }
  }

  Future<({bool location, bool notes})?> _chooseAppleUpdateScope() {
    var location = false;
    var notes = false;
    return showDialog<({bool location, bool notes})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('Update Apple copy'),
          scrollable: true,
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Review title and timing'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include location'),
                  value: location,
                  onChanged: (value) => change(() => location = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include notes'),
                  value: notes,
                  onChanged: (value) => change(() => notes = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (location: location, notes: notes)),
              child: const Text('Review update'),
            ),
          ],
        ),
      ),
    );
  }
}

final _appleCopyVersionFormat = RegExp(r'^[a-f0-9]{64}$');

class _AppleCopyDiff extends StatelessWidget {
  const _AppleCopyDiff({required this.review});

  final EventKitUpdateReview review;

  @override
  Widget build(BuildContext context) {
    final format = MaterialLocalizations.of(context);
    String timing(DateTime start, DateTime end, bool allDay) {
      if (allDay) {
        final last = DateTime(end.year, end.month, end.day - 1);
        return sameDay(start, last)
            ? '${format.formatMediumDate(start)} · All day'
            : '${format.formatMediumDate(start)} to ${format.formatMediumDate(last)} · All day';
      }
      String moment(DateTime value) {
        final local = value.toLocal();
        return '${format.formatMediumDate(local)}, ${format.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
      }

      return '${moment(start)} to ${moment(end)}';
    }

    return AlertDialog(
      title: const Text('Update Apple Calendar?'),
      scrollable: true,
      content: SizedBox(
        width: 410,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Text(
              [
                review.destination.name,
                review.destination.accountName,
              ].where((name) => name.isNotEmpty).join(' · '),
            ),
            _copyDetails(
              'Current in Apple Calendar',
              review.before.title,
              timing(
                review.before.start,
                review.before.end,
                review.before.allDay,
              ),
              review.before.location,
              review.before.notes,
            ),
            const Divider(),
            _copyDetails(
              'After update',
              review.draft.title,
              timing(review.start, review.end, review.draft.allDay),
              review.draft.location,
              review.draft.notes,
            ),
            if (review.timeZoneId case final zone?)
              Text(zone, style: contentMetadataStyle),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Update calendar'),
        ),
      ],
    );
  }

  Widget _copyDetails(
    String headline,
    String title,
    String time,
    String? location,
    String? notes,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 5,
    children: [
      Text(headline, style: contentMetadataStyle),
      Text(title, style: sectionHeadingStyle),
      Text(time),
      if (review.updateLocation)
        Text(location == null || location.isEmpty ? 'No location' : location),
      if (review.updateNotes)
        Text(notes == null || notes.isEmpty ? 'No notes' : notes),
    ],
  );
}
