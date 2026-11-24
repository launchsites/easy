import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activities/activities.dart';
import 'ai/ai_device_state.dart';
import 'ai/ai_runtime.dart';
import 'ai/ai_settings_page.dart';
import 'calendar_page.dart';
import 'calendar_sources/apple_calendar_feed.dart';
import 'calendar_sources/calendar_directory.dart';
import 'calendar_sources/calendar_settings_page.dart';
import 'calendar_sources/event_kit_calendar_adapter.dart'
    show EventKitCalendarAdapter, ExternalCalendarEvent;
import 'calendar_sources/ics_calendar.dart';
import 'calendar_sources/ics_import_export.dart';
import 'calendar_sources/ics_transfer_page.dart';
import 'calendar_sources/ics_workspace.dart';
import 'calendar_sources/ics_workspace_feed.dart';
import 'capture/capture_archive.dart';
import 'capture/capture_interpreter.dart';
import 'capture/capture_review_sheet.dart';
import 'capture/hold_capture_button.dart';
import 'capture/local_transcriber.dart';
import 'capture/voice_capture_sheet.dart';
import 'capture/voice_playback_dialog.dart';
import 'capture/voice_transcription_settings.dart';
import 'focus/focus_mode.dart';
import 'focus/focus_modes_page.dart';
import 'gym_history_page.dart';
import 'gym_mode_ui.dart';
import 'gym_session.dart';
import 'list_pages.dart';
import 'mobile_home.dart';
import 'notes/note_preview.dart';
import 'nutrition/nutrition.dart';
import 'orbit_navigation.dart';
import 'preferences/feature_preferences.dart';
import 'preferences/feature_preferences_page.dart';
import 'quick_capture.dart';
import 'record_editor.dart';
import 'scheduling/plan_day_sheet.dart';
import 'scheduling/planner.dart';
import 'settings_page.dart';
import 'storage/attachment_store.dart';
import 'storage/workspace_backup_page.dart';
import 'storage/workspace_store.dart';
import 'today_page.dart';
import 'workout_plan.dart';
import 'workout_plans_page.dart';
import 'workspace_data.dart';

const appName = String.fromEnvironment('APP_NAME', defaultValue: 'Easy');

void main() => runApp(const EasyApp());

typedef WorkspaceStoreOpener = Future<WorkspaceStore> Function({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
});

class EasyApp extends StatelessWidget {
  const EasyApp({super.key, this.openStore = openWorkspaceStore});

  final WorkspaceStoreOpener openStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: easyTheme(),
      home: _Workspace(openStore: openStore),
    );
  }
}

enum _Destination {
  today('Today', Icons.wb_sunny_outlined),
  calendar('Calendar', Icons.calendar_today_outlined),
  tasks('Tasks', Icons.check_box_outlined),
  notes('Notes', Icons.notes_rounded);

  const _Destination(this.label, this.icon);

  final String label;
  final IconData icon;
}

const _storageKey = 'easy.workspace.v1';
const _gymStorageKey = 'easy.gym-sessions.v1';
const _workoutPlansKey = 'easy.workout-plans.v1';
const _focusProfilesKey = 'focusProfiles';
const _calendarPreferencesKey = 'calendarPreferences';
const _nutritionKey = 'nutrition';
const _activitiesKey = 'activities';
const _voiceSettingsKey = 'easy.voice-transcription.v1';
const _localCalendarAccount = 'easy-local';
const _icsCalendarsKey = 'importedCalendars';
const _featuresKey = 'features';

CalendarIdentity _localCalendar(String category) => CalendarIdentity(
  accountId: _localCalendarAccount,
  calendarId: category.isEmpty ? 'general' : category,
);

bool _isAppleCalendar(CalendarIdentity id) =>
    id.accountId != _localCalendarAccount &&
    id.accountId != workspaceIcsAccountId;

class _Workspace extends StatefulWidget {
  const _Workspace({required this.openStore});

  final WorkspaceStoreOpener openStore;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> with WidgetsBindingObserver {
  final _legacyPreferences = SharedPreferencesAsync();
  WorkspaceStore? _store;
  int? _persistedRevision;
  var _openingStore = false;
  var _reviewSaving = false;
  var _planningDay = false;
  var _recordingVoice = false;
  Future<void> _pendingSave = Future.value();
  late WorkspaceData _data;
  int _contentRevision = 0;
  List<GymSession>? _gymSessions;
  List<WorkoutPlan>? _workoutPlans;
  var _calendarDate = dateOnly(DateTime.now());
  DateTime get _today => dateOnly(DateTime.now());
  var _destination = _Destination.today;
  String? _space;
  Object? _inspected;
  var _loading = true;
  var _loadFailed = false;
  final _pageStorage = PageStorageBucket();
  final _features = ValueNotifier(FeaturePreferences());
  List<FocusMode> _modes = standardFocusModes();
  CalendarSourcePreferences? _calendarPreferences;
  final _appleFeed = AppleCalendarFeed();
  final _icsFeed = IcsWorkspaceFeed();
  List<WorkspaceIcsCalendar> _icsCalendars = const [];
  Future<AttachmentStore?>? _attachmentStore;
  Future<AiDeviceState>? _aiState;
  Future<AiRuntime?>? _preparingAi;
  AiRuntime? _ai;
  final _voiceTranscriber = LocalTranscriber();
  VoiceTranscriptionConfig? _voiceConfig;

  FocusMode? get _focus =>
      _modes.where((mode) => mode.id == _space).firstOrNull;

  bool _allows(EasyFeature feature) => _features.value.allows(feature);

  Iterable<FocusMode> get _availableModes => _modes.where(
    (mode) => mode.sections.isEmpty || mode.sections.any(_showsFocusSection),
  );

  bool _showsFocusSection(FocusSection section) => switch (section) {
    FocusSection.workout => _allows(EasyFeature.workouts),
    FocusSection.nutrition => _allows(EasyFeature.nutrition),
    FocusSection.activity ||
    FocusSection.routines => _allows(EasyFeature.activity),
    FocusSection.schedule || FocusSection.tasks => true,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appleFeed.addListener(_appleCalendarChanged);
    _icsFeed.addListener(_appleCalendarChanged);
    unawaited(_load());
    if (LocalTranscriber.supported) unawaited(_loadVoiceSettings());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appleFeed.dispose();
    _icsFeed.dispose();
    _features.dispose();
    _voiceTranscriber.cancel();
    _ai?.dispose();
    final aiState = _aiState;
    if (aiState != null) {
      unawaited(aiState.then((state) => state.close(), onError: (Object _) {}));
    }
    final store = _store;
    if (store != null) {
      unawaited(_pendingSave.then((_) => store.close()));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _ai?.setForeground(
      state == AppLifecycleState.resumed && _allows(EasyFeature.ai),
    );
    if (state != AppLifecycleState.resumed) _voiceTranscriber.cancel();
    if (!_loading && state == AppLifecycleState.resumed) {
      unawaited(_refreshExternalCalendars(force: true));
    }
  }

  Future<void> _load() async {
    if (_openingStore) return;
    _openingStore = true;
    try {
      final store =
          _store ??
          await widget.openStore(
            preferences: _legacyPreferences,
            readLegacy: _readLegacy,
          );
      if (!mounted) {
        if (_store == null) await store.close();
        return;
      }
      _store = store;
      final revision = await store.read();
      if (!mounted) return;
      await _loadRevision(revision);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      _openingStore = false;
    }
  }

  Future<void> _loadRevision(WorkspaceRevision revision) async {
    final snapshot = revision.snapshot;
    final data = WorkspaceData.decode(snapshot.workspaceJson);
    final sessions = _decodeRecords(snapshot.gymSessionJson, GymSession.decode);
    final plans = _decodeRecords(snapshot.workoutPlanJson, WorkoutPlan.decode);
    if (!mounted) return;
    setState(() {
      _persistedRevision = revision.revision;
      _data = data;
      _contentRevision++;
      _gymSessions = sessions;
      _workoutPlans = plans;
      _inspected = null;
      _loadViewSettings();
      _loading = false;
      _loadFailed = false;
    });
    _refreshCalendarViews();
    if (!_allows(EasyFeature.ai)) _ai?.setForeground(false);
    if (!kIsWeb && identical(widget.openStore, openWorkspaceStore)) {
      if (_allows(EasyFeature.ai)) unawaited(_prepareAi());
    }
  }

  Future<WorkspaceSnapshot> _readLegacy() async {
    final (workspace, gym, plans) = await (
      _legacyPreferences.getString(_storageKey),
      _legacyPreferences.getStringList(_gymStorageKey),
      _legacyPreferences.getStringList(_workoutPlansKey),
    ).wait;
    return WorkspaceSnapshot(
      workspaceJson: workspace ?? WorkspaceData.samples(_today).encode(),
      gymSessionJson: gym ?? [],
      workoutPlanJson: plans ?? [_sampleWorkoutPlan(_today).encode()],
    );
  }

  List<T>? _decodeRecords<T>(List<String> saved, T Function(String) decode) {
    try {
      return saved.map(decode).toList();
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _categories() => {
    for (final key in {
      ...spaceColors.keys,
      ..._data.tasks.map((task) => task.category),
      ..._data.events.map((event) => event.category),
      ..._data.notes.map((note) => note.category).nonNulls,
      ..._modes.expand((mode) => mode.categories ?? const <String>{}),
    })
      if (key.isNotEmpty) key: spaceName(key),
  };

  CalendarSourcePreferences _defaultCalendarPreferences() {
    final categories = _categories().keys;
    return CalendarSourcePreferences(
      allCalendars: ['', ...categories].map(_localCalendar),
      memberships: CalendarModeMemberships({
        for (final mode in _modes)
          mode.id: ['', ...categories].where(mode.includes).map(_localCalendar),
      }),
    );
  }

  void _loadViewSettings() {
    final features = _data.sections[_featuresKey];
    try {
      _features.value = features is Map<String, dynamic>
          ? FeaturePreferences.fromJson(features)
          : FeaturePreferences();
    } on Object {
      _features.value = FeaturePreferences();
    }
    final savedModes = _data.sections[_focusProfilesKey];
    try {
      _modes = savedModes is List
          ? List.unmodifiable([
              for (final mode in savedModes)
                FocusMode.fromJson(mode as Map<String, dynamic>),
            ])
          : standardFocusModes();
      if (_modes.map((mode) => mode.id).toSet().length != _modes.length) {
        throw const FormatException('Duplicate focus ID.');
      }
    } on Object {
      _modes = standardFocusModes();
    }
    if (!_availableModes.any((mode) => mode.id == _space)) _space = null;
    final savedCalendars = _data.sections[_calendarPreferencesKey];
    try {
      _calendarPreferences = savedCalendars is Map<String, Object?>
          ? CalendarSourcePreferences.fromJson(savedCalendars)
          : null;
    } on Object {
      _calendarPreferences = null;
    }
    try {
      _icsCalendars = WorkspaceIcsCalendar.decodeList(
        _data.sections[_icsCalendarsKey],
      );
    } on Object {
      _icsCalendars = const [];
    }
  }

  void _changeFocusModes(List<FocusMode> modes) {
    _modes = modes;
    if (_focus == null) _space = null;
    var updated = _data.withSection(_focusProfilesKey, [
      for (final mode in modes) mode.toJson(),
    ]);
    if (_calendarPreferences case final current?) {
      final defaults = _defaultCalendarPreferences();
      final next = CalendarSourcePreferences(
        allCalendars: current.allCalendars,
        defaultWriteCalendar: current.defaultWriteCalendar,
        memberships: CalendarModeMemberships({
          for (final mode in modes)
            mode.id:
                current.memberships.byMode[mode.id] ??
                defaults.calendarsFor(mode.id),
        }),
      );
      _calendarPreferences = next;
      updated = updated.withSection(_calendarPreferencesKey, next.toJson());
    }
    _update(updated);
    _refreshCalendarViews();
  }

  void _changeCalendarPreferences(CalendarSourcePreferences preferences) {
    _calendarPreferences = preferences;
    _update(_data.withSection(_calendarPreferencesKey, preferences.toJson()));
    _refreshCalendarViews();
  }

  Set<CalendarIdentity> get _selectedAppleCalendars {
    return _allows(EasyFeature.externalCalendars)
        ? _selectedCalendars.where(_isAppleCalendar).toSet()
        : const {};
  }

  Iterable<CalendarIdentity> get _selectedCalendars sync* {
    final preferences = _calendarPreferences;
    if (preferences == null) return;
    yield* preferences.allCalendars;
    yield* preferences.memberships.byMode.values.expand((ids) => ids);
  }

  List<WorkspaceIcsCalendar> get _selectedIcsCalendars {
    final selected = _selectedCalendars
        .where((id) => id.accountId == workspaceIcsAccountId)
        .toSet();
    return [
      for (final source in _icsCalendars)
        if (selected.contains(source.identity)) source,
    ];
  }

  void _refreshCalendarViews() {
    unawaited(_refreshExternalCalendars());
    unawaited(
      _icsFeed.refresh(day: _calendarDate, calendars: _selectedIcsCalendars),
    );
  }

  Future<void> _refreshExternalCalendars({DateTime? day, bool force = false}) =>
      _appleFeed.refresh(
        day: day ?? _calendarDate,
        selected: _selectedAppleCalendars,
        force: force,
      );

  void _appleCalendarChanged() {
    if (mounted && !_loading) setState(() {});
  }

  CalendarEvent _fromApple(SourcedCalendarEvent<ExternalCalendarEvent> record) {
    final event = record.event;
    final source = _appleFeed.sources[record.id.calendar];
    final id = jsonEncode([
      record.id.calendar.accountId,
      record.id.calendar.calendarId,
      record.id.eventId,
      record.id.recurrenceId,
    ]);
    return CalendarEvent(
      id: 'apple:$id',
      title: event.title,
      start: event.start.toLocal(),
      end: event.end.toLocal(),
      category: 'calendar',
      allDay: event.allDay,
      location: event.location,
      description: event.notes,
      sourceLabel: source?.name ?? 'Apple Calendar',
      color: source?.color == null
          ? const Color(0xff4e6c9b)
          : Color(source!.color!),
    );
  }

  Future<void> _openSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => ValueListenableBuilder(
        valueListenable: _features,
        builder: (context, features, _) => SettingsPage(
          sections: [
            SettingsSection(
              title: 'Workspace',
              items: [
                SettingsItem(
                  icon: Icons.tune_rounded,
                  title: 'Features',
                  onTap: _openFeatureSettings,
                ),
                SettingsItem(
                  icon: Icons.adjust_rounded,
                  title: 'Focus modes',
                  subtitle: 'Choose what each mode brings into view',
                  onTap: _openFocusSettings,
                ),
                SettingsItem(
                  icon: Icons.calendar_today_outlined,
                  title: 'Calendars',
                  subtitle: 'Choose which calendars each view shows',
                  onTap: _openCalendarSettings,
                ),
                SettingsItem(
                  icon: Icons.file_copy_outlined,
                  title: 'Calendar files',
                  subtitle: 'Import or export iCalendar files',
                  onTap: _openCalendarFiles,
                ),
                if (features.allows(EasyFeature.nutrition))
                  SettingsItem(
                    icon: Icons.restaurant_outlined,
                    title: 'Nutrition',
                    onTap: _openNutrition,
                  ),
                if (features.allows(EasyFeature.activity))
                  SettingsItem(
                    icon: Icons.timer_outlined,
                    title: 'Activity and routines',
                    onTap: _openActivities,
                  ),
                SettingsItem(
                  icon: Icons.inbox_outlined,
                  title: 'Capture inbox',
                  onTap: () => _openCaptureReview(''),
                ),
              ],
            ),
            SettingsSection(
              title: 'Data',
              items: [
                SettingsItem(
                  icon: Icons.archive_outlined,
                  title: 'Backups',
                  subtitle: 'Export or preview a workspace backup',
                  onTap: _openBackups,
                ),
                if (!kIsWeb && features.allows(EasyFeature.ai))
                  SettingsItem(
                    icon: Icons.auto_awesome_outlined,
                    title: 'AI assistance',
                    subtitle: 'Providers, monthly limit, and usage',
                    onTap: _openAiSettings,
                  ),
                if (LocalTranscriber.supported &&
                    features.allows(EasyFeature.captureMedia))
                  SettingsItem(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Voice transcription',
                    subtitle: 'Optional local speech recognition',
                    onTap: _openVoiceSettings,
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  void _openFeatureSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => FeaturePreferencesPage(
        preferences: _features.value,
        onChanged: (next) async {
          await _commitReviewedData(
            _data,
            _data.withSection(_featuresKey, next.toJson()),
          );
          if (!mounted) return;
          setState(() {
            _features.value = next;
            if (!_availableModes.any((mode) => mode.id == _space)) {
              _space = null;
            }
          });
          final lifecycle = WidgetsBinding.instance.lifecycleState;
          _ai?.setForeground(
            next.allows(EasyFeature.ai) &&
                (lifecycle == null || lifecycle == AppLifecycleState.resumed),
          );
          if (!next.allows(EasyFeature.captureMedia)) {
            _voiceTranscriber.cancel();
          }
          if (next.allows(EasyFeature.ai) && _ai == null && !kIsWeb) {
            unawaited(_prepareAi());
          }
          _refreshCalendarViews();
        },
      ),
    ),
  );

  Future<AiRuntime?> _prepareAi() => _preparingAi ??= _loadAi();

  Future<AiRuntime?> _loadAi() async {
    if (kIsWeb) return null;
    try {
      final state = await (_aiState ??= AiDeviceState.open(
        preferences: _legacyPreferences,
      ));
      if (!mounted) return null;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final runtime = AiRuntime(
        read: state.read,
        compareAndSwap: state.compareAndSwap,
        vault: const AiSystemCredentialVault(),
        foreground:
            _allows(EasyFeature.ai) &&
            (lifecycle == null || lifecycle == AppLifecycleState.resumed),
      );
      _ai = runtime;
      await runtime.load();
      if (mounted) setState(() {});
      return runtime;
    } catch (_) {
      _aiState = null;
      _preparingAi = null;
      return null;
    }
  }

  Future<void> _openAiSettings() async {
    if (!_allows(EasyFeature.ai)) return;
    final runtime = await _prepareAi();
    if (!mounted) return;
    if (runtime == null) {
      _inform('AI settings could not be opened on this device.');
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => AiSettingsPage(runtime: runtime)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _loadVoiceSettings() async {
    try {
      final saved = await _legacyPreferences.getString(_voiceSettingsKey);
      if (!mounted || saved == null) return;
      _voiceConfig = VoiceTranscriptionConfig.fromJson(
        jsonDecode(saved) as Map<String, dynamic>,
      );
    } catch (_) {
      // Reopen settings to select a runtime when configuration is unavailable.
    }
  }

  void _openVoiceSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => VoiceTranscriptionSettings(
        initialConfig: _voiceConfig,
        onSave: (config) async {
          if (config == null) {
            await _legacyPreferences.remove(_voiceSettingsKey);
          } else {
            await _legacyPreferences.setString(
              _voiceSettingsKey,
              jsonEncode(config.toJson()),
            );
          }
          if (mounted) _voiceConfig = config;
        },
      ),
    ),
  );

  void _openFocusSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => FocusModesPage(
        modes: _modes,
        categories: _categories(),
        onChanged: _changeFocusModes,
      ),
    ),
  );

  void _openCalendarSettings() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => CalendarSettingsPage(
        adapter: _allows(EasyFeature.externalCalendars)
            ? const EventKitCalendarAdapter()
            : const EventKitCalendarAdapter(platform: TargetPlatform.linux),
        isAppleCalendar: (id) =>
            _allows(EasyFeature.externalCalendars) && _isAppleCalendar(id),
        initialPreferences:
            _calendarPreferences ?? _defaultCalendarPreferences(),
        onChanged: _changeCalendarPreferences,
        modes: {for (final mode in _modes) mode.id: mode.name},
        localSources: [
          for (final entry in {'': 'General', ..._categories()}.entries)
            CalendarSource(
              id: _localCalendar(entry.key),
              name: entry.value,
              accountName: appName,
              capabilities: CalendarCapability.values,
            ),
          for (final source in _icsCalendars)
            CalendarSource(
              id: source.identity,
              name: source.name,
              accountName: 'Imported',
            ),
        ],
      ),
    ),
  );

  void _openCalendarFiles() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, rebuild) => Scaffold(
          appBar: AppBar(title: const Text('Calendar files')),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 660),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.import_export_rounded),
                      title: const Text('Import or export events'),
                      subtitle: Text('$appName calendars'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        await _openIcsTransfer();
                        if (context.mounted) rebuild(() {});
                      },
                    ),
                    if (_icsCalendars.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        'Imported calendars',
                        style: sectionHeadingStyle,
                      ),
                      const SizedBox(height: 7),
                      for (final source in _icsCalendars)
                        ListTile(
                          leading: const Icon(Icons.calendar_today_outlined),
                          title: Text(source.name),
                          onTap: () async {
                            await _openIcsTransfer(source);
                            if (context.mounted) rebuild(() {});
                          },
                          trailing: IconButton(
                            tooltip: 'Remove ${source.name}',
                            onPressed: () async {
                              await _removeIcsCalendar(source);
                              if (context.mounted) rebuild(() {});
                            },
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _openIcsTransfer([WorkspaceIcsCalendar? source]) async {
    final IcsCalendar export;
    try {
      export = source != null
          ? await compute(IcsCalendar.parse, source.document)
          : exportIcsRecords([
              for (final event in _data.events)
                IcsExportRecord(
                  uid: event.id,
                  title: event.title,
                  start: event.start,
                  end: event.end.isAfter(event.start) ? event.end : null,
                  allDay: event.allDay,
                  location: event.location,
                  description: event.description,
                ),
            ], name: appName);
    } catch (_) {
      if (mounted) _inform('This calendar could not be opened.');
      return;
    }
    if (!mounted) return;
    final exportName = (source?.name ?? '$appName Calendar')
        .replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '_')
        .trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => IcsTransferPage(
          initialDate: _calendarDate,
          exportCalendar: export,
          exportName: '${exportName.isEmpty ? appName : exportName}.ics',
          pickFile: _pickIcsFile,
          saveFile: _saveIcsFile,
          onApply: _addIcsCalendar,
        ),
      ),
    );
  }

  Future<String?> _pickIcsFile() async {
    final bytes = await _pickFileBytes(WorkspaceIcsCalendar.importByteLimit);
    if (bytes == null) return null;
    return compute(_normalizeIcsFile, bytes);
  }

  Future<bool> _saveIcsFile(String name, String contents) async {
    try {
      await _exportFile(
        Uint8List.fromList(utf8.encode(contents)),
        name,
        'text/calendar',
      );
      return true;
    } on BackupExportCancelled {
      return false;
    }
  }

  Future<void> _addIcsCalendar(IcsTransferSelection selection) async {
    if (_icsCalendars.any((source) => source.id == selection.importId)) return;
    if (_icsCalendars.length == WorkspaceIcsCalendar.maxCalendars) {
      throw const FormatException(
        'Remove an imported calendar to add another.',
      );
    }
    final title = selection.calendar.name?.trim();
    final source = WorkspaceIcsCalendar(
      id: selection.importId,
      name: title == null || title.isEmpty ? 'Imported calendar' : title,
      document: selection.calendar.encode(),
    );
    var preferences = _calendarPreferences ?? _defaultCalendarPreferences();
    preferences = preferences.withCalendars(null, {
      ...preferences.allCalendars,
      source.identity,
    });
    if (_space case final mode?) {
      preferences = preferences.withCalendars(mode, {
        ...preferences.calendarsFor(mode),
        source.identity,
      });
    }
    await _storeIcsCalendars(
      [..._icsCalendars, source],
      preferences,
      operationId: 'ics-import-${source.id}',
    );
  }

  Future<void> _removeIcsCalendar(WorkspaceIcsCalendar source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove imported calendar?'),
        content: Text(
          'Remove ${source.name} and its events from this workspace.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    var preferences = _calendarPreferences ?? _defaultCalendarPreferences();
    for (final mode in <String?>[
      null,
      ...preferences.memberships.byMode.keys,
    ]) {
      preferences = preferences.withCalendars(
        mode,
        preferences.calendarsFor(mode).where((id) => id != source.identity),
      );
    }
    try {
      await _storeIcsCalendars(
        _icsCalendars.where((calendar) => calendar.id != source.id).toList(),
        preferences,
      );
    } catch (_) {
      if (mounted) _inform('The imported calendar could not be removed.');
    }
  }

  Future<void> _storeIcsCalendars(
    List<WorkspaceIcsCalendar> sources,
    CalendarSourcePreferences preferences, {
    String? operationId,
  }) async {
    final previous = _data;
    await _commitReviewedData(
      previous,
      previous
          .withSection(_icsCalendarsKey, [
            for (final source in sources) source.toJson(),
          ])
          .withSection(_calendarPreferencesKey, preferences.toJson()),
      operationId: operationId,
    );
    if (!mounted) return;
    setState(() {
      _icsCalendars = List.unmodifiable(sources);
      _calendarPreferences = preferences;
    });
    _refreshCalendarViews();
  }

  Future<void> _openBackups() async {
    await _pendingSave;
    final store = _store;
    if (!mounted || store == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => WorkspaceBackupPage(
          store: store,
          pickBackup: _pickBackup,
          exportBackup: _exportBackup,
          onRestored: _loadRevision,
        ),
      ),
    );
  }

  Future<Uint8List?> _pickBackup() => _pickFileBytes(193 * 1024 * 1024);

  Future<Uint8List?> _pickFileBytes(int limit) async {
    final file = await openFile();
    if (file == null) return null;
    if (await file.length() > limit) {
      throw const FormatException('The selected file is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('The selected file is too large.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<void> _exportBackup(Uint8List bytes, String filename) =>
      _exportFile(bytes, filename, 'application/octet-stream');

  Future<void> _exportFile(
    Uint8List bytes,
    String filename,
    String mimeType,
  ) async {
    final file = XFile.fromData(bytes, mimeType: mimeType);
    if (!kIsWeb &&
        const {
          TargetPlatform.linux,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        }.contains(defaultTargetPlatform)) {
      final destination = await getSaveLocation(suggestedName: filename);
      if (destination == null) throw const BackupExportCancelled();
      await file.saveTo(destination.path);
      return;
    }
    if (!mounted) throw const BackupExportCancelled();
    final center = MediaQuery.sizeOf(context).center(Offset.zero);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [file],
        fileNameOverrides: [filename],
        sharePositionOrigin: Rect.fromCenter(
          center: center,
          width: 1,
          height: 1,
        ),
      ),
    );
    if (result.status == ShareResultStatus.dismissed) {
      throw const BackupExportCancelled();
    }
  }

  void _openNutrition() {
    if (!_allows(EasyFeature.nutrition)) return;
    final NutritionData nutrition;
    try {
      nutrition = _nutritionData();
    } on Object {
      _inform('Your nutrition records could not be opened.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => NutritionPage(
          foods: nutrition.foods,
          meals: nutrition.meals,
          onChanged: (values) =>
              _update(_data.withSection(_nutritionKey, values.toJson())),
          onAttachPhoto: kIsWeb || !_allows(EasyFeature.captureMedia)
              ? null
              : _attachMealPhoto,
          onViewPhoto: _allows(EasyFeature.captureMedia)
              ? _viewMealPhoto
              : null,
        ),
      ),
    );
  }

  NutritionData _nutritionData() {
    final saved = _data.sections[_nutritionKey];
    return saved == null
        ? NutritionData()
        : NutritionData.fromJson(saved as Map<String, dynamic>);
  }

  ActivityData _activityData() {
    final saved = _data.sections[_activitiesKey];
    return saved == null
        ? ActivityData()
        : ActivityData.fromJson(saved as Map<String, dynamic>);
  }

  void _openActivities() {
    if (!_allows(EasyFeature.activity)) return;
    final ActivityData data;
    try {
      data = _activityData();
    } on Object {
      _inform('Your activity records could not be opened.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ActivitiesPage(
          data: data,
          onChanged: (value) => _commitReviewedData(
            _data,
            _data.withSection(_activitiesKey, value.toJson()),
          ),
          targets: [
            for (final task in _data.tasks)
              ActivityTarget(
                id: task.id,
                title: task.title,
                category: task.category,
                kind: ActivityTargetKind.task,
              ),
            for (final event in _data.events)
              if (event.end.isAfter(event.start) && !event.allDay)
                ActivityTarget(
                  id: event.id,
                  title: event.title,
                  category: event.category,
                  kind: ActivityTargetKind.event,
                  plan: ActivityWindow(event.start, event.end),
                ),
          ],
        ),
      ),
    );
  }

  Future<AttachmentStore?> _openAttachments() async {
    try {
      return await (_attachmentStore ??= openAttachmentStore());
    } on Object {
      _attachmentStore = null;
      rethrow;
    }
  }

  Future<AttachmentRef?> _attachMealPhoto() async {
    final store = await _openAttachments();
    if (!mounted || store == null) return null;
    final isPhone = const {
      TargetPlatform.iOS,
      TargetPlatform.android,
    }.contains(defaultTargetPlatform);
    final XFile? picked;
    if (isPhone) {
      final source = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose photo'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (source == null || !mounted) return null;
      picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2560,
        maxHeight: 2560,
        requestFullMetadata: false,
      );
    } else {
      picked = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Meal photos',
            extensions: ['jpg', 'jpeg', 'png', 'heic'],
          ),
        ],
      );
    }
    if (picked == null) return null;
    return store.putStream(
      picked.openRead(),
      kind: AttachmentKind.photo,
      expectedLength: await picked.length(),
    );
  }

  Future<void> _viewMealPhoto(AttachmentRef ref) async {
    final store = await _openAttachments();
    final photo = await store?.read(ref.id);
    if (!mounted) return;
    if (photo == null) {
      _inform('This photo is unavailable on this device.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 650),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: IconButton(
                  tooltip: 'Close photo',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              Flexible(
                child: Image.memory(
                  photo.bytes,
                  fit: BoxFit.contain,
                  semanticLabel: 'Meal photo',
                  errorBuilder: (context, error, stack) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'This device cannot display this photo format.',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _inform(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _openWorkoutPlans() async {
    final plans = _workoutPlans;
    if (!mounted) return;
    if (plans == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout plans could not be opened.')),
      );
      return;
    }
    setState(() => _workoutPlans = plans);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileModeFrame(
          mode: 'gym',
          child: WorkoutPlansPage(plans: plans, onChanged: _saveWorkoutPlans),
        ),
      ),
    );
  }

  void _saveWorkoutPlans(List<WorkoutPlan> plans) {
    if (!mounted) return;
    setState(() => _workoutPlans = List.unmodifiable(plans));
    _persistWorkoutPlans();
  }

  void _persistWorkoutPlans() {
    final snapshot = _workoutPlans!.map((plan) => plan.encode()).toList();
    _queueSave(
      () => _saveMutation(WorkspaceMutation.workoutPlans(snapshot)),
      _persistWorkoutPlans,
    );
  }

  void _update(WorkspaceData data) {
    setState(() => _assignData(data));
    final snapshot = data.encode();
    _queueSave(
      () => _saveMutation(WorkspaceMutation.workspace(snapshot)),
      () => _update(_data),
    );
  }

  void _assignData(WorkspaceData data) {
    if (!identical(data.tasks, _data.tasks) ||
        !identical(data.events, _data.events) ||
        !identical(data.notes, _data.notes)) {
      _contentRevision++;
    }
    _data = data;
    if (_inspected case final TaskItem selected) {
      _inspected = data.tasks
          .where((task) => task.id == selected.id)
          .firstOrNull;
    }
  }

  Future<void> _saveMutation(
    WorkspaceMutation mutation, {
    String? operationId,
  }) async {
    final saved = await _store!.save(
      mutation,
      expectedRevision: _persistedRevision,
      operationId: operationId,
    );
    _persistedRevision = saved.revision;
  }

  Future<void> _commitReviewedData(
    WorkspaceData previous,
    WorkspaceData updated, {
    String? operationId,
    List<GymSession>? sessions,
  }) {
    if (_reviewSaving) {
      return Future.error(StateError('A reviewed change is being saved.'));
    }
    final previousSessions = _gymSessions;
    setState(() => _reviewSaving = true);
    final operation = _pendingSave.then((_) async {
      try {
        if (!mounted ||
            !identical(_data, previous) ||
            (sessions != null && !identical(_gymSessions, previousSessions))) {
          throw StateError('The workspace changed after review.');
        }
        final workspace = updated.encode();
        final WorkspaceMutation mutation;
        if (sessions == null) {
          mutation = WorkspaceMutation.workspace(workspace);
        } else {
          final state = await _store!.read();
          if (state.revision != _persistedRevision) {
            throw StateError('The workspace changed after review.');
          }
          mutation = WorkspaceMutation.replace(
            WorkspaceSnapshot(
              workspaceJson: workspace,
              gymSessionJson: [
                for (final session in sessions) session.encode(),
              ],
              workoutPlanJson: state.snapshot.workoutPlanJson,
            ),
          );
        }
        await _saveMutation(mutation, operationId: operationId);
        if (mounted) {
          setState(() {
            _assignData(updated);
            if (sessions != null) _gymSessions = List.unmodifiable(sessions);
          });
        }
      } finally {
        if (mounted) setState(() => _reviewSaving = false);
      }
    });
    _pendingSave = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  void _queueSave(Future<void> Function() write, VoidCallback retry) {
    _pendingSave = _pendingSave.then((_) async {
      try {
        await write();
      } on WorkspaceRevisionConflict {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This workspace changed in another window.'),
          ),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Changes could not be saved on this device.'),
            action: SnackBarAction(label: 'Retry', onPressed: retry),
          ),
        );
      }
    });
  }

  Future<void> _openGymSession({WorkoutPlan? plan}) async {
    final sessions = _gymSessions;
    if (!mounted) return;
    if (sessions == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gym sessions could not be opened.')),
      );
      return;
    }
    _gymSessions = sessions;
    final latest = sessions.lastOrNull;
    final GymSession session;
    if (latest != null && !latest.finished) {
      session = latest;
    } else {
      session = GymSession.start(plan: plan);
      _saveGymSession(session);
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileModeFrame(
          mode: 'gym',
          child: GymSessionPage(session: session, onChanged: _saveGymSession),
        ),
      ),
    );
  }

  ({WorkoutPlan plan, DateTime date})? _nextWorkout() {
    ({WorkoutPlan plan, DateTime date})? next;
    for (final plan in _workoutPlans ?? const <WorkoutPlan>[]) {
      var date = plan.schedule.nextOnOrAfter(_today);
      while (date != null && _completedWorkout(plan.id, date)) {
        date = plan.schedule.nextOnOrAfter(plusDays(date, 1));
      }
      if (date != null && (next == null || date.isBefore(next.date))) {
        next = (plan: plan, date: date);
      }
    }
    return next;
  }

  bool _completedWorkout(String planId, DateTime date) =>
      _gymSessions?.any(
        (session) =>
            session.finished &&
            session.planId == planId &&
            sameDay(session.startedAt.toLocal(), date),
      ) ??
      false;

  Widget _gymOverview(BuildContext context) {
    final session = _gymSessions?.lastOrNull;
    final active = session != null && !session.finished;
    final next = active ? null : _nextWorkout();
    final today = next != null && sameDay(next.date, _today);
    return GymWorkoutOverview(
      workoutName: active ? session.workoutTitle : next?.plan.name,
      scheduleLabel: active
          ? 'In progress'
          : next == null
          ? null
          : today
          ? 'Today'
          : MaterialLocalizations.of(context).formatMediumDate(next.date),
      exercises: active
          ? [
              for (final name in session.upcomingExercises)
                (name: name, detail: ''),
            ]
          : [
              for (final exercise
                  in next?.plan.exercises ?? const <WorkoutExercise>[])
                (
                  name: exercise.name,
                  detail: _workoutExerciseSummary(exercise),
                ),
            ],
      active: active,
      canStart: today,
      onWorkout: () => _openGymSession(plan: next?.plan),
      onPlans: _openWorkoutPlans,
      onFreestyle: _openGymSession,
      onHistory: (_gymSessions?.any((session) => session.finished) ?? false)
          ? _openGymHistory
          : null,
    );
  }

  void _openGymHistory() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (routeContext) => MobileModeFrame(
        mode: 'gym',
        child: GymHistoryPage(
          sessions: _gymSessions ?? const [],
          onOpen: (session) => Navigator.of(routeContext).push<void>(
            MaterialPageRoute(
              builder: (_) => MobileModeFrame(
                mode: 'gym',
                child: GymSessionPage(
                  session: session,
                  onChanged: _saveGymSession,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void _saveGymSession(GymSession? session) {
    if (session == null || !mounted) return;
    final sessions = _gymSessions!;
    final index = sessions.indexWhere(
      (value) => value.startedAt == session.startedAt,
    );
    final updated = [...sessions];
    if (index == -1) {
      updated.add(session);
    } else {
      updated[index] = session;
    }
    setState(() => _gymSessions = updated);
    _persistGymSessions();
  }

  void _persistGymSessions() {
    final snapshot = _gymSessions!.map((session) => session.encode()).toList();
    _queueSave(
      () => _saveMutation(WorkspaceMutation.gymSessions(snapshot)),
      _persistGymSessions,
    );
  }

  void _navigate(_Destination destination) {
    setState(() {
      _destination = destination;
      _inspected = null;
    });
  }

  void _changeDate(DateTime date) {
    final day = dateOnly(date);
    if (day != _calendarDate) {
      setState(() => _calendarDate = day);
      _refreshCalendarViews();
    }
  }

  void _changeSpace(String? space) {
    setState(() {
      _space = space;
      _inspected = null;
    });
  }

  void _toggleTask(TaskItem task) {
    final done = !task.done;
    _setTaskDone(task.id, done);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done ? 'Task completed' : 'Task reopened'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _setTaskDone(task.id, task.done),
        ),
      ),
    );
  }

  void _setTaskDone(String id, bool done) {
    final task = _data.tasks.where((task) => task.id == id).firstOrNull;
    if (task == null || task.done == done) return;
    _saveRecord(task.withDone(done));
  }

  List<T> _upsert<T>(List<T> records, T updated, String Function(T) id) => [
    for (final existing in records)
      if (id(existing) == id(updated)) updated else existing,
    if (!records.any((existing) => id(existing) == id(updated))) updated,
  ];

  void _saveRecord(Object record) {
    if (record is CalendarEvent && record.isReadOnly) return;
    if (record is TaskItem) {
      final previous = _data.tasks
          .where((task) => task.id == record.id)
          .firstOrNull;
      if (previous?.parentId != record.parentId) {
        final issue = taskParentIssue(_data.tasks, record.id, record.parentId);
        if (issue != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(issue.message)));
          return;
        }
      }
      if (!listEquals(
        previous?.prerequisiteIds ?? const [],
        record.prerequisiteIds,
      )) {
        final issue = taskPrerequisiteIssue(
          _data.tasks,
          record.id,
          record.prerequisiteIds,
        );
        if (issue != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(issue.message)));
          return;
        }
      }
      if (previous?.allowSplit != record.allowSplit ||
          previous?.estimatedMinutes != record.estimatedMinutes ||
          previous?.minimumChunkMinutes != record.minimumChunkMinutes) {
        final issue = taskSplitIssue(
          allowSplit: record.allowSplit,
          minimumChunkMinutes: record.minimumChunkMinutes,
          estimatedMinutes: record.estimatedMinutes,
        );
        if (issue != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(issue)));
          return;
        }
      }
    }
    final data = switch (record) {
      CalendarEvent event => _data.copyWith(
        events: _upsert(_data.events, event, (value) => value.id),
      ),
      TaskItem task => _data.copyWith(
        tasks: _upsert(_data.tasks, task, (value) => value.id),
      ),
      NoteItem note => _data.copyWith(
        notes: _upsert(_data.notes, note, (value) => value.id),
      ),
      _ => _data,
    };
    if (_inspected != null && _recordId(_inspected!) == _recordId(record)) {
      _inspected = record;
    }
    _update(data);
  }

  Future<void> _deleteRecord(Object record) async {
    if (record is CalendarEvent && record.isReadOnly) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_recordKind(record).name}?'),
        content: Text(_recordTitle(record)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_inspected == record) _inspected = null;
    final id = _recordId(record);
    final detached = {
      if (record is TaskItem)
        for (final child in _data.tasks)
          if (child.parentId == id) child.id: child.withParent(null),
    };
    _update(
      _data.copyWith(
        events: record is CalendarEvent
            ? _data.events.where((item) => item.id != id).toList()
            : _data.events,
        tasks: record is TaskItem
            ? [
                for (final task in _data.tasks)
                  if (task.id != id) detached[task.id] ?? task,
              ]
            : _data.tasks,
        notes: record is NoteItem
            ? _data.notes.where((item) => item.id != id).toList()
            : _data.notes,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${spaceName(_recordKind(record).name)} deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (record is TaskItem) {
              _restoreTask(record, detached);
            } else {
              _saveRecord(record);
            }
          },
        ),
      ),
    );
  }

  void _restoreTask(TaskItem saved, Map<String, TaskItem> detached) {
    if (_data.tasks.any((task) => task.id == saved.id)) return;
    final restored =
        taskParentIssue(_data.tasks, saved.id, saved.parentId) == null
        ? saved
        : saved.withParent(null);
    final candidates = [..._data.tasks, restored];
    final tasks = [
      for (final task in candidates)
        if (identical(detached[task.id], task) &&
            taskParentIssue(candidates, task.id, restored.id) == null)
          task.withParent(restored.id)
        else
          task,
    ];
    _update(_data.copyWith(tasks: tasks));
  }

  NoteItem? _homeNote() {
    NoteItem? latest;
    final mode = _focus;
    for (final note in _data.notes) {
      if (mode == null && (note.category != null || !note.noteToSelf)) continue;
      if (mode != null && !mode.includes(note.category?.toLowerCase())) {
        continue;
      }
      if (latest == null ||
          (note.noteToSelf && !latest.noteToSelf) ||
          (note.noteToSelf == latest.noteToSelf &&
              note.updated.isAfter(latest.updated))) {
        latest = note;
      }
    }
    return latest;
  }

  Future<Object?> _showEditor(Widget editor) {
    if (MediaQuery.sizeOf(context).width < 720) {
      return showModalBottomSheet<Object>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: paper,
        builder: (_) => editor,
      );
    }
    return showDialog<Object>(
      context: context,
      builder: (_) => Dialog(backgroundColor: paper, child: editor),
    );
  }

  Future<void> _capture({RecordKind? kind, bool noteToSelf = false}) async {
    if (_reviewSaving) return;
    final destination = _destination;
    final captureKind =
        kind ??
        switch (destination) {
          _Destination.calendar => RecordKind.event,
          _Destination.notes => RecordKind.note,
          _ => RecordKind.task,
        };
    final calendar = _calendarPreferences?.defaultWriteCalendar;
    final result = await _showEditor(
      QuickCapture(
        date: destination == _Destination.calendar ? _calendarDate : _today,
        kind: captureKind,
        initialTaskDate: _today,
        initialCategory:
            captureKind == RecordKind.event &&
                calendar?.accountId == _localCalendarAccount
            ? calendar!.calendarId
            : _focus?.preferredCategory,
        categories: _categories(),
        noteToSelf: noteToSelf,
        allowReview: !noteToSelf,
        allowVoice: !noteToSelf && !kIsWeb && _allows(EasyFeature.captureMedia),
      ),
    );
    if (result == null || !mounted) return;
    if (result case final CaptureReviewRequest request) {
      await _openCaptureReview(request.text);
      return;
    }
    if (result case final VoiceCaptureRequest request) {
      await _openVoiceCapture(initialText: request.text);
      return;
    }
    _saveRecord(result);
    if (result is CalendarEvent && destination == _Destination.calendar) {
      _changeDate(result.start);
    }
  }

  Future<void> _planDay() async {
    if (_reviewSaving || _planningDay || !_allows(EasyFeature.planning)) return;
    _planningDay = true;
    try {
      await _previewAndApplyPlan();
    } finally {
      _planningDay = false;
    }
  }

  Future<void> _previewAndApplyPlan() async {
    final day = _today;
    final appointments = await _planningCalendar(day);
    if (!mounted || appointments == null) return;
    final prior = _data;
    final result = await _showEditor(
      PlanDaySheet(
        day: day,
        events: [...prior.events, ...appointments],
        tasks: prior.tasks,
      ),
    );
    if (!mounted || result is! PlanSelection || result.tasks.isEmpty) return;
    final finalAppointments = await _planningCalendar(day);
    if (!mounted || finalAppointments == null) return;
    final checkedFeed = _appleFeed.events;
    final checkedImports = _icsFeed.events;
    final beforeAcceptance = _data;
    final current = await compute(_reviewSchedule, (
      window: result.window,
      reservationStart: result.reservationStart,
      events: [...beforeAcceptance.events, ...finalAppointments],
      tasks: beforeAcceptance.tasks,
    ));
    if (!mounted) return;
    final available = {
      for (final entry in current.scheduled) entry.task.id: entry,
    };
    final selectedIds = result.tasks.map((item) => item.task.id).toSet();
    final completedIds = {
      for (final task in beforeAcceptance.tasks)
        if (task.done) task.id,
    };
    final now = DateTime.now();
    if (!identical(beforeAcceptance, _data) ||
        !identical(checkedFeed, _appleFeed.events) ||
        !identical(checkedImports, _icsFeed.events) ||
        selectedIds.length != result.tasks.length ||
        result.tasks.any((entry) {
          final checked = available[entry.task.id];
          return checked == null ||
              !_samePlanBlocks(entry.blocks, checked.blocks) ||
              entry.blocks.any((block) => block.start.isBefore(now)) ||
              checked.task.prerequisites.any(
                (id) => !completedIds.contains(id) && !selectedIds.contains(id),
              );
        })) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The available time changed. Preview the day again.'),
        ),
      );
      return;
    }

    final operationId = 'schedule-${now.microsecondsSinceEpoch}';
    var index = 0;
    final events = [
      ...beforeAcceptance.events,
      for (final entry in result.tasks)
        for (final block in available[entry.task.id]!.blocks)
          CalendarEvent(
            id: '$operationId-${index++}',
            title: available[entry.task.id]!.task.title,
            start: block.start,
            end: block.end,
            category: available[entry.task.id]!.task.category,
            plannedTaskId: entry.task.id,
          ),
    ];
    try {
      await _commitReviewedData(
        beforeAcceptance,
        beforeAcceptance.copyWith(events: events),
        operationId: operationId,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The plan could not be saved. Preview it again.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    _changeDate(result.window.start);
    _navigate(_Destination.calendar);
  }

  Future<List<CalendarEvent>?> _planningCalendar(DateTime day) async {
    final apple = _selectedAppleCalendars;
    final imports = _selectedIcsCalendars;
    if (apple.isEmpty && imports.isEmpty) return const [];
    await Future.wait<void>([
      if (apple.isNotEmpty) _refreshExternalCalendars(day: day, force: true),
      if (imports.isNotEmpty) _icsFeed.refresh(day: day, calendars: imports),
    ]);
    if (!mounted) return null;
    if (apple.isNotEmpty &&
        (_appleFeed.problem != null || !_appleFeed.covers(day))) {
      _inform(_appleFeed.problem ?? 'Apple calendars could not be refreshed.');
      return null;
    }
    if (imports.isNotEmpty &&
        (_icsFeed.problem != null || !_icsFeed.covers(day))) {
      _inform(_icsFeed.problem ?? 'Imported calendars could not be refreshed.');
      return null;
    }
    return [
      ..._appleFeed.events.map(_fromApple),
      for (final row in _icsFeed.events) row.event,
    ];
  }

  Future<void> _openVoiceCapture({
    ValueNotifier<HeldVoiceAction>? heldAction,
    String initialText = '',
  }) async {
    if (_reviewSaving ||
        _recordingVoice ||
        kIsWeb ||
        !_allows(EasyFeature.captureMedia)) {
      return;
    }
    _recordingVoice = true;
    try {
      final sheet = VoiceCaptureSheet(
        heldAction: heldAction,
        onSave: (bytes, recordedAt) =>
            _saveVoiceDraft(bytes, recordedAt, initialText),
      );
      final CaptureArchiveEntry? draft;
      if (MediaQuery.sizeOf(context).width < 720) {
        draft = await showModalBottomSheet<CaptureArchiveEntry>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: paper,
          builder: (_) => sheet,
        );
      } else {
        draft = await showDialog<CaptureArchiveEntry>(
          context: context,
          barrierDismissible: false,
          builder: (_) => Dialog(backgroundColor: paper, child: sheet),
        );
      }
      if (!mounted || draft == null) return;
      await _openCaptureReview(draft.text, draft: draft);
    } finally {
      _recordingVoice = false;
    }
  }

  Future<CaptureArchiveEntry> _saveVoiceDraft(
    Uint8List bytes,
    DateTime recordedAt,
    String text,
  ) async {
    final store = await _openAttachments();
    if (store == null) throw StateError('Voice storage is unavailable.');
    final audio = await store.putStream(
      Stream.value(bytes),
      kind: AttachmentKind.audio,
      declaredMimeType: 'audio/wav',
      expectedLength: bytes.length,
    );
    final previous = _data;
    final id = 'voice-${recordedAt.microsecondsSinceEpoch}';
    final existing = previous.captures
        .where((record) => record.id == id)
        .firstOrNull;
    if (existing != null) {
      if (existing.audio?.id == audio.id) return existing;
      throw StateError('A different recording already uses this draft.');
    }
    final draft = CaptureArchiveEntry(
      id: id,
      text: text.trim(),
      capturedAt: recordedAt,
      audio: audio,
    );
    await _commitReviewedData(
      previous,
      previous.copyWith(captures: [...previous.captures, draft]),
      operationId: '$id-draft-1',
    );
    return draft;
  }

  Future<void> _playVoiceDraft(CaptureArchiveEntry draft) async {
    final ref = draft.audio;
    if (ref == null) return;
    try {
      final store = await _openAttachments();
      final audio = await store?.read(ref.id);
      if (!mounted) return;
      if (audio == null) {
        _inform('This recording is unavailable on this device.');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => VoicePlaybackDialog(audio: audio),
      );
    } catch (_) {
      if (mounted) _inform('The recording could not be opened.');
    }
  }

  Future<void> _openCaptureReview(
    String text, {
    CaptureArchiveEntry? draft,
  }) async {
    final runtime = _ai;
    final aiAvailable =
        _allows(EasyFeature.ai) &&
        runtime != null &&
        runtime.settings.route != AiRoute.offline;
    final mediaAvailable = _allows(EasyFeature.captureMedia);
    final sheet = CaptureReviewSheet(
      initialText: text,
      drafts: _data.captures,
      onReview: _reviewCaptureText,
      onApply: _applyCaptureReview,
      initialDraft: draft,
      onPlayDraft: mediaAvailable ? _playVoiceDraft : null,
      onAiReview: aiAvailable ? _reviewCaptureWithAi : null,
      onCancelAi: aiAvailable ? runtime.cancelCurrent : null,
      onTranscribe: mediaAvailable && _voiceConfig != null
          ? _transcribeDraft
          : null,
      onCancelTranscription: _voiceTranscriber.cancel,
      disabledKinds: {
        if (!_allows(EasyFeature.nutrition)) CaptureIntentKind.meal,
        if (!_allows(EasyFeature.workouts)) CaptureIntentKind.workout,
      },
    );
    if (MediaQuery.sizeOf(context).width < 720) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: paper,
        builder: (_) => sheet,
      );
    } else {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(backgroundColor: paper, child: sheet),
      );
    }
  }

  Future<CaptureArchiveEntry> _transcribeDraft(
    CaptureArchiveEntry draft,
  ) async {
    final config = _voiceConfig;
    final ref = draft.audio;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (config == null ||
        ref == null ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      throw StateError('Local transcription is unavailable.');
    }
    final store = await _openAttachments();
    final audio = await store?.read(ref.id);
    if (audio == null || !mounted) {
      throw StateError('Recording is unavailable.');
    }
    final transcript = await _voiceTranscriber.transcribe(config, audio.bytes);
    final current = _data.captures
        .where((source) => source.id == draft.id)
        .firstOrNull;
    if (!mounted ||
        current?.revision != draft.revision ||
        current?.applied != false) {
      throw StateError('The draft changed while transcribing.');
    }
    return _saveCaptureDraft(draftId: draft.id, text: transcript);
  }

  CaptureInput _captureInput(CaptureArchiveEntry source) => CaptureInput(
    id: source.id,
    revision: source.revision,
    text: source.text,
    context: CaptureContext(
      anchor: source.capturedAt,
      revision: _contentRevision,
      focusCategory: _focus?.preferredCategory,
      selectedRecordId: _inspected == null ? null : _recordId(_inspected!),
      categories: _categories(),
      records: [
        for (final task in _data.tasks)
          CaptureRecordRef(
            id: task.id,
            kind: CaptureIntentKind.task,
            title: task.title,
            revision: _contentRevision,
            category: task.category,
            completed: task.done,
          ),
      ],
    ),
  );

  Future<CaptureReview> _reviewCaptureText({
    String? draftId,
    required String text,
  }) async => interpretCapture(
    _captureInput(await _saveCaptureDraft(draftId: draftId, text: text)),
  );

  Future<({CaptureArchiveEntry? draft, CaptureReview? review, String? message})>
  _reviewCaptureWithAi(
    BuildContext sheetContext, {
    String? draftId,
    required String text,
  }) async {
    final draft = await _saveCaptureDraft(draftId: draftId, text: text);
    final runtime = _ai;
    if (runtime == null || !sheetContext.mounted) {
      return (draft: draft, review: null, message: 'The capture is saved.');
    }
    final outcome = await runtime.runCapture(
      input: _captureInput(draft),
      currentRevision: _captureRevision,
      authorize: (preview) => sheetContext.mounted
          ? showAiTransmissionDialog(sheetContext, preview)
          : Future.value(false),
    );
    return (
      draft: draft,
      review: outcome.value,
      message:
          outcome.message ??
          (outcome.value == null
              ? 'The capture is saved. You can review it on this device.'
              : null),
    );
  }

  AiCaptureRevision? _captureRevision(String id) {
    if (!mounted || _loading) return null;
    final entry = _data.captures.where((draft) => draft.id == id).firstOrNull;
    return entry == null || entry.applied
        ? null
        : (sourceRevision: entry.revision, contextRevision: _contentRevision);
  }

  Future<CaptureArchiveEntry> _saveCaptureDraft({
    String? draftId,
    required String text,
  }) async {
    if (text.trim().isEmpty || text.length > 12000) {
      throw ArgumentError('Capture text is outside the supported range.');
    }
    final previous = _data;
    final old = previous.captures
        .where((entry) => entry.id == draftId)
        .firstOrNull;
    if (old?.applied == true) {
      throw StateError('This capture is already applied.');
    }
    final now = DateTime.now();
    final source = old == null
        ? CaptureArchiveEntry(
            id: 'capture-${now.microsecondsSinceEpoch}',
            text: text,
            capturedAt: now,
          )
        : old.text == text
        ? old
        : old.revised(text);
    if (!identical(source, old)) {
      await _commitReviewedData(
        previous,
        previous.copyWith(
          captures: _upsert(previous.captures, source, (entry) => entry.id),
        ),
        operationId: '${source.id}-draft-${source.revision}',
      );
    }
    return source;
  }

  Future<String?> _applyCaptureReview(
    CaptureReview review,
    List<CaptureProposal> selected,
  ) async {
    final previous = _data;
    final source = previous.captures
        .where((entry) => entry.id == review.input.id)
        .firstOrNull;
    if (source == null ||
        source.applied ||
        !review.isCurrentFor(_captureInput(source))) {
      return 'This capture changed. Review it again before adding items.';
    }
    if (selected.isEmpty ||
        selected.toSet().length != selected.length ||
        selected.any(
          (entry) => !entry.isReady || !review.proposals.contains(entry),
        )) {
      return 'Choose the ready items you want to add.';
    }

    final tasks = [...previous.tasks];
    final events = [...previous.events];
    final notes = [...previous.notes];
    List<GymSession>? gym;
    GymSession? capturedSession;
    NutritionData? nutrition;
    for (final proposal in selected) {
      final draft = proposal.draft;
      final id = '${source.id}-${source.revision}-${proposal.span.start}';
      if (tasks.any((record) => record.id == id) ||
          events.any((record) => record.id == id) ||
          notes.any((record) => record.id == id)) {
        return 'An item from this capture was already added.';
      }
      switch (draft) {
        case CaptureTaskDraft():
          tasks.add(
            TaskItem(
              id: id,
              title: draft.title,
              category: draft.category ?? 'personal',
              date: draft.dueDate ?? dateOnly(source.capturedAt),
            ),
          );
        case CaptureEventDraft():
          final start = draft.start;
          final end = draft.end;
          if (start == null || end == null || !end.isAfter(start)) {
            return 'Enter the start and end time for this event.';
          }
          events.add(
            CalendarEvent(
              id: id,
              title: draft.title,
              category: draft.category ?? 'personal',
              start: start,
              end: end,
              allDay: draft.allDay,
              location: draft.location,
            ),
          );
        case CaptureNoteDraft():
          notes.add(
            NoteItem(
              id: id,
              title: draft.title,
              body: draft.body,
              updated: source.capturedAt,
              category: draft.category,
              noteToSelf: draft.noteToSelf,
            ),
          );
        case CaptureWorkoutDraft():
          if (!_allows(EasyFeature.workouts)) {
            return 'Enable Workouts to add this entry.';
          }
          final sessions = _gymSessions;
          if (sessions == null) return 'Workout history could not be opened.';
          gym ??= [...sessions];
          final entry = GymLogEntry(
            id: id,
            title: draft.title,
            loggedAt: source.capturedAt,
            actual: draft.details == draft.title ? null : draft.details,
          );
          final target =
              capturedSession ??
              gym
                  .where(
                    (session) =>
                        !session.finished &&
                        !source.capturedAt.isBefore(session.startedAt),
                  )
                  .lastOrNull;
          if (target == null) {
            var start = source.capturedAt;
            final starts = gym.map((session) => session.startedAt).toSet();
            while (starts.contains(start)) {
              start = start.add(const Duration(microseconds: 1));
            }
            capturedSession = GymSession.loggedCapture(at: start, entry: entry);
            gym.add(capturedSession);
            gym.sort(
              (first, second) => first.startedAt.compareTo(second.startedAt),
            );
          } else {
            capturedSession = target.withCapturedEntry(entry);
            gym[gym.indexOf(target)] = capturedSession;
          }
        case CaptureMealDraft():
          if (!_allows(EasyFeature.nutrition)) {
            return 'Enable Nutrition to add this draft.';
          }
          final current = nutrition ?? _nutritionData();
          if (current.meals.any((meal) => meal.id == id)) {
            return 'This meal draft was already added.';
          }
          nutrition = NutritionData(
            foods: current.foods,
            meals: [
              ...current.meals,
              NutritionMeal(
                id: id,
                name: draft.description,
                eatenAt: source.capturedAt,
                draft: true,
              ),
            ],
          );
        case CaptureCompleteTaskDraft():
          final index = tasks.indexWhere((task) => task.id == draft.targetId);
          if (index < 0 || tasks[index].done) {
            return 'Review the task’s current state.';
          }
          tasks[index] = tasks[index].withDone(true);
      }
    }

    var updated = previous.copyWith(
      tasks: tasks,
      events: events,
      notes: notes,
      captures: _upsert(
        previous.captures,
        source.markApplied(),
        (entry) => entry.id,
      ),
    );
    if (nutrition != null) {
      updated = updated.withSection(_nutritionKey, nutrition.toJson());
    }
    await _commitReviewedData(
      previous,
      updated,
      operationId: '${source.id}-apply-${source.revision}',
      sessions: gym,
    );
    return null;
  }

  Future<void> _editRecord(Object existing) async {
    if (existing is CalendarEvent && existing.isReadOnly) return;
    final result = await _showEditor(
      RecordEditor(
        date: _destination == _Destination.calendar ? _calendarDate : _today,
        kind: _recordKind(existing),
        event: existing is CalendarEvent ? existing : null,
        task: existing is TaskItem ? existing : null,
        taskItems: _data.tasks,
        note: existing is NoteItem ? existing : null,
        noteTargets: existing is NoteItem ? _noteTargets() : const [],
      ),
    );
    if (result != null && mounted) _saveRecord(result);
  }

  Future<void> _openHomeNote(NoteItem? note) async {
    if (note == null) {
      await _capture(kind: RecordKind.note, noteToSelf: true);
    } else {
      await _openRecord(note);
    }
  }

  List<NoteTarget> _noteTargets() => [
    for (final task in _data.tasks)
      NoteTarget(kind: NoteLinkKind.task, id: task.id, title: task.title),
    for (final event in _data.events)
      NoteTarget(kind: NoteLinkKind.event, id: event.id, title: event.title),
  ];

  Future<void> _openNoteLink(NoteLink link) async {
    final target = switch (link.kind) {
      NoteLinkKind.task =>
        _data.tasks.where((task) => task.id == link.id).firstOrNull,
      NoteLinkKind.event =>
        _data.events.where((event) => event.id == link.id).firstOrNull,
    };
    if (target == null) {
      _inform('The linked record is unavailable.');
      return;
    }
    if (target is CalendarEvent) _changeDate(target.start);
    _navigate(
      link.kind == NoteLinkKind.task
          ? _Destination.tasks
          : _Destination.calendar,
    );
    await _openRecord(target);
  }

  Future<void> _openRecord(Object record) async {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => _inspected = record);
      return;
    }
    final action = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: paper,
      showDragHandle: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .68,
        ),
        child: _RecordDetails(
          record: record,
          onEdit: () => Navigator.pop(context, 'edit'),
          onDelete: () => Navigator.pop(context, 'delete'),
          noteTargets: record is NoteItem ? _noteTargets() : const [],
          onOpenNoteLink: (link) => Navigator.pop(context, link),
          onEstimate: _canEstimate(record)
              ? () => Navigator.pop(context, 'estimate')
              : null,
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') await _editRecord(record);
    if (action == 'delete') await _deleteRecord(record);
    if (action is NoteLink) await _openNoteLink(action);
    if (action == 'estimate' && record is TaskItem) {
      await _suggestDuration(record);
    }
  }

  bool _canEstimate(Object? record) =>
      record is TaskItem &&
      !record.done &&
      _allows(EasyFeature.ai) &&
      (_ai?.settings.allowEstimates ?? false);

  Future<void> _suggestDuration(TaskItem task) async {
    final runtime = _ai;
    if (runtime == null || !runtime.settings.allowEstimates) return;
    final revision = _contentRevision;
    final scope = CaptureInput(
      id: 'estimate:${task.id}',
      revision: revision,
      text: task.title,
      context: CaptureContext(anchor: DateTime.now(), revision: revision),
    );
    final outcome = await runtime.runEstimate(
      source: scope,
      input: AiEstimateInput(
        title: task.title,
        sampleDurationsMinutes: _durationSamples(task),
      ),
      currentRevision: (id) =>
          mounted && id == scope.id && revision == _contentRevision
          ? (sourceRevision: revision, contextRevision: revision)
          : null,
      authorize: (preview) => mounted
          ? showAiTransmissionDialog(context, preview)
          : Future.value(false),
    );
    if (!mounted) return;
    final estimate = outcome.value;
    if (estimate == null) {
      if (outcome.status != AiRunStatus.declined) {
        _inform(outcome.message ?? 'There is no duration estimate yet.');
      }
      return;
    }
    final minutes = estimate.duration.inMinutes;
    final splitIssue = taskSplitIssue(
      allowSplit: task.allowSplit,
      minimumChunkMinutes: task.minimumChunkMinutes,
      estimatedMinutes: minutes,
    );
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Duration estimate'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Text(task.title),
            Text('$minutes min', style: sectionHeadingStyle),
            Text(estimate.uncertainty, style: contentMetadataStyle),
            if (outcome.message case final message?)
              Text(message, style: contentMetadataStyle),
            if (splitIssue != null)
              Text(splitIssue, style: contentMetadataStyle),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: splitIssue == null
                ? () => Navigator.pop(context, true)
                : null,
            child: const Text('Use estimate'),
          ),
        ],
      ),
    );
    if (!mounted || approved != true) return;
    final current = _data.tasks.where((item) => item.id == task.id).firstOrNull;
    if (!identical(current, task)) {
      _inform('This task changed. Review its duration again.');
      return;
    }
    _saveRecord(task.withEstimate(minutes));
  }

  List<int> _durationSamples(TaskItem task) {
    final ActivityData activity;
    try {
      activity = _activityData();
    } catch (_) {
      return const [];
    }
    final title = task.title.trim().toLowerCase();
    final finished = activity.records.where(
      (record) =>
          record.finishedAt != null &&
          (record.target?.id == task.id &&
                  record.target?.kind == ActivityTargetKind.task ||
              record.category == task.category &&
                  record.title.trim().toLowerCase() == title),
    );
    return [
      for (final record in finished.toList().reversed.take(16))
        if (record.elapsedAt(record.finishedAt!).inMinutes case final minutes
            when minutes >= 1 && minutes <= 1440)
          minutes,
    ];
  }

  Future<void> _search() async {
    if (_reviewSaving) return;
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _SearchDialog(
        records: [
          ..._data.events,
          ..._appleFeed.events.map(_fromApple),
          for (final row in _icsFeed.events) row.event,
          ..._data.tasks,
          ..._data.notes,
        ],
      ),
    );
    if (result == null || !mounted) return;
    _navigate(switch (result) {
      CalendarEvent() => _Destination.calendar,
      TaskItem() => _Destination.tasks,
      _ => _Destination.notes,
    });
    if (result is CalendarEvent) _changeDate(result.start);
    await _openRecord(result);
  }

  Widget? _focusedContent(BuildContext context, FocusMode? mode) {
    final children = <Widget>[
      if (_allows(EasyFeature.workouts) &&
          (mode?.sections.contains(FocusSection.workout) ?? false))
        _gymOverview(context),
      if (_allows(EasyFeature.nutrition) &&
          (mode?.sections.contains(FocusSection.nutrition) ?? false))
        _focusTool(
          icon: Icons.restaurant_outlined,
          title: 'Meal log',
          onTap: _openNutrition,
        ),
      if (_allows(EasyFeature.activity) &&
          (mode?.sections.intersection(const {
                FocusSection.activity,
                FocusSection.routines,
              }).isNotEmpty ??
              false))
        _focusTool(
          icon: Icons.timer_outlined,
          title: 'Activity and routines',
          onTap: _openActivities,
        ),
    ];
    if (children.isEmpty) return null;
    if (children.length == 1) return children.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 22,
      children: children,
    );
  }

  Widget _focusTool({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    color: raisedPaper,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: line),
      borderRadius: contentSurfaceRadius,
    ),
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );

  (
    List<CalendarEvent>,
    List<SourcedCalendarEvent<ExternalCalendarEvent>>,
    List<IcsWorkspaceEvent>,
    CalendarSourcePreferences?,
    FocusMode?,
  )?
  _visibleEventRevision;
  List<CalendarEvent> _visibleEvents = const [];

  List<CalendarEvent> _calendarEvents(FocusMode? mode) {
    final preferences = _calendarPreferences;
    final revision = (
      _data.events,
      _appleFeed.events,
      _icsFeed.events,
      preferences,
      mode,
    );
    if (_visibleEventRevision == revision) return _visibleEvents;
    final calendars = preferences?.calendarsFor(mode?.id);
    _visibleEvents = [
      for (final event in _data.events)
        if (calendars?.contains(_localCalendar(event.category)) ??
            (mode?.includes(event.category.toLowerCase()) ?? true))
          event,
      for (final event in revision.$2)
        if (calendars?.contains(event.id.calendar) ?? false) _fromApple(event),
      for (final row in revision.$3)
        if (calendars?.contains(row.calendar) ?? false) row.event,
    ];
    _visibleEventRevision = revision;
    return _visibleEvents;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        body: Center(
          child: _loadFailed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Your workspace could not be opened.'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Retry'),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < 720;
    final compact = width < 900;
    final space = _space;
    final mode = _focus;
    final modes = _availableModes.toList(growable: false);
    final events = _calendarEvents(mode);
    final tasks = mode == null || mode.categories == null
        ? _data.tasks
        : _data.tasks
              .where((item) => mode.includes(item.category.toLowerCase()))
              .toList();
    final notes = mode == null || mode.categories == null
        ? _data.notes
        : _data.notes
              .where((item) => mode.includes(item.category?.toLowerCase()))
              .toList();
    final showSchedule = mode?.sections.contains(FocusSection.schedule) ?? true;
    final showTasks = mode?.sections.contains(FocusSection.tasks) ?? true;
    final focusedContent = _focusedContent(context, mode);
    final visibleCalendars =
        _calendarPreferences?.calendarsFor(space) ?? const <CalendarIdentity>{};
    final calendarProblem =
        (_allows(EasyFeature.externalCalendars) &&
                visibleCalendars.any(_isAppleCalendar)
            ? _appleFeed.problem
            : null) ??
        (visibleCalendars.any((id) => id.accountId == workspaceIcsAccountId)
            ? _icsFeed.problem
            : null);
    final todayNote = mobile ? _homeNote() : null;
    final canPlan =
        _allows(EasyFeature.planning) &&
        showTasks &&
        tasks.any((task) => !task.done && (task.estimatedMinutes ?? 0) > 0);
    final page = PageStorage(
      bucket: _pageStorage,
      child: IndexedStack(
        index: _destination.index,
        sizing: StackFit.expand,
        children: [
          if (mobile)
            MobileHome(
              date: _today,
              mode: space,
              modeName: mode?.name,
              modeControl: _ModeControl(
                mode: space,
                modes: modes,
                onSettings: _openSettings,
                showCurrentMode: false,
                onModeChanged: _changeSpace,
              ),
              note: todayNote,
              notesAlreadyFiltered: true,
              focusedContent: focusedContent,
              showTasks: showTasks,
              showSchedule: showSchedule,
              onPlanDay: canPlan ? _planDay : null,
              events: events,
              tasks: tasks,
              onNoteTap: () => _openHomeNote(todayNote),
              onEventTap: _openRecord,
              onTaskTap: _openRecord,
              onTaskToggle: _toggleTask,
              onCalendarTap: () {
                _changeDate(_today);
                _navigate(_Destination.calendar);
              },
            )
          else
            TodayPage(
              date: _today,
              title: mode?.name ?? 'Today',
              showSchedule: showSchedule,
              showTasks: showTasks,
              focusedContent: focusedContent,
              onPlanDay: canPlan ? _planDay : null,
              events: events,
              tasks: tasks,
              onEventTap: _openRecord,
              onTaskTap: _openRecord,
              onTaskToggle: _toggleTask,
            ),
          Column(
            children: [
              if (calendarProblem != null)
                TextButton(
                  onPressed: _openCalendarSettings,
                  child: Text(calendarProblem),
                ),
              Expanded(
                child: CalendarPage(
                  date: _calendarDate,
                  events: events,
                  eventsRevision: _visibleEventRevision,
                  onDateChanged: _changeDate,
                  onEventTap: _openRecord,
                ),
              ),
            ],
          ),
          TasksPage(
            tasks: tasks,
            onToggle: _toggleTask,
            onTaskTap: _openRecord,
          ),
          NotesPage(notes: notes, onNoteTap: _openRecord),
        ],
      ),
    );
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
    };
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: AbsorbPointer(
          absorbing: _reviewSaving,
          child: MobileModeFrame(
            mode: space,
            modeColor: mode == null ? null : Color(mode.color),
            child: Scaffold(
              backgroundColor: mobile ? paper : shell,
              body: SafeArea(
                bottom: !mobile,
                child: mobile
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Column(
                            children: [
                              if (_destination != _Destination.today &&
                                  (_destination != _Destination.calendar ||
                                      space != null))
                                _MobileHeader(
                                  space: space,
                                  modes: modes,
                                  displayBrand:
                                      _destination != _Destination.calendar,
                                  onSpaceChanged: _changeSpace,
                                  onSearch: _search,
                                  onSettings: _openSettings,
                                ),
                              Expanded(child: page),
                            ],
                          ),
                          Positioned(
                            right: 20,
                            bottom: MediaQuery.paddingOf(context).bottom + 20,
                            child: HoldCaptureButton(
                              onTap: _capture,
                              onHeldRecord:
                                  kIsWeb || !_allows(EasyFeature.captureMedia)
                                  ? null
                                  : (action) =>
                                        _openVoiceCapture(heldAction: action),
                            ),
                          ),
                          Positioned.fill(
                            child: OrbitNavigation(
                              destinations: [
                                for (final destination in _Destination.values)
                                  OrbitDestination(
                                    destination.label,
                                    destination.icon,
                                  ),
                              ],
                              selectedIndex: _destination.index,
                              onSelected: (index) =>
                                  _navigate(_Destination.values[index]),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          _DesktopHeader(
                            onSearch: _search,
                            onCapture: _capture,
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 14, 14),
                              child: Row(
                                children: [
                                  _Sidebar(
                                    destination: _destination,
                                    compact: compact,
                                    space: space,
                                    modes: modes,
                                    onNavigate: _navigate,
                                    onSpaceChanged: _changeSpace,
                                    onSettings: _openSettings,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: _Surface(child: page)),
                                  if (_inspected != null && width >= 1000) ...[
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: width >= 1250 ? 294 : 264,
                                      child: _Surface(
                                        child: _RecordDetails(
                                          record: _inspected!,
                                          onClose: () =>
                                              setState(() => _inspected = null),
                                          onEdit: () =>
                                              _editRecord(_inspected!),
                                          onDelete: () =>
                                              _deleteRecord(_inspected!),
                                          noteTargets: _inspected is NoteItem
                                              ? _noteTargets()
                                              : const [],
                                          onOpenNoteLink: _openNoteLink,
                                          onEstimate: _canEstimate(_inspected)
                                              ? () => _suggestDuration(
                                                  _inspected! as TaskItem,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ScheduleProposal _reviewSchedule(
  ({
    TimeSpan window,
    DateTime? reservationStart,
    List<CalendarEvent> events,
    List<TaskItem> tasks,
  })
  input,
) => planWorkspaceDay(
  window: input.window,
  reservationStart: input.reservationStart,
  events: input.events,
  tasks: input.tasks,
);

String _normalizeIcsFile(Uint8List data) =>
    IcsCalendar.parseBytes(data).encode();

bool _samePlanBlocks(List<TimeSpan> first, List<TimeSpan> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (!first[index].start.isAtSameMomentAs(second[index].start) ||
        !first[index].end.isAtSameMomentAs(second[index].end)) {
      return false;
    }
  }
  return true;
}

WorkoutPlan _sampleWorkoutPlan(DateTime today) => WorkoutPlan(
  id: 'sample-upper-body',
  name: 'Upper body',
  schedule: WorkoutSchedule(
    kind: WorkoutScheduleKind.weekdays,
    startDate: today,
    weekdays: [today.weekday],
  ),
  exercises: [
    WorkoutExercise(
      id: 'sample-treadmill',
      name: 'Treadmill',
      kind: WorkoutExerciseKind.cardio,
      distanceKm: 0.5,
      minutes: 5,
      inclinePercent: 2,
    ),
    WorkoutExercise(
      id: 'sample-bench',
      name: 'Bench press',
      kind: WorkoutExerciseKind.strength,
      sets: [
        for (var index = 1; index <= 3; index++)
          WorkoutSet(id: 'sample-bench-$index', weightKg: 50, reps: 8),
      ],
    ),
  ],
);

String _workoutExerciseSummary(WorkoutExercise exercise) {
  if (exercise.kind == WorkoutExerciseKind.strength) {
    final count = exercise.sets.length;
    return '$count ${count == 1 ? 'set' : 'sets'}';
  }
  String number(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
  return '${number(exercise.distanceKm)} km · ${exercise.minutes} min · '
      '${number(exercise.inclinePercent)}%';
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: paper,
      borderRadius: BorderRadius.circular(19),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? const Color(0xffdcead9) : accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wb_twilight_outlined, size: 23, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            appName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              letterSpacing: -.7,
              color: dark ? const Color(0xfff5f7f1) : ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopHeader extends StatelessWidget {
  const _DesktopHeader({required this.onSearch, required this.onCapture});

  final VoidCallback onSearch;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final shortcut = Theme.of(context).platform == TargetPlatform.macOS
        ? '⌘ K'
        : 'Ctrl K';
    return SizedBox(
      height: 70,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        child: Row(
          children: [
            const Expanded(child: _Brand(dark: true)),
            Expanded(
              flex: 2,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 370),
                  child: Material(
                    color: shellSurface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: Color(0xff343d34)),
                    ),
                    child: InkWell(
                      onTap: onSearch,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: sidebarText,
                            ),
                            const SizedBox(width: 9),
                            const Expanded(
                              child: Text(
                                'Search workspace',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: sidebarText,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: const Color(0xff3d473c),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 2,
                                ),
                                child: Text(
                                  shortcut,
                                  style: const TextStyle(
                                    color: sidebarText,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onCapture,
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffe3ebdf),
                    foregroundColor: const Color(0xff283d31),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 17,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.space,
    required this.modes,
    required this.displayBrand,
    required this.onSpaceChanged,
    required this.onSearch,
    required this.onSettings,
  });

  final String? space;
  final List<FocusMode> modes;
  final bool displayBrand;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: displayBrand
                ? const _Brand(dark: false)
                : const SizedBox.shrink(),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 146),
            child: _ModeControl(
              mode: space,
              modes: modes,
              onModeChanged: onSpaceChanged,
              onSettings: onSettings,
            ),
          ),
          IconButton(
            tooltip: 'Search workspace',
            onPressed: onSearch,
            icon: const Icon(Icons.search_rounded, size: 21),
          ),
        ],
      ),
    );
  }
}

class _ModeControl extends StatelessWidget {
  const _ModeControl({
    required this.mode,
    required this.modes,
    required this.onModeChanged,
    required this.onSettings,
    this.showCurrentMode = true,
  });

  final String? mode;
  final List<FocusMode> modes;
  final ValueChanged<String?> onModeChanged;
  final VoidCallback onSettings;
  final bool showCurrentMode;

  @override
  Widget build(BuildContext context) {
    final current = mode;
    final profile = modes.where((item) => item.id == current).firstOrNull;
    final foreground = profile == null ? muted : Color(profile.color);
    return MenuAnchor(
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.expand_more_rounded, size: 17),
        iconAlignment: IconAlignment.end,
        label: Text(
          showCurrentMode && profile != null ? profile.name : 'Mode',
          overflow: TextOverflow.ellipsis,
        ),
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => onModeChanged(null),
          trailingIcon: current == null
              ? const Icon(Icons.check, size: 18)
              : null,
          child: const Text('No mode'),
        ),
        for (final mode in modes)
          MenuItemButton(
            onPressed: () => onModeChanged(mode.id),
            leadingIcon: Icon(Icons.circle, color: Color(mode.color), size: 8),
            trailingIcon: current == mode.id
                ? const Icon(Icons.check, size: 18)
                : null,
            child: Text(
              mode.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const Divider(),
        MenuItemButton(
          onPressed: onSettings,
          leadingIcon: const Icon(Icons.settings_outlined, size: 18),
          child: const Text('Settings'),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destination,
    required this.compact,
    required this.space,
    required this.modes,
    required this.onNavigate,
    required this.onSpaceChanged,
    required this.onSettings,
  });

  final _Destination destination;
  final bool compact;
  final String? space;
  final List<FocusMode> modes;
  final ValueChanged<_Destination> onNavigate;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 54 : 206,
      child: ListView(
        padding: EdgeInsets.only(
          left: compact ? 0 : 2,
          top: 9,
          right: compact ? 0 : 8,
        ),
        children: [
          for (final item in _Destination.values)
            _SidebarButton(
              label: item.label,
              icon: item.icon,
              color: sidebarText,
              selected: item == destination,
              compact: compact,
              onTap: () => onNavigate(item),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 12,
              19,
              compact ? 4 : 10,
              16,
            ),
            child: const Divider(color: Color(0xff323b33)),
          ),
          if (!compact)
            const Padding(
              padding: EdgeInsets.fromLTRB(13, 4, 0, 8),
              child: Text(
                'Focus modes',
                style: TextStyle(
                  color: Color(0xffa7b0a4),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          _SidebarButton(
            label: 'All spaces',
            icon: Icons.grid_view_rounded,
            color: sidebarText,
            selected: space == null,
            compact: compact,
            onTap: () => onSpaceChanged(null),
          ),
          for (final mode in modes)
            _SidebarButton(
              label: mode.name,
              icon: Icons.circle,
              color: Color.lerp(Color(mode.color), sidebarText, .43)!,
              selected: space == mode.id,
              compact: compact,
              onTap: () => onSpaceChanged(mode.id),
            ),
          const SizedBox(height: 20),
          _SidebarButton(
            label: 'Settings',
            icon: Icons.settings_outlined,
            color: sidebarText,
            selected: false,
            compact: compact,
            onTap: onSettings,
          ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: compact ? label : null,
      selected: selected,
      button: true,
      child: Tooltip(
        message: compact ? label : '',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Material(
            color: selected ? const Color(0xff2a342b) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 0 : 12,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Icon(
                        icon,
                        size: icon == Icons.circle ? 8 : 18,
                        color: selected && icon != Icons.circle
                            ? const Color(0xffd0dfd1)
                            : color,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xfff0f5ec)
                                : sidebarText,
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _recordId(Object record) => switch (record) {
  CalendarEvent() => record.id,
  TaskItem() => record.id,
  NoteItem() => record.id,
  _ => throw ArgumentError.value(record),
};

String _recordTitle(Object record) => switch (record) {
  CalendarEvent() => record.title,
  TaskItem() => record.title,
  NoteItem() => record.title,
  _ => throw ArgumentError.value(record),
};

RecordKind _recordKind(Object record) => switch (record) {
  CalendarEvent() => RecordKind.event,
  TaskItem() => RecordKind.task,
  NoteItem() => RecordKind.note,
  _ => throw ArgumentError.value(record),
};

class _RecordDetails extends StatelessWidget {
  const _RecordDetails({
    required this.record,
    required this.onEdit,
    required this.onDelete,
    this.onClose,
    this.noteTargets = const [],
    this.onOpenNoteLink,
    this.onEstimate,
  });

  final Object record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onClose;
  final List<NoteTarget> noteTargets;
  final ValueChanged<NoteLink>? onOpenNoteLink;
  final VoidCallback? onEstimate;

  @override
  Widget build(BuildContext context) {
    final item = record;
    final localizations = MaterialLocalizations.of(context);
    String day(DateTime date) => localizations.formatFullDate(date);
    String time(DateTime date) =>
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));
    final rows = switch (item) {
      CalendarEvent() => [
        (Icons.calendar_today_outlined, day(item.start)),
        if (item.allDay)
          (Icons.schedule_outlined, 'All day')
        else
          (
            Icons.schedule_outlined,
            sameDay(item.start, item.end)
                ? '${time(item.start)} – ${time(item.end)}'
                : '${time(item.start)} – ${day(item.end)}, ${time(item.end)}',
          ),
        if (item.location?.isNotEmpty ?? false)
          (Icons.place_outlined, item.location!),
        (Icons.circle_outlined, item.sourceLabel ?? spaceName(item.category)),
      ],
      TaskItem() => [
        (Icons.check_box_outlined, item.done ? 'Completed' : 'Open'),
        if (item.date != null) (Icons.calendar_today_outlined, day(item.date!)),
        (Icons.circle_outlined, spaceName(item.category)),
        if (item.estimatedMinutes case final minutes?)
          (Icons.timer_outlined, '$minutes min estimate'),
      ],
      NoteItem() => [
        (
          Icons.schedule_outlined,
          'Edited ${localizations.formatMediumDate(item.updated)}',
        ),
      ],
      _ => <(IconData, String)>[],
    };
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(25, onClose == null ? 11 : 22, 25, 27),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _recordTitle(record),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.8,
                      height: 1.15,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: 'Close details',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 19),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            for (final (icon, label) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(icon, color: muted, size: 17),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: muted, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            if (item is NoteItem &&
                (item.body.trim().isNotEmpty || item.links.isNotEmpty)) ...[
              const Divider(),
              const SizedBox(height: 14),
              NotePreview(
                note: item,
                targets: noteTargets,
                onOpenLink: onOpenNoteLink,
              ),
            ],
            if (item case CalendarEvent(description: final description?)) ...[
              const Divider(),
              const SizedBox(height: 14),
              SelectableText(
                description,
                style: const TextStyle(height: 1.6, fontSize: 14),
              ),
            ],
            if (item is! CalendarEvent || !item.isReadOnly) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: onEdit,
                    child: const Text('Edit'),
                  ),
                  TextButton(
                    onPressed: onDelete,
                    style: TextButton.styleFrom(foregroundColor: muted),
                    child: const Text('Delete'),
                  ),
                  if (onEstimate != null)
                    TextButton(
                      onPressed: onEstimate,
                      child: const Text('Suggest duration'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.records});

  final List<Object> records;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final results = widget.records
        .where(
          (record) =>
              _recordTitle(record)
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase()),
        )
        .take(30)
        .toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: (_) {
                  if (results.isNotEmpty) Navigator.pop(context, results.first);
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Search workspace',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            Flexible(
              child: results.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No matching items.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final kind = _recordKind(result);
                        return ListTile(
                          leading: Icon(switch (kind) {
                            RecordKind.event => Icons.calendar_today_outlined,
                            RecordKind.task => Icons.check_box_outlined,
                            RecordKind.note => Icons.notes_rounded,
                          }),
                          title: Text(_recordTitle(result)),
                          subtitle: Text(spaceName(kind.name)),
                          onTap: () => Navigator.pop(context, result),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
