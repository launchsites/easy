import 'package:material_ui/material_ui.dart';

import 'availability_settings.dart';

Future<SchedulingSettings?> showSchedulingSettingsEditor(
  BuildContext context, {
  required SchedulingSettings settings,
  required Map<String, String> categories,
}) => Navigator.of(context).push<SchedulingSettings>(
  MaterialPageRoute(
    builder: (context) =>
        SchedulingSettingsPage(settings: settings, categories: categories),
  ),
);

class SchedulingSettingsPage extends StatefulWidget {
  const SchedulingSettingsPage({
    required this.settings,
    required this.categories,
    super.key,
  });

  final SchedulingSettings settings;
  final Map<String, String> categories;

  @override
  State<SchedulingSettingsPage> createState() => _SchedulingSettingsPageState();
}

enum _Panel { hours, places }

class _SchedulingSettingsPageState extends State<SchedulingSettingsPage> {
  late final List<WeeklyAvailability> _hours;
  late final List<SavedPlace> _places;
  late final List<TravelDuration> _routes;
  late final TextEditingController _timeZone;
  late final TextEditingController _before;
  late final TextEditingController _after;
  _Panel _panel = _Panel.hours;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = widget.settings;
    _hours = settings.availability.toList();
    _places = settings.places.toList();
    _routes = settings.routes.toList();
    _timeZone = TextEditingController(text: settings.timeZoneId ?? '');
    _before = TextEditingController(text: '${settings.beforeMinutes}');
    _after = TextEditingController(text: '${settings.afterMinutes}');
  }

  @override
  void dispose() {
    _timeZone.dispose();
    _before.dispose();
    _after.dispose();
    super.dispose();
  }

  void _change(VoidCallback update) => setState(() {
    update();
    _error = null;
  });

  Future<void> _editHours([int? index]) async {
    final result = await showDialog<WeeklyAvailability>(
      context: context,
      builder: (context) => _WeeklyEditor(
        initial: index == null ? null : _hours[index],
        categories: widget.categories,
      ),
    );
    if (!mounted || result == null) return;
    _change(() {
      if (index == null) {
        _hours.add(result);
      } else {
        _hours[index] = result;
      }
    });
  }

  Future<void> _editPlace([int? index]) async {
    final result = await showDialog<SavedPlace>(
      context: context,
      builder: (context) =>
          _PlaceEditor(initial: index == null ? null : _places[index]),
    );
    if (!mounted || result == null) return;
    _change(() {
      if (index == null) {
        _places.add(result);
      } else {
        _places[index] = result;
      }
    });
  }

  void _removePlace(int index) => _change(() {
    final removed = _places.removeAt(index);
    _routes.removeWhere(
      (route) =>
          route.fromPlaceId == removed.id || route.toPlaceId == removed.id,
    );
  });

  Future<void> _editRoute([int? index]) async {
    final result = await showDialog<TravelDuration>(
      context: context,
      builder: (context) => _RouteEditor(
        initial: index == null ? null : _routes[index],
        places: _places,
      ),
    );
    if (!mounted || result == null) return;
    _change(() {
      if (index == null) {
        _routes.add(result);
      } else {
        _routes[index] = result;
      }
    });
  }

  Future<void> _review() async {
    final before = int.tryParse(_before.text.trim());
    final after = int.tryParse(_after.text.trim());
    final zone = _timeZone.text.trim();
    if (before == null || after == null) {
      setState(() {
        _panel = _Panel.places;
        _error = 'Enter whole minutes for both event buffers.';
      });
      return;
    }
    late final SchedulingSettings proposal;
    try {
      proposal = SchedulingSettings(
        timeZoneId: zone.isEmpty ? null : zone,
        availability: _hours,
        places: _places,
        routes: _routes,
        beforeMinutes: before,
        afterMinutes: after,
      );
    } on ArgumentError catch (error) {
      setState(
        () => _error = error.message?.toString() ?? 'Check these settings.',
      );
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Review scheduling settings'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(proposal.timeZoneId ?? 'Device time zone'),
              const SizedBox(height: 12),
              const Text('Weekly hours'),
              if (proposal.availability.isEmpty)
                const Text('No weekly hours configured'),
              for (final window in proposal.availability)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    _describeHours(context, window, widget.categories),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'Event buffer: ${proposal.beforeMinutes} min before, ${proposal.afterMinutes} min after',
              ),
              const SizedBox(height: 12),
              const Text('Saved places'),
              if (proposal.places.isEmpty) const Text('No places configured'),
              for (final place in proposal.places) ...[
                Text(place.name),
                if (place.privateDetail case final detail?
                    when detail.isNotEmpty)
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              const Text('Travel durations'),
              if (proposal.routes.isEmpty) const Text('No routes configured'),
              for (final route in proposal.routes)
                Text('${_routeName(route)}  ·  ${route.minutes} min'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Back to editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save settings'),
          ),
        ],
      ),
    );
    if (mounted && accepted == true) Navigator.pop(context, proposal);
  }

  String _routeName(TravelDuration route) {
    final names = {for (final place in _places) place.id: place.name};
    return '${names[route.fromPlaceId]} → ${names[route.toPlaceId]}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scheduling')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: SegmentedButton<_Panel>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Panel.hours, label: Text('Hours')),
                  ButtonSegment(
                    value: _Panel.places,
                    label: Text('Places & travel'),
                  ),
                ],
                selected: {_panel},
                onSelectionChanged: (value) =>
                    setState(() => _panel = value.single),
              ),
            ),
            Expanded(
              child: ListView(
                key: PageStorageKey(_panel),
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                children: _panel == _Panel.hours
                    ? _hourPanel(context)
                    : _placePanel(context),
              ),
            ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _review,
                    child: const Text('Review changes'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _hourPanel(BuildContext context) => [
    TextField(
      controller: _timeZone,
      decoration: const InputDecoration(
        labelText: 'Time zone',
        hintText: 'Device time zone',
        helperText: 'Enter an IANA name such as Europe/London.',
      ),
    ),
    const SizedBox(height: 20),
    _SectionHeading('Weekly hours', action: 'Add hours', onAdd: _editHours),
    if (_hours.isEmpty)
      const Text('Add the hours you want to make available for planning.'),
    for (final (index, window) in _hours.indexed)
      _EditableRow(
        label: _describeHours(context, window, widget.categories),
        onTap: () => _editHours(index),
        onRemove: () => _change(() => _hours.removeAt(index)),
      ),
  ];

  List<Widget> _placePanel(BuildContext context) => [
    _SectionHeading('Saved places', action: 'Add place', onAdd: _editPlace),
    if (_places.isEmpty) const Text('Name a place you regularly go to.'),
    for (final (index, place) in _places.indexed)
      _EditableRow(
        label: place.name,
        onTap: () => _editPlace(index),
        onRemove: () => _removePlace(index),
      ),
    const SizedBox(height: 18),
    _SectionHeading(
      'Travel durations',
      action: 'Add route',
      onAdd: _places.length >= 2 ? _editRoute : null,
    ),
    Text(
      _places.length < 2 ? 'Add two saved places to enter a travel duration.' : 'A gap between events at two saved places stays unavailable until you enter a duration for that direction.',
    ),
    for (final (index, route) in _routes.indexed)
      _EditableRow(
        label: '${_routeName(route)}  ·  ${route.minutes} min',
        onTap: () => _editRoute(index),
        onRemove: () => _change(() => _routes.removeAt(index)),
      ),
    const SizedBox(height: 26),
    Text('Event buffers', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 6),
    TextField(
      controller: _before,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Minutes before each event'),
    ),
    TextField(
      controller: _after,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Minutes after each event'),
    ),
  ];
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(
    this.title, {
    required this.action,
    required this.onAdd,
  });
  final String title;
  final String action;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      TextButton.icon(
        icon: const Icon(Icons.add),
        label: Text(action),
        onPressed: onAdd,
      ),
    ],
  );
}

class _EditableRow extends StatelessWidget {
  const _EditableRow({
    required this.label,
    required this.onTap,
    required this.onRemove,
  });
  final String label;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    onTap: onTap,
    trailing: IconButton(
      tooltip: 'Remove $label',
      onPressed: onRemove,
      icon: const Icon(Icons.close),
    ),
  );
}

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _formatMinute(BuildContext context, int minute) =>
    TimeOfDay(hour: minute ~/ 60 % 24, minute: minute % 60).format(context);

String _describeHours(
  BuildContext context,
  WeeklyAvailability window,
  Map<String, String> labels,
) {
  final days = window.weekdays.toList()..sort();
  final dates = days.map((day) => _weekdayNames[day - 1]).join(', ');
  final times = window.startMinute == 0 && window.endMinute == 1440
      ? 'All day'
      : '${_formatMinute(context, window.startMinute)}–${_formatMinute(context, window.endMinute)}'
            '${window.crossesMidnight ? ' next day' : ''}';
  final categories = window.categories
      ?.map((category) => labels[category] ?? category)
      .join(', ');
  return '${window.kind == AvailabilityKind.unavailable ? 'Unavailable · ' : ''}'
      '$dates · $times${categories == null ? '' : ' · $categories'}';
}

class _EditDialog extends StatelessWidget {
  const _EditDialog({
    required this.title,
    required this.fields,
    required this.onSave,
    this.error,
  });

  final String title;
  final List<Widget> fields;
  final VoidCallback onSave;
  final String? error;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(title),
    content: SizedBox(
      width: 410,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...fields,
          if (error case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: onSave, child: const Text('Done')),
    ],
  );
}

class _WeeklyEditor extends StatefulWidget {
  const _WeeklyEditor({this.initial, required this.categories});
  final WeeklyAvailability? initial;
  final Map<String, String> categories;

  @override
  State<_WeeklyEditor> createState() => _WeeklyEditorState();
}

class _WeeklyEditorState extends State<_WeeklyEditor> {
  late final Set<int> _days;
  late final Set<String> _categories;
  late AvailabilityKind _kind;
  late int _start;
  late int _end;
  late bool _allDay;
  String? _error;

  @override
  void initState() {
    super.initState();
    final old = widget.initial;
    _days = {...?old?.weekdays};
    _categories = {...?old?.categories};
    _kind = old?.kind ?? AvailabilityKind.available;
    _allDay = old?.startMinute == 0 && old?.endMinute == 1440;
    _start = _allDay ? 9 * 60 : old?.startMinute ?? 9 * 60;
    _end = _allDay ? 17 * 60 : old?.endMinute ?? 17 * 60;
  }

  void _change(VoidCallback update) => setState(() {
    update();
    _error = null;
  });

  Future<void> _editTime({required bool start}) async {
    final minute = start ? _start : _end;
    final result = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60 % 24, minute: minute % 60),
    );
    if (!mounted || result == null) return;
    _change(() {
      final time = result.hour * 60 + result.minute;
      if (start) {
        _start = time;
      } else {
        _end = time;
      }
    });
  }

  void _save() {
    try {
      final row = WeeklyAvailability(
        id: widget.initial?.id ?? newSchedulingEntryId(),
        weekdays: _days,
        startMinute: _allDay ? 0 : _start,
        endMinute: _allDay ? 1440 : _end,
        categories: _categories.isEmpty ? null : _categories,
        kind: _kind,
      );
      Navigator.pop(context, row);
    } on ArgumentError catch (error) {
      setState(
        () => _error = error.message?.toString() ?? 'Check these hours.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = {
      ...widget.categories,
      for (final id in _categories)
        if (!widget.categories.containsKey(id)) id: id,
    };
    return _EditDialog(
      title: 'Weekly hours',
      error: _error,
      onSave: _save,
      fields: [
        DropdownButtonFormField<AvailabilityKind>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Type'),
          items: const [
            DropdownMenuItem(
              value: AvailabilityKind.available,
              child: Text('Available'),
            ),
            DropdownMenuItem(
              value: AvailabilityKind.unavailable,
              child: Text('Unavailable'),
            ),
          ],
          onChanged: (value) => _change(() => _kind = value!),
        ),
        const SizedBox(height: 12),
        const Text('Days'),
        Wrap(
          spacing: 6,
          children: [
            for (final (index, day) in _weekdayNames.indexed)
              FilterChip(
                label: Text(day),
                selected: _days.contains(index + 1),
                onSelected: (value) => _change(() {
                  if (value) {
                    _days.add(index + 1);
                  } else {
                    _days.remove(index + 1);
                  }
                }),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('All day'),
          value: _allDay,
          onChanged: (value) => _change(() => _allDay = value),
        ),
        if (!_allDay) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Starts'),
            subtitle: Text(_formatMinute(context, _start)),
            onTap: () => _editTime(start: true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ends'),
            subtitle: Text(
              '${_formatMinute(context, _end)}${_end < _start ? ' next day' : ''}',
            ),
            onTap: () => _editTime(start: false),
          ),
        ],
        if (choices.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_categories.isEmpty ? 'All categories' : 'Selected categories'),
          Wrap(
            spacing: 6,
            children: [
              for (final entry in choices.entries)
                FilterChip(
                  label: Text(entry.value),
                  selected: _categories.contains(entry.key),
                  onSelected: (value) => _change(() {
                    if (value) {
                      _categories.add(entry.key);
                    } else {
                      _categories.remove(entry.key);
                    }
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PlaceEditor extends StatefulWidget {
  const _PlaceEditor({this.initial});
  final SavedPlace? initial;

  @override
  State<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<_PlaceEditor> {
  late final TextEditingController _name;
  late final TextEditingController _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _detail = TextEditingController(text: widget.initial?.privateDetail ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _detail.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final place = SavedPlace(
        id: widget.initial?.id ?? newSchedulingEntryId(),
        name: _name.text,
        privateDetail: _detail.text.trim().isEmpty ? null : _detail.text,
      );
      Navigator.pop(context, place);
    } on ArgumentError catch (error) {
      setState(
        () => _error = error.message?.toString() ?? 'Check the place name.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => _EditDialog(
    title: 'Saved place',
    error: _error,
    onSave: _save,
    fields: [
      TextField(
        autofocus: true,
        controller: _name,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      TextField(
        controller: _detail,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(
          labelText: 'Private detail (optional)',
        ),
      ),
    ],
  );
}

class _RouteEditor extends StatefulWidget {
  const _RouteEditor({this.initial, required this.places});
  final TravelDuration? initial;
  final List<SavedPlace> places;

  @override
  State<_RouteEditor> createState() => _RouteEditorState();
}

class _RouteEditorState extends State<_RouteEditor> {
  String? _from;
  String? _to;
  late final TextEditingController _minutes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _from = widget.initial?.fromPlaceId;
    _to = widget.initial?.toPlaceId;
    final minutes = widget.initial?.minutes;
    _minutes = TextEditingController(text: minutes == null ? '' : '$minutes');
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  void _save() {
    final from = _from;
    final to = _to;
    final minutes = int.tryParse(_minutes.text.trim());
    if (from == null || to == null || minutes == null) {
      setState(() => _error = 'Choose both places and enter a duration.');
      return;
    }
    try {
      final route = TravelDuration(
        fromPlaceId: from,
        toPlaceId: to,
        minutes: minutes,
      );
      Navigator.pop(context, route);
    } on ArgumentError catch (error) {
      setState(
        () =>
            _error = error.message?.toString() ?? 'Check the travel duration.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final place in widget.places)
        DropdownMenuItem(
          value: place.id,
          child: Text(place.name, overflow: TextOverflow.ellipsis),
        ),
    ];
    return _EditDialog(
      title: 'Travel duration',
      error: _error,
      onSave: _save,
      fields: [
        DropdownButtonFormField<String>(
          initialValue: _from,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'From'),
          items: items,
          onChanged: (value) => setState(() => _from = value),
        ),
        DropdownButtonFormField<String>(
          initialValue: _to,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'To'),
          items: items,
          onChanged: (value) => setState(() => _to = value),
        ),
        TextField(
          controller: _minutes,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Minutes'),
        ),
      ],
    );
  }
}
