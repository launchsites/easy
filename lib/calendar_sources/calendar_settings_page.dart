import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ui_theme.dart' as palette;
import 'calendar_directory.dart';
import 'event_kit_calendar_adapter.dart';

class CalendarSourcePreferences {
  CalendarSourcePreferences({
    Iterable<CalendarIdentity> allCalendars = const [],
    CalendarModeMemberships? memberships,
    this.defaultWriteCalendar,
  }) : allCalendars = Set.unmodifiable(allCalendars),
       memberships = memberships ?? CalendarModeMemberships();

  factory CalendarSourcePreferences.fromJson(Map<String, Object?> json) {
    final all = json['allCalendars'];
    final modes = json['memberships'];
    final destination = json['defaultWriteCalendar'];
    if (all != null && all is! List) {
      throw const FormatException('Expected a list of calendars for All.');
    }
    if (modes != null && modes is! Map<String, Object?>) {
      throw const FormatException('Expected calendar memberships.');
    }
    return CalendarSourcePreferences(
      allCalendars: all is List ? all.map(_identityFromJson) : const [],
      memberships: modes is Map<String, Object?>
          ? CalendarModeMemberships.fromJson(modes)
          : null,
      defaultWriteCalendar: destination == null
          ? null
          : _identityFromJson(destination),
    );
  }

  final Set<CalendarIdentity> allCalendars;
  final CalendarModeMemberships memberships;
  final CalendarIdentity? defaultWriteCalendar;

  Set<CalendarIdentity> calendarsFor(String? modeId) =>
      modeId == null ? allCalendars : memberships.forMode(modeId);

  CalendarSourcePreferences withCalendars(
    String? modeId,
    Iterable<CalendarIdentity> calendars,
  ) => CalendarSourcePreferences(
    allCalendars: modeId == null ? calendars : allCalendars,
    memberships: modeId == null
        ? memberships
        : memberships.withCalendars(modeId, calendars),
    defaultWriteCalendar: defaultWriteCalendar,
  );

  CalendarSourcePreferences withDefaultWriteCalendar(
    CalendarIdentity? calendar,
  ) => CalendarSourcePreferences(
    allCalendars: allCalendars,
    memberships: memberships,
    defaultWriteCalendar: calendar,
  );

  CalendarSourcePreferences withoutCalendars(Set<CalendarIdentity> removed) =>
      CalendarSourcePreferences(
        allCalendars: allCalendars.difference(removed),
        memberships: CalendarModeMemberships({
          for (final entry in memberships.byMode.entries)
            entry.key: entry.value.difference(removed),
        }),
        defaultWriteCalendar: removed.contains(defaultWriteCalendar)
            ? null
            : defaultWriteCalendar,
      );

  Map<String, Object?> toJson() => {
    'allCalendars': [for (final calendar in allCalendars) calendar.toJson()],
    'memberships': memberships.toJson(),
    if (defaultWriteCalendar case final calendar?)
      'defaultWriteCalendar': calendar.toJson(),
  };
}

CalendarIdentity _identityFromJson(Object? value) {
  if (value is Map<String, Object?>) return CalendarIdentity.fromJson(value);
  throw const FormatException('Expected a calendar identity.');
}

class CalendarSettingsPage extends StatefulWidget {
  const CalendarSettingsPage({
    required this.initialPreferences,
    required this.onChanged,
    required this.modes,
    this.localSources = const [],
    this.isAppleCalendar,
    this.adapter = const EventKitCalendarAdapter(),
    super.key,
  });

  final CalendarSourcePreferences initialPreferences;
  final ValueChanged<CalendarSourcePreferences> onChanged;
  final Map<String, String> modes;
  final Iterable<CalendarSource> localSources;
  final bool Function(CalendarIdentity)? isAppleCalendar;
  final EventKitCalendarAdapter adapter;

  @override
  State<CalendarSettingsPage> createState() => _CalendarSettingsPageState();
}

class _CalendarSettingsPageState extends State<CalendarSettingsPage>
    with WidgetsBindingObserver {
  late CalendarSourcePreferences _preferences;
  EventKitCalendarAccess? _access;
  List<CalendarSource> _appleSources = const [];
  bool _loading = false;
  bool _failed = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _preferences = widget.initialPreferences;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(CalendarSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.initialPreferences, oldWidget.initialPreferences)) {
      _preferences = widget.initialPreferences;
    }
    if (widget.adapter != oldWidget.adapter) {
      _request++;
      _access = null;
      _appleSources = const [];
      _loading = false;
      _failed = false;
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh({bool ask = false}) async {
    final adapter = widget.adapter;
    if (_loading || !adapter.isAvailable) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final access = ask
          ? await adapter.requestReadAccess()
          : await adapter.accessStatus();
      if (!mounted || request != _request) return;
      final sources = access == EventKitCalendarAccess.full
          ? await adapter.calendars()
          : const <CalendarSource>[];
      if (!mounted || request != _request) return;
      setState(() {
        _access = access;
        _appleSources = sources;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _failed = true;
        _appleSources = const [];
      });
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _update(CalendarSourcePreferences value) {
    setState(() => _preferences = value);
    widget.onChanged(value);
  }

  Set<CalendarIdentity> _unavailableAppleSelections(
    Iterable<CalendarSource> sources,
  ) {
    final isAppleCalendar = widget.isAppleCalendar;
    if (isAppleCalendar == null ||
        _loading ||
        _failed ||
        (widget.adapter.isAvailable && _access == null)) {
      return const {};
    }
    final present = sources.map((source) => source.id).toSet();
    final selected = {
      ..._preferences.allCalendars,
      for (final calendars in _preferences.memberships.byMode.values)
        ...calendars,
      ?_preferences.defaultWriteCalendar,
    };
    return selected
        .where(
          (calendar) =>
              isAppleCalendar(calendar) && !present.contains(calendar),
        )
        .toSet();
  }

  Iterable<MapEntry<String?, String>> get _views sync* {
    yield const MapEntry(null, 'All');
    yield* widget.modes.entries;
  }

  Future<void> _editVisibility(CalendarSource source) async {
    final views = _views.toList();
    final selected = {
      for (final view in views)
        if (_preferences.calendarsFor(view.key).contains(source.id)) view.key,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(source.name),
              const SizedBox(height: 4),
              Text(
                source.accountName,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
                  child: Text(
                    'Show in',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                for (final view in views)
                  CheckboxListTile(
                    title: Text(view.value),
                    controlAffinity: ListTileControlAffinity.leading,
                    value: selected.contains(view.key),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(view.key);
                      } else {
                        selected.remove(view.key);
                      }
                    }),
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
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    var preferences = _preferences;
    for (final view in views) {
      final current = preferences.calendarsFor(view.key);
      final show = selected.contains(view.key);
      if (current.contains(source.id) == show) continue;
      final updated = {...current};
      if (show) {
        updated.add(source.id);
      } else {
        updated.remove(source.id);
      }
      preferences = preferences.withCalendars(view.key, updated);
    }
    if (!identical(preferences, _preferences)) _update(preferences);
  }

  Future<void> _editDefault(List<CalendarSource> writable) async {
    final selected = _preferences.defaultWriteCalendar;
    final result = await showDialog<({CalendarIdentity? id})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Default calendar'),
        children: [
          ListTile(
            title: const Text('Ask each time'),
            trailing: selected == null ? const Icon(Icons.check_rounded) : null,
            onTap: () =>
                Navigator.pop(context, (id: null as CalendarIdentity?)),
          ),
          for (final source in writable)
            ListTile(
              title: Text(source.name),
              subtitle: Text(source.accountName),
              trailing: selected == source.id
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(context, (id: source.id)),
            ),
        ],
      ),
    );
    if (!mounted ||
        result == null ||
        result.id == _preferences.defaultWriteCalendar) {
      return;
    }
    _update(_preferences.withDefaultWriteCalendar(result.id));
  }

  @override
  Widget build(BuildContext context) {
    final sources = <CalendarIdentity, CalendarSource>{
      for (final source in widget.localSources) source.id: source,
      for (final source in _appleSources) source.id: source,
    }.values;
    final readable = sources.where((source) => source.canRead).toList();
    final writable = sources.where((source) => source.canWrite).toList();
    final unavailable = _unavailableAppleSelections(sources);
    final defaultSource = writable
        .where((source) => source.id == _preferences.defaultWriteCalendar)
        .firstOrNull;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Calendars')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 36),
              children: [
                const Text(
                  'Apple Calendar',
                  style: palette.sectionHeadingStyle,
                ),
                const SizedBox(height: 8),
                _accessSection(context),
                if (unavailable.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Unavailable Apple calendars',
                    style: palette.sectionHeadingStyle,
                  ),
                  const SizedBox(height: 8),
                  _accessAction(
                    context,
                    unavailable.length == 1
                        ? 'One saved Apple calendar is unavailable on this device.'
                        : '${unavailable.length} saved Apple calendars are unavailable on this device.',
                    'Clear unavailable selections',
                    () => _update(_preferences.withoutCalendars(unavailable)),
                  ),
                ],
                if (readable.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const Text(
                    'Show in views',
                    style: palette.sectionHeadingStyle,
                  ),
                  const SizedBox(height: 8),
                  for (final source in readable) _sourceRow(context, source),
                ],
                if (writable.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const Text('New events', style: palette.sectionHeadingStyle),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Default calendar'),
                    subtitle: Text(
                      defaultSource == null
                          ? _preferences.defaultWriteCalendar == null
                                ? 'Ask each time'
                                : 'Choose a calendar'
                          : '${defaultSource.name} · ${defaultSource.accountName}',
                      style: text.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _editDefault(writable),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceRow(BuildContext context, CalendarSource source) {
    final selected = _views
        .where(
          (view) => _preferences.calendarsFor(view.key).contains(source.id),
        )
        .map((view) => view.value)
        .join(', ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(source.name),
      subtitle: Text(
        selected.isEmpty
            ? source.accountName
            : '${source.accountName}\n$selected',
        maxLines: selected.isEmpty ? 1 : 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: selected.isNotEmpty,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _editVisibility(source),
    );
  }

  Widget _accessSection(BuildContext context) {
    if (_loading) {
      return const Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 9),
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_failed) {
      return _accessAction(
        context,
        'Calendar access could not be checked.',
        'Retry',
        _refresh,
      );
    }
    return switch (_access) {
      EventKitCalendarAccess.full => _accessAction(
        context,
        _appleSources.isEmpty
            ? 'No Apple calendars found.'
            : _appleSources.any((source) => source.canWrite)
            ? 'Calendar access granted'
            : 'Read-only access',
        'Refresh calendars',
        _refresh,
      ),
      EventKitCalendarAccess.unknown ||
      EventKitCalendarAccess.writeOnly => _accessAction(
        context,
        'Use calendars already on this device.',
        'Allow calendar access',
        () => _refresh(ask: true),
      ),
      EventKitCalendarAccess.denied => _accessAction(
        context,
        'Allow calendar access in your system settings.',
        'Check access',
        _refresh,
      ),
      EventKitCalendarAccess.restricted => _accessAction(
        context,
        'Calendar access is restricted on this device.',
        'Check access',
        _refresh,
      ),
      EventKitCalendarAccess.unavailable || null => Text(
        widget.adapter.isAvailable
            ? 'Calendar access is unavailable on this device.'
            : 'Available on iPhone, iPad and Mac.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    };
  }

  Widget _accessAction(
    BuildContext context,
    String message,
    String label,
    VoidCallback action,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(message, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: action, child: Text(label)),
    ],
  );
}
