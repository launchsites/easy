import 'package:material_ui/material_ui.dart';

import 'local_reminder.dart';
import 'local_reminder_backend.dart';

Future<LocalReminderSettings?> showLocalReminderSettings(
  BuildContext context, {
  required LocalReminderSettings settings,
  required LocalReminderBackend backend,
}) => showDialog<LocalReminderSettings>(
  context: context,
  builder: (context) =>
      _LocalReminderSettingsDialog(settings: settings, backend: backend),
);

class _LocalReminderSettingsDialog extends StatefulWidget {
  const _LocalReminderSettingsDialog({
    required this.settings,
    required this.backend,
  });

  final LocalReminderSettings settings;
  final LocalReminderBackend backend;

  @override
  State<_LocalReminderSettingsDialog> createState() =>
      _LocalReminderSettingsDialogState();
}

class _LocalReminderSettingsDialogState
    extends State<_LocalReminderSettingsDialog>
    with WidgetsBindingObserver {
  LocalReminderCapabilities? _capabilities;
  late bool _enabled;
  late bool _showTitles;
  bool _working = false;
  String? _error;
  int _refresh = 0;

  @override
  void initState() {
    super.initState();
    _enabled = widget.settings.enabled;
    _showTitles = widget.settings.showRecordTitles;
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final revision = ++_refresh;
    try {
      final status = await widget.backend.authorization();
      if (mounted && revision == _refresh) {
        setState(() {
          _capabilities = status;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && revision == _refresh) {
        setState(() => _error = 'Notification settings could not be checked.');
      }
    }
  }

  Future<void> _allowNotifications() async {
    _start();
    ++_refresh;
    try {
      final status = await widget.backend.requestNotificationPermission();
      if (mounted) setState(() => _capabilities = status);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Notifications could not be enabled.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _allowExact() async {
    _start();
    try {
      await widget.backend.requestExactScheduling();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Alarm access settings could not be opened.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _start() => setState(() {
    _working = true;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final capability = _capabilities;
    final status = capability?.permission;
    final supported = capability?.supported == true;
    final canSchedule = capability?.canSchedule == true;
    return AlertDialog(
      scrollable: true,
      title: const Text('Reminders on this device'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (capability == null && _error == null)
              const LinearProgressIndicator(),
            if (status == LocalReminderPermission.unavailable)
              const Text(
                'Local notification delivery is unavailable on this device.',
              ),
            if (status == LocalReminderPermission.notDetermined)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  onPressed: _working ? null : _allowNotifications,
                  child: const Text('Allow notifications'),
                ),
              ),
            if (status == LocalReminderPermission.denied)
              const Text('Allow Easy notifications in system settings.'),
            if (status == LocalReminderPermission.granted &&
                capability!.canRequestExactScheduling &&
                !capability.exactScheduling)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  onPressed: _working ? null : _allowExact,
                  child: const Text('Allow precise alarms'),
                ),
              ),
            if (supported || _enabled)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Deliver reminders'),
                value: _enabled,
                onChanged: _working || (!_enabled && !canSchedule)
                    ? null
                    : (value) => setState(() => _enabled = value),
              ),
            if (_enabled)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show titles in notifications'),
                value: _showTitles,
                onChanged: _working
                    ? null
                    : (value) => setState(() => _showTitles = value),
              ),
            if (_working) const LinearProgressIndicator(),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _working
              ? null
              : () => Navigator.pop(
                  context,
                  LocalReminderSettings(
                    enabled: _enabled,
                    showRecordTitles: _showTitles,
                  ),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class RecordReminderChoice {
  const RecordReminderChoice(this.preference);

  final RecordReminderPreference? preference;
}

Future<RecordReminderChoice?> showRecordReminderEditor(
  BuildContext context, {
  required ReminderTarget target,
  RecordReminderPreference? initial,
  DateTime? start,
}) => showDialog<RecordReminderChoice>(
  context: context,
  builder: (context) =>
      _RecordReminderDialog(target: target, initial: initial, start: start),
);

class _RecordReminderDialog extends StatefulWidget {
  const _RecordReminderDialog({required this.target, this.initial, this.start});

  final ReminderTarget target;
  final RecordReminderPreference? initial;
  final DateTime? start;

  @override
  State<_RecordReminderDialog> createState() => _RecordReminderDialogState();
}

class _RecordReminderDialogState extends State<_RecordReminderDialog> {
  late DateTime _day;
  late TimeOfDay _time;
  late bool _relative;
  late final TextEditingController _lead;
  bool _laterFold = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final at =
        (initial?.at ??
                widget.start ??
                DateTime.now().add(const Duration(hours: 1)))
            .toLocal();
    _day = DateUtils.dateOnly(at);
    _time = TimeOfDay.fromDateTime(at);
    _relative = initial?.minutesBeforeStart != null;
    _lead = TextEditingController(text: '${initial?.minutesBeforeStart ?? 10}');
    final alternatives = _instants();
    _laterFold =
        alternatives.first != alternatives.last &&
        initial?.at?.isAtSameMomentAs(alternatives.last!) == true;
  }

  @override
  void dispose() {
    _lead.dispose();
    super.dispose();
  }

  ({DateTime? first, DateTime? last}) _instants() {
    final clock = DateTime.utc(
      _day.year,
      _day.month,
      _day.day,
      _time.hour,
      _time.minute,
    );
    return (
      first: resolveReminderClock(clock),
      last: resolveReminderClock(clock, laterFold: true),
    );
  }

  Future<void> _chooseDay() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(_day.year - 10),
      lastDate: DateTime(_day.year + 15, 12, 31),
      helpText: 'Reminder date',
    );
    if (!mounted || date == null) return;
    setState(() {
      _day = date;
      _laterFold = false;
      _error = null;
    });
  }

  Future<void> _chooseTime() async {
    final time = await showTimePicker(context: context, initialTime: _time);
    if (!mounted || time == null) return;
    setState(() {
      _time = time;
      _laterFold = false;
      _error = null;
    });
  }

  void _save() {
    if (_relative) {
      final minutes = int.tryParse(_lead.text.trim());
      if (minutes == null) {
        setState(() => _error = 'Enter whole minutes.');
        return;
      }
      try {
        Navigator.pop(
          context,
          RecordReminderChoice(
            RecordReminderPreference.relative(
              target: widget.target,
              minutesBeforeStart: minutes,
            ),
          ),
        );
      } on ArgumentError catch (error) {
        setState(() => _error = error.message?.toString());
      }
      return;
    }
    final possibilities = _instants();
    final at = _laterFold ? possibilities.last : possibilities.first;
    if (at == null) {
      setState(() => _error = 'This local time is skipped when clocks change.');
      return;
    }
    if (!at.isAfter(DateTime.now())) {
      setState(() => _error = 'Choose a future time.');
      return;
    }
    Navigator.pop(
      context,
      RecordReminderChoice(
        RecordReminderPreference.absolute(target: widget.target, at: at),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final times = _instants();
    return AlertDialog(
      scrollable: true,
      title: const Text('Reminder'),
      content: SizedBox(
        width: 350,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.start != null || _relative)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Before the start'),
                value: _relative,
                onChanged: (value) => setState(() {
                  _relative = value;
                  _error = null;
                }),
              ),
            if (_relative)
              TextField(
                controller: _lead,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Minutes before'),
              )
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date'),
                subtitle: Text(
                  MaterialLocalizations.of(context).formatMediumDate(_day),
                ),
                onTap: _chooseDay,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Time'),
                subtitle: Text(_time.format(context)),
                onTap: _chooseTime,
              ),
              if (times.first != times.last)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use the later repeated time'),
                  value: _laterFold,
                  onChanged: (value) =>
                      setState(() => _laterFold = value ?? false),
                ),
            ],
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (widget.initial != null)
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const RecordReminderChoice(null)),
                child: const Text('Remove reminder'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save reminder')),
      ],
    );
  }
}
