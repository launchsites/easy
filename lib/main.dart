import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, kIsWeb, listEquals, setEquals;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activities/activities.dart';
import 'automation/automation.dart';
import 'automation/workspace_automation_events.dart';
import 'ai/ai_device_state.dart';
import 'ai/ai_linux_credential_vault.dart';
import 'ai/ai_runtime.dart';
import 'ai/ai_settings_page.dart';
import 'ai/duration_evidence_estimate.dart';
import 'ai/task_estimates_page.dart';
import 'ai/vision/vision_image.dart';
import 'calendar_page.dart';
import 'calendar_sources/apple_calendar_feed.dart';
import 'calendar_sources/calendar_directory.dart';
import 'calendar_sources/calendar_settings_page.dart';
import 'calendar_sources/event_kit_calendar_adapter.dart'
    show
        EventKitCalendarAccess,
        EventKitCalendarAdapter,
        EventKitCopyReceipt,
        EventKitEventDraft,
        EventKitUpdateReview,
        ExternalCalendarEvent;
import 'calendar_sources/ics_calendar.dart';
import 'calendar_sources/ics_import_export.dart';
import 'calendar_sources/ics_transfer_page.dart';
import 'calendar_sources/ics_workspace.dart';
import 'calendar_sources/ics_workspace_feed.dart';
import 'calendar_sources/internal_recurrence.dart';
import 'calendar_sources/internal_recurrence_editor.dart';
import 'calendar_sources/internal_workspace_feed.dart';
import 'capture/capture_archive.dart';
import 'capture/capture_interpreter.dart';
import 'capture/capture_review_sheet.dart';
import 'capture/held_voice_capture.dart';
import 'capture/hold_capture_button.dart';
import 'capture/local_transcriber.dart';
import 'capture/task_category_hint.dart';
import 'capture/voice_capture_sheet.dart';
import 'capture/voice_playback_dialog.dart';
import 'capture/voice_transcription_settings.dart';
import 'categories/category_palette.dart';
import 'categories/workspace_categories.dart';
import 'categories/workspace_categories_page.dart';
import 'focus/focus_mode.dart';
import 'focus/focus_modes_page.dart';
import 'focus/focus_suggestion_action.dart';
import 'gym_history_page.dart';
import 'gym_mode_ui.dart';
import 'gym_session.dart';
import 'health/health.dart';
import 'insights/insights.dart';
import 'list_pages.dart';
import 'mobile_home.dart';
import 'notes/note_preview.dart';
import 'nutrition/meal_vision_review.dart';
import 'nutrition/nutrition.dart';
import 'onboarding/workspace_setup.dart';
import 'orbit_navigation.dart';
import 'preferences/feature_preferences.dart';
import 'preferences/feature_preferences_page.dart';
import 'quick_capture.dart';
import 'record_editor.dart';
import 'reminders/local_reminder.dart';
import 'reminders/local_reminder_backend.dart';
import 'reminders/local_reminder_editor.dart';
import 'reminders/workspace_record_reminders.dart';
import 'review/review.dart';
import 'scheduling/availability_settings.dart';
import 'scheduling/availability_settings_page.dart';
import 'scheduling/future_block_removal.dart';
import 'scheduling/future_block_removal_sheet.dart';
import 'scheduling/manual_time_block.dart';
import 'scheduling/manual_time_block_sheet.dart';
import 'scheduling/plan_day_sheet.dart';
import 'scheduling/planner.dart';
import 'scheduling/task_objective_availability.dart';
import 'scheduling/task_objective_review.dart';
import 'scheduling/task_objective_review_sheet.dart';
import 'scheduling/weekly_plan_sheet.dart';
import 'scheduling/weekly_planner.dart';
import 'search/search.dart';
import 'settings_page.dart';
import 'storage/attachment_store.dart';
import 'storage/media_backup.dart';
import 'storage/workspace_backup_page.dart';
import 'storage/workspace_store.dart';
import 'sync/manual_sync_installation.dart';
import 'sync/manual_sync_page.dart';
import 'sync/manual_sync_workspace.dart';
import 'sync/sync_password_vault_prompt.dart';
import 'sync/workspace_manual_sync.dart';
import 'task_context/task_context.dart';
import 'tasks/recurring_task.dart';
import 'tasks/task_breakdown.dart';
import 'tasks/task_breakdown_review.dart';
import 'tasks/task_capture_defaults.dart';
import 'tasks/task_capture_defaults_editor.dart';
import 'tasks/task_repeat_editor.dart';
import 'tasks/task_workspace_feed.dart';
import 'today_page.dart';
import 'workout_plan.dart';
import 'workout_plans_page.dart';
import 'workspace_data.dart';

part 'workspace_chrome.dart';
part 'workspace_repeating_tasks.dart';
part 'workspace_category_views.dart';
part 'workspace_search.dart';
part 'workspace_task_actions.dart';
part 'workspace_reminders.dart';
part 'workspace_planner.dart';
part 'workspace_manual_plan.dart';
part 'workspace_task_context.dart';
part 'workspace_apple_updates.dart';
part 'workspace_activity_actions.dart';
part 'workspace_onboarding.dart';
part 'workspace_focus_suggestions.dart';
part 'workspace_manual_sync_actions.dart';
part 'workspace_workout_capture.dart';
part 'workspace_task_objectives.dart';
part 'workspace_automation.dart';
part 'workspace_apple_access.dart';
part 'workspace_task_completion.dart';
part 'workspace_review_availability.dart';

const appName = String.fromEnvironment('APP_NAME', defaultValue: 'Easy');

void main() => runApp(const EasyApp());

typedef WorkspaceStoreOpener = Future<WorkspaceStore> Function({
  required SharedPreferencesAsync preferences,
  required Future<WorkspaceSnapshot> Function() readLegacy,
});

class EasyApp extends StatelessWidget {
  const EasyApp({
    super.key,
    this.openStore = openWorkspaceStore,
    this.calendarAdapter = const EventKitCalendarAdapter(),
    this.reminderBackend = const PlatformLocalReminderBackend(),
    this.reminderSettings = const LocalReminderSettingsStore(),
  });

  final WorkspaceStoreOpener openStore;
  final EventKitCalendarAdapter calendarAdapter;
  final LocalReminderBackend reminderBackend;
  final LocalReminderSettingsStore reminderSettings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: easyTheme(),
      home: _Workspace(
        openStore: openStore,
        calendarAdapter: calendarAdapter,
        reminderBackend: reminderBackend,
        reminderSettings: reminderSettings,
      ),
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
const _appleCopiesKey = 'appleCalendarCopies';
const _featuresKey = 'features';
const _reviewsKey = 'reviews';
const _scheduleSettingsKey = 'schedulingSettings';
const _healthKey = 'health';
const _recurringEventsKey = 'recurringEvents';

IcsCalendar _exportWorkspaceCalendar(
  ({
    List<CalendarEvent> events,
    List<InternalRecurringEvent> series,
    Set<String> seriesIds,
  })
  snapshot,
) {
  final standalone = exportIcsRecords([
    for (final event in snapshot.events)
      if (!snapshot.seriesIds.contains(event.id))
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
  return standalone.withEvents([
    ...standalone.events,
    for (final series in snapshot.series) ...series.toIcsEvents(),
  ]);
}

CalendarIdentity _localCalendar(String category) => CalendarIdentity(
  accountId: _localCalendarAccount,
  calendarId: category.isEmpty ? 'general' : category,
);

bool _isAppleCalendar(CalendarIdentity id) =>
    id.accountId != _localCalendarAccount &&
    id.accountId != workspaceIcsAccountId;

({WorkspaceData data, List<GymSession>? sessions, List<WorkoutPlan>? plans})
_decodeWorkspaceSnapshot(WorkspaceSnapshot snapshot) {
  List<T>? decodeRecords<T>(List<String> saved, T Function(String) decode) {
    try {
      return saved.map(decode).toList();
    } catch (_) {
      return null;
    }
  }

  return (
    data: WorkspaceData.decode(snapshot.workspaceJson),
    sessions: decodeRecords(snapshot.gymSessionJson, GymSession.decode),
    plans: decodeRecords(snapshot.workoutPlanJson, WorkoutPlan.decode),
  );
}

class _Workspace extends StatefulWidget {
  const _Workspace({
    required this.openStore,
    required this.calendarAdapter,
    required this.reminderBackend,
    required this.reminderSettings,
  });

  final WorkspaceStoreOpener openStore;
  final EventKitCalendarAdapter calendarAdapter;
  final LocalReminderBackend reminderBackend;
  final LocalReminderSettingsStore reminderSettings;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> with WidgetsBindingObserver {
  final _legacyPreferences = SharedPreferencesAsync();
  WorkspaceStore? _store;
  int? _persistedRevision;
  var _openingStore = false;
  var _reviewSaving = false;
  var _activityActionOpen = false;
  var _futureRemovalOpen = false;
  var _manualSyncOpen = false;
  var _taskObjectivesOpen = false;
  var _automationOpen = false;
  Timer? _automationCalendarTimer;
  Object? _automationSeriesKey;
  Future<List<InternalWorkspaceEvent>>? _automationSeriesWindow;
  Object? _automationCacheKey;
  AutomationData? _cachedAutomation;
  Object? _reviewAvailabilityKey;
  final _reviewAvailabilityCache = <DateTime, Future<ReviewDayAvailability?>>{};
  var _planningDay = false;
  var _recordingVoice = false;
  final _heldVoiceOverlay = HeldVoiceCaptureOverlay();
  var _openingGym = false;
  var _mealReviewGeneration = 0;
  var _reviewingMealPhoto = false;
  Future<void> _pendingSave = Future.value();
  late WorkspaceData _data;
  WorkspaceData? _savedWorkspace;
  int _contentRevision = 0;
  List<GymSession>? _gymSessions;
  List<GymSession>? _savedGymSessions;
  List<WorkoutPlan>? _workoutPlans;
  List<WorkoutPlan>? _savedWorkoutPlans;
  var _calendarDate = dateOnly(DateTime.now());
  DateTime get _today => dateOnly(DateTime.now());
  var _destination = _Destination.today;
  final _mountedDestinations = {_Destination.today};
  String? _space;
  Object? _inspected;
  var _loading = true;
  var _loadFailed = false;
  final _pageStorage = PageStorageBucket();
  final _features = ValueNotifier(FeaturePreferences());
  List<FocusMode> _modes = standardFocusModes();
  late final _focusSuggestionStore = FocusSuggestionSettingsStore(
    _legacyPreferences,
  );
  FocusSuggestionPreferences _focusSuggestionPreferences =
      FocusSuggestionPreferences();
  Timer? _focusSuggestionBoundary;
  Object? _focusSuggestionSourceRevision;
  List<FocusSuggestionEvent> _focusEvents = const [];
  var _focusSuggestionSaving = false;
  CalendarSourcePreferences? _calendarPreferences;
  late final _appleFeed = AppleCalendarFeed(adapter: widget.calendarAdapter);
  final _unsavedAppleCopies = <String, EventKitCopyReceipt>{};
  var _copyingApple = false;
  int _appleCopyRevision = 0;
  final _icsFeed = IcsWorkspaceFeed();
  final _internalFeed = InternalWorkspaceFeed();
  List<WorkspaceIcsCalendar> _icsCalendars = const [];
  List<InternalRecurringEvent> _eventSeries = const [];
  Set<String> _eventSeriesIds = const {};
  Object? _categoryRevision;
  Object? _categorySource;
  Set<String> _categoryReferences = const {};
  WorkspaceCategories _categoryCache = WorkspaceCategories.defaults();
  Object? _focusedTasksRevision;
  List<TaskItem> _focusedTasks = const [];
  Object? _focusedNotesRevision;
  List<NoteItem> _focusedNotes = const [];
  Future<SearchPreferences>? _searchPreferences;
  Future<void> _searchPreferenceWrites = Future.value();
  Future<SearchIndex>? _searchIndex;
  Object? _searchIndexRevision;
  Object? _searchActivitySource;
  List<ActivityRecord> _searchActivities = const [];
  var _searchOpen = false;
  late final _localReminderController = LocalReminderController(
    backend: widget.reminderBackend,
    appName: appName,
  );
  Future<LocalReminderSettings>? _localReminderSettings;
  WorkspaceData? _reminderWorkspace;
  Object? _reminderWorkspaceRevision;
  Timer? _reminderDebounce;
  var _taskFeed = TaskWorkspaceFeed();
  var _taskSeriesUnreadable = false;
  Future<AttachmentStore?>? _attachmentStore;
  Future<AiDeviceState>? _aiState;
  Future<AiRuntime?>? _preparingAi;
  AiRuntime? _ai;
  final _aiViewChanges = ValueNotifier(0);
  Timer? _estimateTimer;
  int? _lastEstimateCheck;
  DateTime _lastWorkspaceInput = DateTime.now();
  int _taskHistoryRevision = 0;
  Object? _taskHistoryCacheKey;
  TaskContextIndex? _taskHistoryCache;
  Future<TaskContextIndex>? _buildingTaskHistory;
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
    _appleFeed.addListener(_calendarViewsChanged);
    _icsFeed.addListener(_calendarViewsChanged);
    _internalFeed.addListener(_calendarViewsChanged);
    unawaited(_load());
    unawaited(_loadFocusSuggestions());
    if (LocalTranscriber.supported) unawaited(_loadVoiceSettings());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appleFeed.dispose();
    _icsFeed.dispose();
    _internalFeed.dispose();
    _features.dispose();
    _aiViewChanges.dispose();
    _estimateTimer?.cancel();
    _focusSuggestionBoundary?.cancel();
    _automationCalendarTimer?.cancel();
    _reminderDebounce?.cancel();
    _voiceTranscriber.cancel();
    _heldVoiceOverlay.dispose();
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
    _syncEstimateTimer();
    if (state != AppLifecycleState.resumed) _voiceTranscriber.cancel();
    if (state != AppLifecycleState.resumed) {
      _focusSuggestionBoundary?.cancel();
    } else if (_focusSuggestionPreferences.enabled && !_loading) {
      setState(() {});
    }
    if (!_loading && state == AppLifecycleState.resumed) {
      _queueAutomationCalendarCheck();
      unawaited(_refreshExternalCalendars(force: true));
      if (_reminderWorkspace case final saved?) {
        _queueReminderSync(saved, force: true);
      }
    } else if (_reminderWorkspace case final saved?
        when _reminderDebounce?.isActive == true) {
      _queueReminderSync(saved, force: true, immediate: true);
    }
    if (state != AppLifecycleState.resumed) _automationCalendarTimer?.cancel();
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
    final large =
        snapshot.workspaceJson.length > 256 * 1024 ||
        snapshot.gymSessionJson.length > 512 ||
        snapshot.workoutPlanJson.length > 128;
    final (:data, :sessions, :plans) = large
        ? await compute(_decodeWorkspaceSnapshot, snapshot)
        : _decodeWorkspaceSnapshot(snapshot);
    if (!mounted) return;
    setState(() {
      _persistedRevision = revision.revision;
      _data = data;
      _savedWorkspace = data;
      _contentRevision++;
      _taskHistoryRevision++;
      _gymSessions = _savedGymSessions = sessions;
      _workoutPlans = _savedWorkoutPlans = plans;
      _inspected = null;
      _unsavedAppleCopies.clear();
      _appleCopyRevision++;
      _loadViewSettings();
      _loading = false;
      _loadFailed = false;
    });
    _refreshCalendarViews();
    _queueAutomationCalendarCheck();
    if (!_requiresWorkspaceSetup) _queueReminderSync(data, force: true);
    if (!_allows(EasyFeature.ai)) _ai?.setForeground(false);
    if (!_requiresWorkspaceSetup &&
        !kIsWeb &&
        identical(widget.openStore, openWorkspaceStore)) {
      if (_allows(EasyFeature.ai)) unawaited(_prepareAi());
    }
  }

  Future<WorkspaceSnapshot> _readLegacy() async {
    final (workspace, gym, plans) = await (
      _legacyPreferences.getString(_storageKey),
      _legacyPreferences.getStringList(_gymStorageKey),
      _legacyPreferences.getStringList(_workoutPlansKey),
    ).wait;
    final nativeEntry = identical(widget.openStore, openWorkspaceStore);
    final fallback = nativeEntry
        ? WorkspaceData(
            events: [],
            tasks: [],
            notes: [],
            sections: {
              if (workspace == null && gym == null && plans == null)
                _workspaceSetupKey: _workspaceSetupPending,
            },
          )
        : WorkspaceData.samples(_today);
    return WorkspaceSnapshot(
      workspaceJson: workspace ?? fallback.encode(),
      gymSessionJson: gym ?? [],
      workoutPlanJson:
          plans ?? (nativeEntry ? [] : [_sampleWorkoutPlan(_today).encode()]),
    );
  }

  CalendarSourcePreferences _defaultCalendarPreferences() {
    final categories = _categories(includeArchived: true).keys;
    return CalendarSourcePreferences(
      allCalendars: ['', ...categories].map(_localCalendar),
      memberships: CalendarModeMemberships({
        for (final mode in _modes)
          mode.id: ['', ...categories]
              .where((category) => _modeIncludes(mode, category))
              .map(_localCalendar),
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
    try {
      _assignEventSeries(
        readInternalSeries(_data.sections[_recurringEventsKey]),
      );
    } on Object {
      _assignEventSeries(const []);
    }
    _readTaskFeed();
  }

  void _assignEventSeries(List<InternalRecurringEvent> series) {
    _eventSeries = List.unmodifiable(series);
    _eventSeriesIds = {for (final value in series) value.id};
  }

  Future<void> _saveEventSeries(List<InternalRecurringEvent> series) async {
    if (series.length > 500) {
      throw const FormatException('Too many repeating events.');
    }
    final previous = _data;
    await _commitReviewedData(
      previous,
      previous.withSection(_recurringEventsKey, [
        for (final item in series) item.toJson(),
      ]),
    );
    if (!mounted) return;
    setState(() {
      _assignEventSeries(series);
      if (_inspected is CalendarEvent) _inspected = null;
    });
    _refreshCalendarViews();
  }

  InternalWorkspaceEvent? _findOccurrence(CalendarEvent event) => _internalFeed
      .events
      .where(
        (row) =>
            row.event.id == event.id &&
            row.series.id == event.recurringSeriesId,
      )
      .firstOrNull;

  Future<void> _setEventRepeat(CalendarEvent event) async {
    final occurrence = _findOccurrence(event);
    if (event.recurringSeriesId != null && occurrence == null) return;
    final rule = await showInternalRecurrenceRuleEditor(
      context,
      initialRule: occurrence?.occurrence.rule,
      startDate: event.start,
    );
    if (!mounted || rule == null) return;
    try {
      final InternalRecurringEvent series;
      if (occurrence == null) {
        if (!_data.events.any((item) => identical(item, event)) ||
            _eventSeriesIds.contains(event.id)) {
          return;
        }
        series = InternalRecurringEvent(
          id: event.id,
          event: adaptSeriesDraft(event),
          rule: rule,
        );
      } else {
        final scope = await showDialog<InternalOccurrenceScope>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Change repeat rule'),
            children: [
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, InternalOccurrenceScope.future),
                child: const Text('This and following occurrences'),
              ),
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, InternalOccurrenceScope.series),
                child: const Text('Entire series'),
              ),
            ],
          ),
        );
        if (!mounted ||
            scope == null ||
            !_eventSeries.contains(occurrence.series)) {
          return;
        }
        series = occurrence.series.edit(
          occurrence.occurrence,
          scope: scope,
          event: occurrence.occurrence.event,
          rule: rule,
        );
      }
      await _saveEventSeries(_upsert(_eventSeries, series, (item) => item.id));
    } catch (_) {
      if (mounted) _inform('The repeat rule could not be saved.');
    }
  }

  Future<void> _editOccurrence(CalendarEvent record) async {
    final row = _findOccurrence(record);
    if (row == null) return;
    final scope = await showInternalOccurrenceScopeDialog(
      context,
      skipping: false,
    );
    if (!mounted || scope == null) return;
    final edited = await _showEditor(
      RecordEditor(date: record.start, kind: RecordKind.event, event: record),
    );
    if (!mounted ||
        edited is! CalendarEvent ||
        !_eventSeries.contains(row.series)) {
      return;
    }
    try {
      final changed = row.series.edit(
        row.occurrence,
        scope: scope,
        event: adaptSeriesDraft(edited, original: row),
      );
      await _saveEventSeries(_upsert(_eventSeries, changed, (item) => item.id));
    } catch (_) {
      if (mounted) _inform('This repeating event could not be updated.');
    }
  }

  Future<void> _skipOccurrence(CalendarEvent record) async {
    final row = _findOccurrence(record);
    if (row == null) return;
    final scope = await showInternalOccurrenceScopeDialog(
      context,
      skipping: true,
    );
    if (!mounted || scope == null || !_eventSeries.contains(row.series)) return;
    try {
      final changed = row.series.skip(row.occurrence, scope: scope);
      await _saveEventSeries(_upsert(_eventSeries, changed, (item) => item.id));
    } catch (_) {
      if (mounted) _inform('This repeating event could not be skipped.');
    }
  }

  void _openEventSeries() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => StatefulBuilder(
        builder: (context, rebuild) => Scaffold(
          appBar: AppBar(title: const Text('Repeating events')),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    for (final series in _eventSeries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(series.event.title),
                        subtitle: Text(spaceName(series.rule.frequency.name)),
                        trailing: TextButton(
                          onPressed: () async {
                            await _returnToSingleEvent(series);
                            if (context.mounted) rebuild(() {});
                          },
                          child: const Text('Keep one event'),
                        ),
                      ),
                    if (_eventSeries.isEmpty)
                      const Text('No repeating events.'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _returnToSingleEvent(InternalRecurringEvent series) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep the original event?'),
        content: Text(
          'Remove the repeating schedule for ${series.event.title} and keep the original event.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Keep one event'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !_eventSeries.contains(series)) return;
    try {
      await _saveEventSeries(
        _eventSeries.where((item) => item.id != series.id).toList(),
      );
    } catch (_) {
      if (mounted) _inform('The repeating schedule could not be removed.');
    }
  }

  Iterable<CalendarEvent> _standaloneEvents(List<CalendarEvent> events) =>
      _eventSeriesIds.isEmpty
      ? events
      : events.where((event) => !_eventSeriesIds.contains(event.id));

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
      _icsFeed.refresh(day: _calendarDate, sources: _selectedIcsCalendars),
    );
    unawaited(_internalFeed.refresh(day: _calendarDate, sources: _eventSeries));
  }

  Future<void> _refreshExternalCalendars({DateTime? day, bool force = false}) =>
      _appleFeed.refresh(
        day: day ?? _calendarDate,
        selected: _selectedAppleCalendars,
        force: force,
      );

  void _calendarViewsChanged() {
    if (!_loading) {
      _changeWorkspaceView(() {
        final selected = _inspected;
        if (_isAppleProjection(selected)) {
          _inspected = _currentAppleProjection(selected! as CalendarEvent);
        }
      });
      _queueAutomationCalendarCheck();
    }
  }

  void _changeWorkspaceView([VoidCallback? update]) {
    if (mounted) setState(update ?? () {});
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
        builder: (context, features, _) => ListenableBuilder(
          listenable: _aiViewChanges,
          builder: (context, _) => SettingsPage(
            sections: [
              SettingsSection(
                title: 'Workspace',
                items: [
                  SettingsItem(
                    icon: Icons.tune_rounded,
                    title: 'Features',
                    onTap: _openFeatureSettings,
                  ),
                  if (MediaQuery.sizeOf(context).width < 720)
                    SettingsItem(
                      icon: Icons.search_rounded,
                      title: 'Search workspace',
                      onTap: _search,
                    ),
                  SettingsItem(
                    icon: Icons.adjust_rounded,
                    title: 'Focus modes',
                    subtitle: 'Choose what each mode brings into view',
                    onTap: _openFocusSettings,
                  ),
                  SettingsItem(
                    icon: Icons.event_available_outlined,
                    title: 'Calendar focus suggestions',
                    onTap: _openFocusSuggestionSettings,
                  ),
                  SettingsItem(
                    icon: Icons.label_outline_rounded,
                    title: 'Categories',
                    subtitle: 'Names, colours and subcategories',
                    onTap: _openCategories,
                  ),
                  SettingsItem(
                    icon: Icons.add_task_rounded,
                    title: 'Task capture defaults',
                    subtitle: 'Preferred date and category for new tasks',
                    onTap: _openTaskDefaults,
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
                  if (_supportsReminders)
                    SettingsItem(
                      icon: Icons.notifications_none_rounded,
                      title: 'Reminders',
                      subtitle: 'Choose alerts for this device',
                      onTap: _openReminderSettings,
                    ),
                  if (_eventSeries.isNotEmpty)
                    SettingsItem(
                      icon: Icons.repeat_rounded,
                      title: 'Repeating events',
                      onTap: _openEventSeries,
                    ),
                  if (features.allows(EasyFeature.nutrition))
                    SettingsItem(
                      icon: Icons.restaurant_outlined,
                      title: 'Nutrition',
                      onTap: _openNutrition,
                    ),
                  if (features.allows(EasyFeature.health))
                    SettingsItem(
                      icon: Icons.favorite_border_rounded,
                      title: 'Health log',
                      onTap: _openHealthLog,
                    ),
                  if (features.allows(EasyFeature.activity))
                    SettingsItem(
                      icon: Icons.timer_outlined,
                      title: 'Activity and routines',
                      onTap: _openActivities,
                    ),
                  if (features.allows(EasyFeature.reviews))
                    SettingsItem(
                      icon: Icons.edit_calendar_outlined,
                      title: 'Daily review',
                      onTap: _openDailyReview,
                    ),
                  SettingsItem(
                    icon: Icons.rule_rounded,
                    title: 'Automation rules',
                    subtitle: 'Prepare follow-up items for review',
                    onTap: _openAutomation,
                  ),
                  if (features.allows(EasyFeature.planning))
                    SettingsItem(
                      icon: Icons.schedule_rounded,
                      title: 'Availability and travel',
                      onTap: _openSchedulingSettings,
                    ),
                  if (features.allows(EasyFeature.planning))
                    SettingsItem(
                      icon: Icons.view_week_outlined,
                      title: 'Plan week',
                      subtitle: 'Review suggested blocks across seven days',
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_planWeek());
                      },
                    ),
                  if (features.allows(EasyFeature.insights))
                    SettingsItem(
                      icon: Icons.insights_outlined,
                      title: 'Activity insights',
                      onTap: _openInsights,
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
                  if (!kIsWeb)
                    SettingsItem(
                      icon: Icons.devices_other_outlined,
                      title: 'Manual sync',
                      subtitle: 'Pair devices and exchange encrypted files',
                      onTap: _openManualSync,
                    ),
                  if (!kIsWeb && features.allows(EasyFeature.ai))
                    SettingsItem(
                      icon: Icons.auto_awesome_outlined,
                      title: 'AI assistance',
                      subtitle: 'Providers, monthly limit, and usage',
                      onTap: _openAiSettings,
                    ),
                  if (features.allows(EasyFeature.ai) &&
                      (_ai?.settings.automaticEstimates ?? false))
                    SettingsItem(
                      icon: Icons.timer_outlined,
                      title: 'Duration suggestions',
                      onTap: _openTaskEstimates,
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
          _lastEstimateCheck = null;
          _syncEstimateTimer();
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
      const linuxVault = AiLinuxCredentialVault();
      final vault = defaultTargetPlatform == TargetPlatform.linux
          ? await linuxVault.available()
                ? linuxVault
                : AiSessionCredentialVault()
          : const AiSystemCredentialVault();
      if (!mounted) return null;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final runtime = AiRuntime(
        read: state.read,
        compareAndSwap: state.compareAndSwap,
        vault: vault,
        foreground:
            _allows(EasyFeature.ai) &&
            (lifecycle == null || lifecycle == AppLifecycleState.resumed),
      );
      _ai = runtime;
      runtime.addListener(_aiChanged);
      await runtime.load();
      if (mounted) setState(() {});
      return runtime;
    } catch (_) {
      _aiState = null;
      _preparingAi = null;
      return null;
    }
  }

  void _aiChanged() {
    if (!mounted) return;
    _aiViewChanges.value++;
    _syncEstimateTimer();
  }

  void _syncEstimateTimer() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (!foreground ||
        !_allows(EasyFeature.ai) ||
        !(_ai?.settings.automaticEstimates ?? false)) {
      _estimateTimer?.cancel();
      _estimateTimer = null;
      return;
    }
    _estimateTimer ??= Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(_runAutomaticEstimate());
    });
  }

  AiEnrichmentCandidate? _estimateCandidate(TaskItem task) {
    if (task.done ||
        _taskFeed.ids.contains(task.id) ||
        task.schedulingHold != null ||
        task.estimatedMinutes != null ||
        task.title.length > 300) {
      return null;
    }
    if (_needsEstimateHistory && !_taskHistoryReady) return null;
    final history = _needsEstimateHistory
        ? _providerDurationHistoryFor(task)
        : null;
    final samples = history?.compatibleMinutes ?? const <int>[];
    return AiEnrichmentCandidate(
      taskId: task.id,
      title: task.title,
      sourceRevision: _stableRevision([
        task.title,
        task.category,
        task.date?.toIso8601String(),
        task.dueAt?.toIso8601String(),
        task.priority?.name,
        task.minimumChunkMinutes,
        task.allowSplit,
      ]),
      contextRevision: _stableRevision(
        history == null
            ? samples
            : [
                samples,
                history.cohort.name,
                history.sampleCount,
                history.matchingSamples,
                history.latestCompletion.toIso8601String(),
                history.median.inSeconds,
                history.lower.inSeconds,
                history.upper.inSeconds,
              ],
      ),
      sampleDurationsMinutes: samples,
      durationHistory: history,
    );
  }

  AiCaptureRevision? _estimateRevision(String id) {
    if (_loading) return null;
    final task = _data.tasks.where((task) => task.id == id).firstOrNull;
    return task == null ? null : _estimateCandidate(task)?.revision;
  }

  Future<void> _runAutomaticEstimate() async {
    final runtime = _ai;
    if (!mounted ||
        _loading ||
        _reviewSaving ||
        _reviewingMealPhoto ||
        runtime == null ||
        runtime.busy ||
        !_allows(EasyFeature.ai) ||
        !runtime.settings.automaticEstimates ||
        !identical(_savedWorkspace, _data) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastWorkspaceInput) < const Duration(seconds: 25)) {
      return;
    }
    final pulse =
        now.millisecondsSinceEpoch ~/ (2 * Duration.millisecondsPerMinute);
    if (pulse == _lastEstimateCheck) return;
    _lastEstimateCheck = pulse;
    if (!runtime.automaticEstimateOpportunity &&
        runtime.pendingEstimates.length < 32) {
      return;
    }
    if (_needsEstimateHistory && !await _prepareTaskHistory()) return;
    if (!mounted ||
        !identical(_savedWorkspace, _data) ||
        ModalRoute.of(context)?.isCurrent != true ||
        DateTime.now().difference(_lastWorkspaceInput) <
            const Duration(seconds: 25) ||
        runtime.busy) {
      return;
    }
    if (runtime.pendingEstimates.length >= 32) {
      await runtime.discardObsoleteEstimates(_estimateRevision);
      if (!mounted ||
          !identical(_savedWorkspace, _data) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
    }
    if (!runtime.automaticEstimateOpportunity) return;
    final candidates =
        _data.tasks
            .where((task) => !task.done && task.estimatedMinutes == null)
            .toList()
          ..sort((first, second) {
            final a = first.dueAt ?? first.date;
            final b = second.dueAt ?? second.date;
            if (a != null && b != null) {
              final order = a.compareTo(b);
              if (order != 0) return order;
            }
            if ((a == null) != (b == null)) return a == null ? 1 : -1;
            final priority = (second.priority ?? TaskPriority.normal).index
                .compareTo((first.priority ?? TaskPriority.normal).index);
            return priority == 0 ? first.id.compareTo(second.id) : priority;
          });
    for (final task in candidates) {
      final candidate = _estimateCandidate(task);
      if (candidate != null && runtime.canAutomaticallyEstimate(candidate)) {
        await runtime.runAutomaticEstimate(
          candidate: candidate,
          currentRevision: _estimateRevision,
        );
        return;
      }
    }
  }

  Iterable<TaskEstimateReviewItem> _pendingEstimates(AiRuntime runtime) sync* {
    for (final estimate in runtime.currentPendingEstimates(_estimateRevision)) {
      final task = _data.tasks
          .where((task) => task.id == estimate.taskId)
          .firstOrNull;
      if (task == null) continue;
      yield TaskEstimateReviewItem(
        estimate: estimate,
        title: task.title,
        issue: taskSplitIssue(
          allowSplit: task.allowSplit,
          minimumChunkMinutes: task.minimumChunkMinutes,
          estimatedMinutes: estimate.durationMinutes,
        ),
      );
    }
  }

  Future<void> _openTaskEstimates() async {
    final runtime = _ai;
    if (runtime == null || !_allows(EasyFeature.ai)) return;
    if (_needsEstimateHistory && !await _prepareTaskHistory()) {
      if (mounted) _inform('Timing history is unavailable.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TaskEstimatesPage(
          runtime: runtime,
          readItems: () => _pendingEstimates(runtime),
          onAccept: (estimate) async {
            final previous = _data;
            final item = _pendingEstimates(runtime)
                .where((item) => identical(item.estimate, estimate))
                .firstOrNull;
            if (item == null || item.issue != null) {
              throw StateError('The estimate changed.');
            }
            await _commitReviewedData(
              previous,
              previous.copyWith(
                tasks: [
                  for (final task in previous.tasks)
                    if (task.id == estimate.taskId)
                      task.withEstimate(estimate.durationMinutes)
                    else
                      task,
                ],
              ),
            );
            await runtime.discardPendingEstimate(estimate);
          },
        ),
      ),
    );
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
            ? widget.calendarAdapter
            : const EventKitCalendarAdapter(platform: TargetPlatform.linux),
        isAppleCalendar: (id) =>
            _allows(EasyFeature.externalCalendars) && _isAppleCalendar(id),
        initialPreferences:
            _calendarPreferences ?? _defaultCalendarPreferences(),
        onChanged: _changeCalendarPreferences,
        modes: {for (final mode in _modes) mode.id: mode.name},
        localSources: [
          for (final entry in {
            '': 'General',
            ..._categories(includeArchived: true),
          }.entries)
            CalendarSource(
              id: _localCalendar(entry.key),
              name: entry.value,
              accountName: appName,
              color: _catalog.colorArgbFor(entry.key),
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
      if (source != null) {
        export = await compute(IcsCalendar.parse, source.document);
      } else {
        final snapshot = _data.events;
        final series = _eventSeries;
        final idSet = _eventSeriesIds;
        export = await compute(_exportWorkspaceCalendar, (
          events: snapshot,
          series: series,
          seriesIds: idSet,
        ));
      }
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
          media: kIsWeb
              ? null
              : WorkspaceMediaBackupUiSupport(
                  loadAttachments: _openAttachments,
                  pickBackupFile: () => openFile(),
                  saveMediaArchive: _saveMediaBackup,
                ),
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

  Future<void> _exportFile(Uint8List bytes, String filename, String mimeType) =>
      _saveOrShareFile(XFile.fromData(bytes, mimeType: mimeType), filename);

  Future<void> _saveMediaBackup(WorkspaceMediaBackupFile archive) =>
      _saveOrShareFile(
        XFile(archive.nativePath, mimeType: 'application/octet-stream'),
        archive.suggestedName,
        retainFilename: true,
      );

  Future<void> _saveOrShareFile(
    XFile file,
    String filename, {
    bool retainFilename = false,
  }) async {
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
        fileNameOverrides: retainFilename ? null : [filename],
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
          recipes: nutrition.recipes,
          onChanged: (values) =>
              _update(_data.withSection(_nutritionKey, values.toJson())),
          onAttachPhoto: kIsWeb || !_allows(EasyFeature.captureMedia)
              ? null
              : _attachMealPhoto,
          onViewPhoto: _allows(EasyFeature.captureMedia)
              ? _viewMealPhoto
              : null,
          onReviewPhoto:
              _allows(EasyFeature.captureMedia) &&
                  _allows(EasyFeature.ai) &&
                  (_ai?.canRunMealVision ?? false)
              ? _reviewMealPhoto
              : null,
          onCancelPhotoReview: _cancelMealReview,
        ),
      ),
    );
  }

  SchedulingSettings? _planningPreferences({bool expandCategories = false}) {
    final raw = _data.sections[_scheduleSettingsKey];
    if (raw == null) return null;
    final settings = SchedulingSettings.fromJson(raw as Map<String, Object?>);
    if (!expandCategories ||
        settings.availability.every((window) => window.categories == null)) {
      return settings;
    }
    return SchedulingSettings(
      timeZoneId: settings.timeZoneId,
      places: settings.places,
      routes: settings.routes,
      beforeMinutes: settings.beforeMinutes,
      afterMinutes: settings.afterMinutes,
      availability: [
        for (final window in settings.availability)
          if (window.categories case final categories?)
            WeeklyAvailability(
              id: window.id,
              weekdays: window.weekdays,
              startMinute: window.startMinute,
              endMinute: window.endMinute,
              kind: window.kind,
              categories: _expandCategoryReferences(categories),
            )
          else
            window,
      ],
    );
  }

  Future<void> _openSchedulingSettings() async {
    final SchedulingSettings settings;
    try {
      settings = _planningPreferences() ?? SchedulingSettings();
    } catch (_) {
      _inform('Your scheduling settings could not be opened.');
      return;
    }
    final updated = await showSchedulingSettingsEditor(
      context,
      settings: settings,
      categories: _categories(),
    );
    if (!mounted || updated == null) return;
    try {
      await _commitReviewedData(
        _data,
        _data.withSection(_scheduleSettingsKey, updated.toJson()),
      );
    } catch (_) {
      if (mounted) _inform('The scheduling settings could not be saved.');
    }
  }

  bool _canAssignPlace(Object? record) {
    if (!_allows(EasyFeature.planning) ||
        record is! CalendarEvent ||
        record.isReadOnly ||
        record.recurringSeriesId != null ||
        _eventSeriesIds.contains(record.id)) {
      return false;
    }
    try {
      return _planningPreferences()?.places.isNotEmpty ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _assignPlace(CalendarEvent event) async {
    final places = _planningPreferences()?.places ?? const [];
    final selection = await showDialog<({String? id})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Travel place'),
        children: [
          ListTile(
            title: const Text('Unassigned'),
            selected: event.savedPlaceId == null,
            onTap: () => Navigator.pop(context, (id: null as String?)),
          ),
          for (final place in places)
            ListTile(
              title: Text(place.name),
              selected: event.savedPlaceId == place.id,
              onTap: () => Navigator.pop(context, (id: place.id)),
            ),
        ],
      ),
    );
    if (!mounted ||
        selection == null ||
        !_data.events.any((record) => identical(record, event))) {
      return;
    }
    _saveRecord(event.withPlace(selection.id));
  }

  NutritionData _nutritionData() {
    final saved = _data.sections[_nutritionKey];
    return saved == null
        ? NutritionData()
        : NutritionData.fromJson(saved as Map<String, dynamic>);
  }

  void _cancelMealReview() {
    _mealReviewGeneration++;
    if (_reviewingMealPhoto) _ai?.cancelCurrent();
  }

  Future<List<NutritionPortion>?> _reviewMealPhoto(
    BuildContext routeContext,
    NutritionMeal meal,
    List<NutritionFood> foods,
  ) async {
    final runtime = _ai;
    final reference = meal.photo;
    if (runtime == null ||
        reference == null ||
        !runtime.canRunMealVision ||
        !_allows(EasyFeature.ai) ||
        _reviewingMealPhoto ||
        runtime.busy) {
      return null;
    }
    _reviewingMealPhoto = true;
    final generation = ++_mealReviewGeneration;
    bool active() =>
        mounted && routeContext.mounted && generation == _mealReviewGeneration;
    try {
      await _pendingSave;
      final persisted = await _store!.read();
      final workspaceJson =
          jsonDecode(persisted.snapshot.workspaceJson) as Map<String, dynamic>;
      final raw = workspaceJson[_nutritionKey];
      final stored = raw is Map<String, dynamic>
          ? NutritionData.fromJson(raw).meals
                .where((item) => item.id == meal.id)
                .firstOrNull
          : null;
      if (stored?.photo?.id != reference.id) {
        throw StateError('Save the draft before analysis.');
      }
      final media = await (await _openAttachments())?.read(reference.id);
      if (media == null || !active()) return null;
      final image = await prepareAiVisionImage(media.bytes);
      if (!active()) return null;
      final revision = _stableRevision([meal.id, reference.id]);
      final capture = CaptureInput(
        id: 'meal-photo:${meal.id}',
        revision: revision,
        text: 'Meal photo',
        context: CaptureContext(anchor: meal.eatenAt, revision: revision),
      );
      AiCaptureRevision? current(String id) {
        if (!active() || id != capture.id) return null;
        final photo = _nutritionData().meals
            .where((item) => item.id == meal.id)
            .firstOrNull
            ?.photo;
        return photo?.id == reference.id
            ? (sourceRevision: revision, contextRevision: revision)
            : null;
      }

      final result = await runtime.runMealVision(
        source: capture,
        image: image,
        currentRevision: current,
        authorize: (details) => routeContext.mounted && active()
            ? showMealVisionTransmissionDialog(routeContext, details)
            : Future.value(false),
      );
      if (!routeContext.mounted || !active()) return null;
      if (result.value case final review?) {
        final portions = await showMealVisionReview(
          routeContext,
          review,
          foods,
        );
        return active() ? portions : null;
      }
      if (result.status != AiRunStatus.declined) {
        _inform(
          result.message ??
              'The photo is saved. No food suggestions are available.',
        );
      }
      return null;
    } finally {
      _reviewingMealPhoto = false;
    }
  }

  Object? _activityCacheKey;
  ActivityData? _cachedActivityData;

  ActivityData _activityData() {
    final saved = _data.sections[_activitiesKey];
    final existing = _cachedActivityData;
    if (existing != null && identical(saved, _activityCacheKey)) {
      return existing;
    }
    final parsed = saved == null
        ? ActivityData()
        : ActivityData.fromJson(saved as Map<String, dynamic>);
    _activityCacheKey = saved;
    _cachedActivityData = parsed;
    return parsed;
  }

  void _openDailyReview() {
    if (!_allows(EasyFeature.reviews)) return;
    final ReviewData review;
    try {
      review = _readReviewData(_data);
    } catch (_) {
      _inform('Your review history could not be opened.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReviewPage(
          data: review,
          agendaForDay: _reviewAgenda,
          availabilityForDay: _reviewAvailabilityFor,
          activityMinutesForDay: (day) =>
              _confirmedMinutes(day, plusDays(day, 1)),
          onChanged: _saveReviewWithAutomation,
          onRollForward: _rollReviewTaskForward,
          onReviewActions: _openCaptureReview,
        ),
      ),
    );
  }

  void _openInsights() {
    if (!_allows(EasyFeature.insights)) return;
    final ActivityData activity;
    try {
      activity = _activityData();
    } catch (_) {
      _inform('Activity records could not be opened.');
      return;
    }
    final active = _allows(EasyFeature.activity)
        ? activity.records
        : const <ActivityRecord>[];
    final eventSpans = <String, List<InsightWindow>>{};
    final records = <InsightActivity>[];
    for (final record in active) {
      final spans = [
        for (final span in record.spans)
          if (span.end != null && span.end!.isAfter(span.start))
            InsightWindow(span.start, span.end!),
      ];
      if (spans.isEmpty) continue;
      final target = record.target;
      if (target?.kind == ActivityTargetKind.event) {
        (eventSpans[target!.id] ??= []).addAll(spans);
      }
      records.add(
        InsightActivity(
          id: record.id,
          category: record.category,
          spans: spans,
          taskId: target?.kind == ActivityTargetKind.task ? target?.id : null,
        ),
      );
    }
    if (_allows(EasyFeature.workouts)) {
      for (final session in _gymSessions ?? const <GymSession>[]) {
        final finished = session.finishedAt;
        if (finished == null || !finished.isAfter(session.startedAt)) continue;
        records.add(
          InsightActivity(
            id: 'gym:${session.startedAt.toIso8601String()}',
            category: 'gym',
            spans: [InsightWindow(session.startedAt, finished)],
          ),
        );
      }
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => InsightsPage(
          activities: records,
          tasks: [
            for (final task in _taskFeed.insightTasks(_data.tasks))
              InsightTask(
                id: task.id,
                title: task.title,
                category: task.category,
                projectId: task.parentId,
                dueAt: task.dueAt,
                completedAt: task.completedAt,
              ),
          ],
          plans: [
            for (final event in _data.events)
              if (event.plannedTaskId != null ||
                  eventSpans.containsKey(event.id))
                InsightPlan(
                  id: event.id,
                  category: event.category,
                  initial:
                      event.initialPlannedStart != null &&
                          event.initialPlannedEnd != null
                      ? InsightWindow(
                          event.initialPlannedStart!,
                          event.initialPlannedEnd!,
                        )
                      : null,
                  accepted: InsightWindow(event.start, event.end),
                  actual: eventSpans[event.id] ?? const [],
                ),
          ],
          onExportJson: (name, data) async {
            try {
              await _exportFile(
                Uint8List.fromList(utf8.encode(data)),
                name,
                'application/json',
              );
              return true;
            } on BackupExportCancelled {
              return false;
            }
          },
        ),
      ),
    );
  }

  ReviewAgenda _reviewAgenda(DateTime day) {
    final end = plusDays(day, 1);
    final standaloneIds = _taskFeed.series.isEmpty
        ? null
        : _taskFeed.standalone(_data.tasks).map((task) => task.id).toSet();
    return ReviewAgenda(
      events: [
        for (final event in [
          ..._standaloneEvents(_data.events),
          if (_allows(EasyFeature.externalCalendars) &&
              _appleFeed.hasVerifiedAccess)
            ..._appleFeed.events.map(_fromApple),
          ..._icsFeed.events.map((row) => row.event),
          ..._internalFeed.events.map((row) => row.event),
        ])
          if (event.start.isBefore(end) && event.end.isAfter(day))
            ReviewEvent(
              id: event.id,
              title: event.title,
              start: event.start,
              end: event.end,
              allDay: event.allDay,
            ),
      ],
      tasks: [
        for (final task in _taskFeed.reviewTasks(_data.tasks, day))
          ReviewTask(
            id: task.id,
            title: task.title,
            date: task.date,
            dueAt: task.dueAt,
            done: task.done,
            estimatedMinutes: task.estimatedMinutes,
            completedAt: task.completedAt,
            canChangePreferredDate: standaloneIds?.contains(task.id) ?? true,
          ),
      ],
      unresolvedCaptures: _data.captures
          .where(
            (item) => !item.applied && sameDay(item.capturedAt.toLocal(), day),
          )
          .length,
      confirmedActivityMinutes: _confirmedMinutes(day, end),
    );
  }

  int? _confirmedMinutes(DateTime start, DateTime end) {
    if (!_allows(EasyFeature.activity)) return null;
    final ActivityData activity;
    try {
      activity = _activityData();
    } catch (_) {
      return null;
    }
    final bounds = TimeSpan(start, end);
    final spans = [
      for (final activity in activity.records)
        for (final span in activity.spans)
          if (span.end != null && span.end!.isAfter(span.start))
            ?TimeSpan(span.start, span.end!).intersection(bounds),
    ]..sort((first, second) => first.start.compareTo(second.start));
    if (spans.isEmpty) return null;
    var minutes = Duration.zero;
    var cursor = start;
    for (final span in spans) {
      if (!span.end.isAfter(cursor)) continue;
      minutes += span.end.difference(
        span.start.isAfter(cursor) ? span.start : cursor,
      );
      cursor = span.end;
    }
    return minutes.inMinutes;
  }

  Future<void> _rollReviewTaskForward(ReviewTask recorded, DateTime day) async {
    final previous = _data;
    final tasks = [...previous.tasks];
    final index = tasks.indexWhere((task) => task.id == recorded.id);
    if (index < 0) throw StateError('This task is unavailable.');
    final task = tasks[index];
    if (task.done || task.dueAt != null || task.date != recorded.date) {
      throw StateError('Review the current task before moving its date.');
    }
    tasks[index] = task.withDate(dateOnly(day));
    await _commitReviewedData(previous, previous.copyWith(tasks: tasks));
  }

  void _openActivities({String? initialRecordId}) {
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
          initialRecordId: initialRecordId,
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

  HealthData _healthData() {
    final saved = _data.sections[_healthKey];
    return saved == null
        ? HealthData()
        : HealthData.fromJson(saved as Map<String, dynamic>);
  }

  List<HealthExerciseTarget> _healthTargets([WorkoutPlan? only]) => [
    for (final plan
        in only == null ? _workoutPlans ?? const <WorkoutPlan>[] : [only])
      for (final exercise in plan.exercises)
        HealthExerciseTarget(
          planId: plan.id,
          exerciseId: exercise.id,
          name: exercise.name,
          planName: plan.name,
        ),
  ];

  void _openHealthLog() {
    if (!_allows(EasyFeature.health)) return;
    final HealthData health;
    try {
      health = _healthData();
    } catch (_) {
      _inform('Your health log could not be opened.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HealthPage(
          data: health,
          exerciseTargets: _healthTargets(),
          onChanged: (data) => _commitReviewedData(
            _data,
            _data.withSection(_healthKey, data.toJson()),
          ),
        ),
      ),
    );
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
    final plans = _workoutPlans!;
    final snapshot = plans.map((plan) => plan.encode()).toList();
    _queueSave(() async {
      await _saveMutation(WorkspaceMutation.workoutPlans(snapshot));
      _savedWorkoutPlans = plans;
    }, _persistWorkoutPlans);
  }

  void _update(WorkspaceData data) {
    setState(() => _assignData(data));
    final snapshot = data.encode();
    _queueSave(() async {
      await _saveMutation(WorkspaceMutation.workspace(snapshot));
      _savedWorkspace = data;
      _queueReminderSync(data);
      _queueAutomationCalendarCheck();
    }, () => _update(_data));
  }

  void _assignData(WorkspaceData data) {
    if (_changesTaskEvidence(_data.tasks, data.tasks)) _taskHistoryRevision++;
    final taskSeriesChanged = !identical(
      data.sections[recurringTasksSection],
      _data.sections[recurringTasksSection],
    );
    if (!identical(data.tasks, _data.tasks) ||
        !identical(data.events, _data.events) ||
        !identical(data.notes, _data.notes) ||
        !identical(
          data.sections[_taskCaptureDefaultsKey],
          _data.sections[_taskCaptureDefaultsKey],
        ) ||
        !identical(
          data.sections[_categorySettingsKey],
          _data.sections[_categorySettingsKey],
        ) ||
        taskSeriesChanged) {
      _contentRevision++;
    }
    _data = data;
    if (taskSeriesChanged) _readTaskFeed();
    if (_inspected case final TaskItem selected) {
      _inspected = _workspaceTasks
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
    List<WorkoutPlan>? plans,
  }) {
    if (_reviewSaving) {
      return Future.error(StateError('A reviewed change is being saved.'));
    }
    final previousSessions = _gymSessions;
    final previousPlans = _workoutPlans;
    setState(() => _reviewSaving = true);
    final operation = _pendingSave.then((_) async {
      var saved = false;
      try {
        if (!mounted ||
            !identical(_data, previous) ||
            (sessions != null && !identical(_gymSessions, previousSessions)) ||
            (plans != null && !identical(_workoutPlans, previousPlans))) {
          throw StateError('The workspace changed after review.');
        }
        final workspace = updated.encode();
        final WorkspaceMutation mutation;
        if (sessions == null && plans == null) {
          mutation = WorkspaceMutation.workspace(workspace);
        } else {
          final state = await _store!.read();
          if (state.revision != _persistedRevision) {
            throw StateError('The workspace changed after review.');
          }
          mutation = WorkspaceMutation.replace(
            WorkspaceSnapshot(
              workspaceJson: workspace,
              gymSessionJson: sessions == null
                  ? state.snapshot.gymSessionJson
                  : [for (final session in sessions) session.encode()],
              workoutPlanJson: plans == null
                  ? state.snapshot.workoutPlanJson
                  : [for (final plan in plans) plan.encode()],
            ),
          );
        }
        await _saveMutation(mutation, operationId: operationId);
        saved = true;
        _savedWorkspace = updated;
        _queueReminderSync(updated);
        if (mounted) {
          setState(() {
            _assignData(updated);
            if (sessions != null) {
              _gymSessions = _savedGymSessions = List.unmodifiable(sessions);
            }
            if (plans != null) {
              _workoutPlans = _savedWorkoutPlans = List.unmodifiable(plans);
            }
          });
        }
      } finally {
        if (mounted) {
          setState(() => _reviewSaving = false);
          if (saved) _queueAutomationCalendarCheck();
        }
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
    if (_openingGym || !_allows(EasyFeature.workouts)) return;
    _openingGym = true;
    try {
      await _showGymSession(plan);
    } finally {
      _openingGym = false;
    }
  }

  Future<void> _showGymSession(WorkoutPlan? plan) async {
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
      final begun = await _startWorkout(plan, sessions);
      if (begun == null || !mounted) return;
      session = begun;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileModeFrame(
          mode: 'gym',
          child: GymSessionPage(
            session: session,
            previousSessions: sessions,
            onChanged: _saveGymSession,
            buildCaptureControl: (onReviewed) =>
                _gymCaptureControl(session.startedAt, onReviewed),
          ),
        ),
      ),
    );
  }

  Future<GymSession?> _startWorkout(
    WorkoutPlan? plan,
    List<GymSession> previousSessions,
  ) async {
    final at = DateTime.now();
    final planned = GymSession.start(plan: plan, now: at);
    final HealthData? health;
    try {
      health = _allows(EasyFeature.health) ? _healthData() : null;
    } catch (_) {
      _inform('Open the health log before starting this workout.');
      return null;
    }
    if (health == null ||
        health
            .forWorkout(
              planId: plan?.id,
              exerciseIds: planned.exercises.map((exercise) => exercise.id),
              workoutAt: at,
            )
            .isEmpty) {
      _saveGymSession(planned);
      return planned;
    }
    final decision = await showWorkoutHealthReview(
      context,
      data: health,
      planId: plan?.id,
      exercises: plan == null ? const [] : _healthTargets(plan),
      workoutAt: at,
    );
    if (!mounted ||
        decision == null ||
        !identical(_gymSessions, previousSessions)) {
      return null;
    }
    final updated = planned.withSkippedExercises(decision.skippedExerciseIds);
    final before = _data;
    try {
      await _commitReviewedData(
        before,
        before.withSection(
          _healthKey,
          health.withWorkoutDecision(decision).toJson(),
        ),
        sessions: [...previousSessions, updated],
      );
      return updated;
    } catch (_) {
      if (mounted) _inform('The reviewed workout could not be saved.');
      return null;
    }
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
          bodyMeasurements: _gymHistoryMeasurements(),
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

  List<BodyMeasurement> _gymHistoryMeasurements() {
    if (!_allows(EasyFeature.health)) return const [];
    try {
      return _healthData().measurements;
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  void _saveGymSession(GymSession? session) {
    if (session == null || !mounted) return;
    final sessions = _gymSessions!;
    final index = sessions.indexWhere(
      (value) => value.startedAt.isAtSameMomentAs(session.startedAt),
    );
    final updated = [...sessions];
    if (index == -1) {
      updated.add(session);
    } else {
      updated[index] = session;
    }
    final workout = index >= 0 && sessions[index].finished
        ? null
        : automationForWorkout(session);
    final revised = _withAutomationEvents(_data, [?workout]);
    final addedDraft = !identical(revised, _data);
    setState(() {
      _gymSessions = updated;
      if (addedDraft) _assignData(revised);
    });
    if (addedDraft) {
      _persistWorkoutWithAutomation();
    } else {
      _persistGymSessions();
    }
  }

  void _persistGymSessions() {
    final sessions = _gymSessions!;
    final snapshot = sessions.map((session) => session.encode()).toList();
    _queueSave(() async {
      await _saveMutation(WorkspaceMutation.gymSessions(snapshot));
      _savedGymSessions = sessions;
    }, _persistGymSessions);
  }

  void _navigate(_Destination destination) {
    setState(() {
      _destination = destination;
      _mountedDestinations.add(destination);
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

  List<T> _upsert<T>(List<T> records, T updated, String Function(T) id) => [
    for (final existing in records)
      if (id(existing) == id(updated)) updated else existing,
    if (!records.any((existing) => id(existing) == id(updated))) updated,
  ];

  void _saveRecord(Object record) {
    if (record is CalendarEvent && record.isReadOnly) return;
    TaskItem? oldTask;
    if (record is TaskItem) {
      final previous = _data.tasks
          .where((task) => task.id == record.id)
          .firstOrNull;
      oldTask = previous;
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
    _update(
      record is TaskItem && oldTask?.done == false
          ? _withAutomationEvents(data, [?automationForTask(record)])
          : data,
    );
  }

  Future<void> _deleteRecord(Object record) async {
    if (record is CalendarEvent && record.isReadOnly) return;
    if (record is CalendarEvent && record.recurringSeriesId != null) {
      await _skipOccurrence(record);
      return;
    }
    if (_repeatingTask(record) case final row?) {
      await _skipRepeatingTask(row);
      return;
    }
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
    final hierarchy = TaskHierarchy(candidates);
    final tasks = [
      for (final task in candidates)
        if (identical(detached[task.id], task) &&
            hierarchy.parentIssue(task.id, restored.id) == null)
          task.withParent(restored.id)
        else
          task,
    ];
    _update(_data.copyWith(tasks: tasks));
  }

  NoteItem? _homeNote() {
    NoteItem? latest;
    final mode = _focus;
    for (final note in _notesInMode(mode)) {
      if (mode == null && (note.category != null || !note.noteToSelf)) continue;
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
    final content = _categoryScope(editor);
    if (MediaQuery.sizeOf(context).width < 720) {
      return showModalBottomSheet<Object>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: paper,
        builder: (_) => content,
      );
    }
    return showDialog<Object>(
      context: context,
      builder: (_) => Dialog(backgroundColor: paper, child: content),
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
    final defaults = _captureDefaults;
    final result = await _showEditor(
      QuickCapture(
        date: destination == _Destination.calendar ? _calendarDate : _today,
        kind: captureKind,
        initialTaskDate: destination == _Destination.calendar
            ? _calendarDate
            : defaults.dateFor(_today),
        initialTaskCategory: _defaultTaskCategory(defaults),
        initialCategory:
            captureKind == RecordKind.event &&
                calendar?.accountId == _localCalendarAccount
            ? (calendar!.calendarId == 'general' ? '' : calendar.calendarId)
            : _preferredFocusCategory,
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
    final SchedulingSettings? settings;
    try {
      settings = _planningPreferences(expandCategories: true);
    } catch (_) {
      _inform('Your scheduling settings could not be opened.');
      return;
    }
    final categories = _expandCategoryScope(_focus);
    final result = await _showEditor(
      PlanDaySheet(
        day: day,
        events: [..._standaloneEvents(prior.events), ...appointments],
        tasks: _taskFeed.planningTasks(prior.tasks, day),
        settings: settings,
        categories: categories,
      ),
    );
    if (!mounted || result is! PlanSelection || result.tasks.isEmpty) return;
    final finalAppointments = await _planningCalendar(day);
    if (!mounted || finalAppointments == null) return;
    final checkedFeed = _appleFeed.events;
    final checkedImports = _icsFeed.events;
    final checkedSeries = _internalFeed.events;
    final beforeAcceptance = _data;
    if (!identical(
          prior.sections[_scheduleSettingsKey],
          beforeAcceptance.sections[_scheduleSettingsKey],
        ) ||
        !identical(
          prior.sections[_categorySettingsKey],
          beforeAcceptance.sections[_categorySettingsKey],
        )) {
      _inform('Availability changed. Preview the day again.');
      return;
    }
    final current = await compute(_reviewSchedule, (
      window: result.window,
      reservationStart: result.reservationStart,
      events: [
        ..._standaloneEvents(beforeAcceptance.events),
        ...finalAppointments,
      ],
      tasks: _taskFeed.planningTasks(beforeAcceptance.tasks, day),
      settings: settings,
      categories: categories,
    ));
    if (!mounted) return;
    final available = {
      for (final entry in current.scheduled) entry.task.id: entry,
    };
    final selectedIds = result.tasks.map((item) => item.task.id).toSet();
    final now = DateTime.now();
    if (!identical(beforeAcceptance, _data) ||
        !identical(checkedFeed, _appleFeed.events) ||
        !identical(checkedImports, _icsFeed.events) ||
        !identical(checkedSeries, _internalFeed.events) ||
        selectedIds.length != result.tasks.length ||
        result.tasks.any((entry) {
          final checked = available[entry.task.id];
          return checked == null ||
              !sameReviewedSchedule(entry, checked) ||
              entry.blocks.any((block) => block.start.isBefore(now)) ||
              checked.task.prerequisites.any(
                (id) =>
                    !current.satisfiedPrerequisites.contains(id) &&
                    !selectedIds.contains(id),
              );
        })) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The available time changed. Preview the day again.'),
        ),
      );
      return;
    }

    await _storeReviewedBlocks(beforeAcceptance, [
      for (final proposed in result.tasks) available[proposed.task.id]!,
    ]);
  }

  Future<List<CalendarEvent>?> _planningCalendar(
    DateTime day, {
    DateTime? firstDay,
    DateTime? lastDay,
    bool reportProblem = true,
  }) async {
    final apple = _selectedAppleCalendars;
    final imports = _selectedIcsCalendars;
    final series = _eventSeries;
    if (apple.isEmpty && imports.isEmpty && series.isEmpty) return const [];
    await Future.wait<void>([
      if (apple.isNotEmpty) _refreshExternalCalendars(day: day, force: true),
      if (imports.isNotEmpty) _icsFeed.refresh(day: day, sources: imports),
      if (series.isNotEmpty) _internalFeed.refresh(day: day, sources: series),
    ]);
    if (!mounted) return null;
    bool covered(bool Function(DateTime) covers) =>
        covers(firstDay ?? day) && covers(lastDay ?? day);
    if (apple.isNotEmpty &&
        (_appleFeed.problem != null || !covered(_appleFeed.covers))) {
      if (reportProblem) {
        _inform(
          _appleFeed.problem ?? 'Apple calendars could not be refreshed.',
        );
      }
      return null;
    }
    if (imports.isNotEmpty &&
        (_icsFeed.problem != null || !covered(_icsFeed.covers))) {
      if (reportProblem) {
        _inform(
          _icsFeed.problem ?? 'Imported calendars could not be refreshed.',
        );
      }
      return null;
    }
    if (series.isNotEmpty &&
        (_internalFeed.problem != null || !covered(_internalFeed.covers))) {
      if (reportProblem) {
        _inform(
          _internalFeed.problem ?? 'Repeating events could not be refreshed.',
        );
      }
      return null;
    }
    return [
      ..._appleFeed.events.map(_fromApple),
      for (final row in _icsFeed.events) row.event,
      for (final row in _internalFeed.events) row.event,
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
      Future<CaptureArchiveEntry> persist(
        Uint8List bytes,
        DateTime recordedAt,
      ) => _saveVoiceDraft(bytes, recordedAt, initialText);
      final CaptureArchiveEntry? draft;
      if (heldAction != null) {
        draft = await _heldVoiceOverlay.show(
          context,
          action: heldAction,
          onSave: persist,
        );
      } else if (MediaQuery.sizeOf(context).width < 720) {
        draft = await showModalBottomSheet<CaptureArchiveEntry>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: paper,
          builder: (_) => VoiceCaptureSheet(onSave: persist),
        );
      } else {
        draft = await showDialog<CaptureArchiveEntry>(
          context: context,
          barrierDismissible: false,
          builder: (_) => Dialog(
            backgroundColor: paper,
            child: VoiceCaptureSheet(onSave: persist),
          ),
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
    bool offerVoice = false,
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
      defaultTaskDate: _captureDefaults.dateFor,
      defaultCategory: _reviewDefaultCategory,
      onInspectWorkout: _inspectWorkoutCapture,
      initialDraft: draft,
      offerVoice: offerVoice && mediaAvailable && !kIsWeb,
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
    final request = MediaQuery.sizeOf(context).width < 720
        ? await showModalBottomSheet<CaptureReviewVoiceRequest>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            isDismissible: false,
            enableDrag: false,
            backgroundColor: paper,
            builder: (_) => sheet,
          )
        : await showDialog<CaptureReviewVoiceRequest>(
            context: context,
            barrierDismissible: false,
            builder: (_) => Dialog(backgroundColor: paper, child: sheet),
          );
    if (request != null && mounted) {
      await _openVoiceCapture(initialText: request.text);
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
      focusCategory: _preferredFocusCategory,
      selectedRecordId: _inspected == null ? null : _recordId(_inspected!),
      categories: _categories(),
      records: [
        for (final task in _captureTaskMatches(source.capturedAt))
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
  }) async {
    final source = await _saveCaptureDraft(draftId: draftId, text: text);
    final liveWorkout = _allows(EasyFeature.workouts)
        ? _liveWorkoutFor(source.capturedAt, _gymSessions ?? const [])
        : null;
    return interpretCapture(
      _captureInput(source),
      matchesLiveWorkout: liveWorkout == null
          ? null
          : (entry) =>
                reviewGymWorkoutCapture(
                  session: liveWorkout,
                  originalText: entry,
                  recordedAt: source.capturedAt,
                ).draft !=
                null,
    );
  }

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
    Map<CaptureProposal, CaptureWorkoutSelection> workoutChanges,
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
        ) ||
        workoutChanges.keys.any(
          (entry) =>
              entry.draft is! CaptureWorkoutDraft || !selected.contains(entry),
        )) {
      return 'Choose the ready items you want to add.';
    }

    final tasks = [...previous.tasks];
    final events = [...previous.events];
    final notes = [...previous.notes];
    final repeats = <String, RecurringTaskSeries>{};
    final automation = <AutomationEvent>[];
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
              category:
                  draft.category ?? _reviewDefaultCategory(proposal) ?? '',
              date:
                  draft.dueDate ?? _captureDefaults.dateFor(source.capturedAt),
              schedulingHold: taskSchedulingHoldHint(draft.title),
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
              category:
                  draft.category ?? _reviewDefaultCategory(proposal) ?? '',
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
              category: draft.category ?? _reviewDefaultCategory(proposal),
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
          final target =
              capturedSession ?? _liveWorkoutFor(source.capturedAt, gym);
          final literal = _workoutSourceText(review, proposal);
          if (workoutChanges[proposal] case final reviewed?) {
            if (target == null ||
                reviewed.draft.originalText != literal ||
                (reviewed.markExplicitCompletion &&
                    !reviewed.draft.canConfirmCompletion)) {
              return 'The workout changed. Review the current sets again.';
            }
            final updated = reviewed.draft.apply(
              target,
              entryId: id,
              markExplicitCompletion: reviewed.markExplicitCompletion,
            );
            if (updated == null) {
              return 'The workout changed. Review the current sets again.';
            }
            gym[gym.indexOf(target)] = updated;
            capturedSession = updated;
            continue;
          }
          final entry = GymLogEntry(
            id: id,
            title: draft.title,
            loggedAt: source.capturedAt,
            actual: draft.details == draft.title ? null : draft.details,
            captureText: literal.length <= 2400 ? literal : null,
          );
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
          nutrition = current.copyWith(
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
          if (index >= 0 &&
              !_taskFeed.ids.contains(draft.targetId) &&
              !tasks[index].done) {
            tasks[index] = tasks[index].withDone(
              true,
              completedAt: DateTime.now().toUtc(),
            );
            if (automationForTask(tasks[index]) case final event?) {
              automation.add(event);
            }
            continue;
          }
          final row = _taskFeed.row(
            draft.targetId,
            previous.tasks,
            _today,
            sourceDate: source.capturedAt.toLocal(),
          );
          if (row == null ||
              row.task.done ||
              repeats.containsKey(row.series.id)) {
            return 'Review the task’s current state.';
          }
          final completed = row.series.complete(
            row.occurrence,
            at: DateTime.now().toUtc(),
          );
          repeats[row.series.id] = completed;
          if (_automationForRepeatedTask(completed, row.task.id)
              case final event?) {
            automation.add(event);
          }
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
    if (repeats.isNotEmpty) {
      updated = _withTaskSeries(updated, [
        for (final series in _taskFeed.series) repeats[series.id] ?? series,
      ]);
    }
    await _commitReviewedData(
      previous,
      _withAutomationEvents(updated, automation),
      operationId: '${source.id}-apply-${source.revision}',
      sessions: gym,
    );
    return null;
  }

  Future<void> _editRecord(Object existing) async {
    if (existing is CalendarEvent && existing.isReadOnly) return;
    if (existing is CalendarEvent && existing.plannedTaskId != null) {
      if (!_allows(EasyFeature.planning)) {
        _inform('Enable planning in Settings to move this time block.');
        return;
      }
      await _openManualBlock(existing);
      return;
    }
    if (existing is CalendarEvent && existing.recurringSeriesId != null) {
      await _editOccurrence(existing);
      return;
    }
    if (_repeatingTask(existing) case final row?) {
      await _editRepeatingTask(row);
      return;
    }
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
        _workspaceTasks.where((task) => task.id == link.id).firstOrNull ??
            _linkedTaskOccurrence(link.id),
      NoteLinkKind.event =>
        _data.events.where((event) => event.id == link.id).firstOrNull,
    };
    if (target == null) {
      _inform('The linked record is unavailable.');
      return;
    }
    final Object shown;
    if (target is CalendarEvent && _eventSeriesIds.contains(target.id)) {
      final occurrence = _internalFeed.events
          .where(
            (row) =>
                row.series.id == target.id && !row.event.end.isBefore(_today),
          )
          .firstOrNull;
      if (occurrence == null) {
        _inform(
          'This series has no upcoming occurrence in the current calendar window.',
        );
        return;
      }
      shown = occurrence.event;
    } else {
      shown = target;
    }
    if (shown is CalendarEvent) _changeDate(shown.start);
    _navigate(
      link.kind == NoteLinkKind.task
          ? _Destination.tasks
          : _Destination.calendar,
    );
    await _openRecord(shown);
  }

  Future<void> _openRecord(Object record) async {
    final current = _isAppleProjection(record)
        ? _currentAppleProjection(record as CalendarEvent)
        : record;
    if (current == null) {
      _inform('This Apple Calendar event is unavailable.');
      return;
    }
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => _inspected = current);
      return;
    }
    final appleAction = _appleActionFor(record);
    final action = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: paper,
      showDragHandle: true,
      builder: (context) => _appleDetailsWhileAllowed(
        record,
        (visibleRecord) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .68,
          ),
          child: _categoryScope(
            _RecordDetails(
              record: visibleRecord,
              onEdit: () => Navigator.pop(context, 'edit'),
              onToggleDone: switch (record) {
                TaskItem task => () => _toggleTaskFromDetails(context, task),
                _ => null,
              },
              onDelete: () => Navigator.pop(context, 'delete'),
              noteTargets: record is NoteItem ? _noteTargets() : const [],
              onOpenNoteLink: (link) => Navigator.pop(context, link),
              onEstimate: _canEstimate(record)
                  ? () => Navigator.pop(context, 'estimate')
                  : null,
              appleActionLabel: appleAction?.label,
              onAppleCopy: appleAction != null
                  ? () => Navigator.pop(context, appleAction)
                  : null,
              repeatingTask: _repeatingTask(record) != null,
              onRepeat: _canRepeatEvent(record) || _canRepeatTask(record)
                  ? () => Navigator.pop(context, 'repeat')
                  : null,
              onAssignPlace: _canAssignPlace(record)
                  ? () => Navigator.pop(context, 'place')
                  : null,
              onAddSubtask: _canAddSubtask(record)
                  ? () => Navigator.pop(context, 'child')
                  : null,
              onBreakdown: _canAddSubtask(record)
                  ? () => Navigator.pop(context, 'breakdown')
                  : null,
              reminderSet: _hasRecordReminder(record),
              onReminder: _recordReminderTarget(record) != null
                  ? () => Navigator.pop(context, 'reminder')
                  : null,
              onSchedule: _canScheduleTask(record)
                  ? () => Navigator.pop(context, 'schedule')
                  : null,
              onTimingHistory: _canSeeTaskTiming(record)
                  ? () => Navigator.pop(context, 'timing')
                  : null,
              onTrackActivity: _canTrackActivity(record)
                  ? () => Navigator.pop(context, 'track-time')
                  : null,
              onRemoveFutureBlocks: _canRemoveFutureBlocks(record)
                  ? () => Navigator.pop(context, 'future-blocks')
                  : null,
            ),
          ),
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
    if (action is _AppleRecordAction && record is CalendarEvent) {
      await _appleRecordAction(record, action);
    }
    if (action == 'repeat' && record is CalendarEvent) {
      await _setEventRepeat(record);
    }
    if (action == 'repeat' && record is TaskItem) {
      await _setTaskRepeat(record);
    }
    if (action == 'place' && record is CalendarEvent) {
      await _assignPlace(record);
    }
    if (action == 'child' && record is TaskItem) await _addSubtask(record);
    if (action == 'breakdown' && record is TaskItem) {
      await _breakDownTask(record);
    }
    if (action == 'reminder') await _editRecordReminder(record);
    if (action == 'schedule') await _openManualBlock(record);
    if (action == 'timing' && record is TaskItem) await _openTaskTiming(record);
    if (action == 'track-time') await _openActualActivity(record);
    if (action == 'future-blocks' && record is TaskItem) {
      await _removeFutureBlocks(record);
    }
  }

  bool _canRepeatEvent(Object? record) =>
      record is CalendarEvent &&
      !record.isReadOnly &&
      record.plannedTaskId == null &&
      (record.recurringSeriesId != null ||
          !_eventSeriesIds.contains(record.id));

  bool _canCopyToApple(Object? record) =>
      record is CalendarEvent &&
      !record.isReadOnly &&
      record.recurringSeriesId == null &&
      !_eventSeriesIds.contains(record.id) &&
      widget.calendarAdapter.isAvailable &&
      _allows(EasyFeature.externalCalendars) &&
      _appleCopyFor(record.id) == null;

  CalendarOccurrenceIdentity? _appleCopyFor(String localId) {
    final unsaved = _unsavedAppleCopies[localId];
    if (unsaved != null) return unsaved.id;
    final saved = _data.sections[_appleCopiesKey];
    if (saved is! Map<String, dynamic>) return null;
    final entry = saved[localId];
    if (entry is! Map<String, dynamic>) return null;
    try {
      final eventId = entry['eventId'];
      if (eventId is! String || eventId.isEmpty) return null;
      return CalendarOccurrenceIdentity(
        calendar: CalendarIdentity.fromJson(entry),
        eventId: eventId,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _copyToApple(CalendarEvent event) async {
    if (_copyingApple || !_canCopyToApple(event)) return;
    _copyingApple = true;
    var copied = false;
    try {
      final adapter = widget.calendarAdapter;
      if (await adapter.accessStatus() != EventKitCalendarAccess.full) {
        if (mounted) {
          _inform('Connect Apple Calendar in Settings before copying.');
        }
        return;
      }
      final sources = (await adapter.calendars())
          .where((source) => source.canWrite)
          .toList();
      if (!mounted) return;
      if (sources.isEmpty) {
        _inform('No writable Apple calendars are available.');
        return;
      }
      final defaultSource = _calendarPreferences?.defaultWriteCalendar;
      sources.sort((first, second) {
        if (first.id == defaultSource) {
          return second.id == defaultSource ? 0 : -1;
        }
        if (second.id == defaultSource) return 1;
        return first.name.compareTo(second.name);
      });
      final destination = await showDialog<CalendarSource>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Choose Apple calendar'),
          children: [
            for (final source in sources)
              ListTile(
                title: Text(source.name),
                subtitle: Text(source.accountName),
                onTap: () => Navigator.pop(context, source),
              ),
          ],
        ),
      );
      if (!mounted || destination == null) return;
      final review = await adapter.prepareCreate(
        destination: destination,
        draft: EventKitEventDraft(
          title: event.title,
          start: event.start,
          end: event.end,
          allDay: event.allDay,
          location: event.location,
          notes: event.description,
        ),
      );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) {
          final format = MaterialLocalizations.of(context);
          String when(DateTime instant) {
            final local = instant.toLocal();
            final day = format.formatMediumDate(local);
            if (event.allDay) return day;
            return '$day · ${format.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
          }

          final last = event.allDay ? plusDays(review.end, -1) : review.end;
          return AlertDialog(
            scrollable: true,
            title: const Text('Copy to Apple Calendar?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(review.draft.title, style: sectionHeadingStyle),
                Text(
                  '${review.destination.name} · ${review.destination.accountName}',
                ),
                Text(
                  event.allDay && sameDay(review.start, last)
                      ? '${when(review.start)} · All day'
                      : '${when(review.start)} to ${when(last)}',
                ),
                if (review.timeZoneId case final zone?)
                  Text(zone, style: contentMetadataStyle),
                if (review.draft.location case final location?) Text(location),
                if (review.draft.notes case final notes?) Text(notes),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add to calendar'),
              ),
            ],
          );
        },
      );
      if (!mounted || approved != true || !_canCopyToApple(event)) return;
      if (!_data.events.any((current) => identical(current, event))) {
        _inform('This event changed. Open its current details to copy it.');
        return;
      }
      final result = await adapter.createReviewedEventWithReceipt(
        review,
        confirmed: true,
      );
      copied = true;
      if (!mounted) return;
      await _persistAppleReceipt(event.id, result);
      if (!mounted) return;
      _inform('Added to ${destination.name}.');
      unawaited(_refreshExternalCalendars(force: true));
    } catch (_) {
      if (mounted) {
        _inform(
          copied
              ? 'Apple Calendar saved this copy. Save its link again in Easy.'
              : 'The copy could not be confirmed. Check Apple Calendar before trying again.',
        );
      }
    } finally {
      _copyingApple = false;
    }
  }

  bool _canEstimate(Object? record) =>
      record is TaskItem &&
      !record.done &&
      !_taskFeed.ids.contains(record.id) &&
      _repeatingTask(record) == null &&
      _allows(EasyFeature.ai) &&
      (_ai?.settings.allowEstimates ?? false);

  Future<void> _suggestDuration(TaskItem task) async {
    final runtime = _ai;
    if (runtime == null || !runtime.settings.allowEstimates) return;
    if (_hasTaskHistory) await _prepareTaskHistory();
    if (!mounted ||
        !identical(runtime, _ai) ||
        !_data.tasks.any((record) => identical(record, task))) {
      return;
    }
    final revision = _contentRevision;
    final historyKey = _taskHistoryKey;
    final history = _providerDurationHistoryFor(task);
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
        sampleDurationsMinutes: history?.compatibleMinutes ?? const [],
        durationHistory: history,
      ),
      currentRevision: (id) =>
          mounted &&
              id == scope.id &&
              revision == _contentRevision &&
              historyKey == _taskHistoryKey
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
    if (!identical(current, task) || historyKey != _taskHistoryKey) {
      _inform('This task changed. Review its duration again.');
      return;
    }
    _saveRecord(task.withEstimate(minutes));
  }

  Widget? _focusedContent(BuildContext context, FocusMode? mode) {
    final suggestion = _focusSuggestionAction();
    final children = <Widget>[
      if (suggestion != null)
        Align(alignment: AlignmentDirectional.centerStart, child: suggestion),
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
    int,
    List<InternalRecurringEvent>,
    List<InternalWorkspaceEvent>,
    WorkspaceCategories,
  )?
  _visibleEventRevision;
  List<CalendarEvent> _visibleEvents = const [];

  List<CalendarEvent> _calendarEvents(FocusMode? mode) {
    final preferences = _calendarPreferences;
    final revision = (
      _data.events,
      _allows(EasyFeature.externalCalendars) && _appleFeed.hasVerifiedAccess
          ? _appleFeed.events
          : const <SourcedCalendarEvent<ExternalCalendarEvent>>[],
      _icsFeed.events,
      preferences,
      mode,
      _appleCopyRevision,
      _eventSeries,
      _internalFeed.events,
      _catalog,
    );
    if (_visibleEventRevision == revision) return _visibleEvents;
    final calendars = preferences?.calendarsFor(mode?.id);
    final categoryScope = _expandCategoryScope(mode);
    bool visible(CalendarEvent event) =>
        calendars?.contains(_localCalendar(event.category)) ??
        (categoryScope?.contains(_catalog.canonicalId(event.category)) ?? true);
    final local = [
      for (final event in _standaloneEvents(_data.events))
        if (visible(event)) event,
    ];
    final linked = <CalendarOccurrenceIdentity, CalendarEvent>{
      if (_data.sections[_appleCopiesKey] != null ||
          _unsavedAppleCopies.isNotEmpty)
        for (final event in local) ?_appleCopyFor(event.id): event,
    };
    _visibleEvents = [
      ...local,
      for (final row in _internalFeed.events)
        if (visible(row.event)) row.event,
      for (final event in revision.$2)
        if ((calendars?.contains(event.id.calendar) ?? false) &&
            !_sameAppleEvent(linked[event.id], event.event))
          _fromApple(event),
      for (final row in revision.$3)
        if (calendars?.contains(row.calendar) ?? false) row.event,
    ];
    _visibleEventRevision = revision;
    return _visibleEvents;
  }

  bool _sameAppleEvent(CalendarEvent? local, ExternalCalendarEvent apple) =>
      local != null &&
      local.title == apple.title &&
      local.allDay == apple.allDay &&
      local.start.isAtSameMomentAs(apple.start) &&
      local.end.isAtSameMomentAs(apple.end);

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
    if (_requiresWorkspaceSetup) {
      return WorkspaceSetupPage(
        appName: appName,
        onChosen: _finishWorkspaceSetup,
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < 720;
    final compact = width < 900;
    final space = _space;
    final mode = _focus;
    final modes = _availableModes.toList(growable: false);
    final events = _calendarEvents(mode);
    final tasks = _tasksInMode(mode);
    final notes = _notesInMode(mode);
    final showSchedule = mode?.sections.contains(FocusSection.schedule) ?? true;
    final showTasks = mode?.sections.contains(FocusSection.tasks) ?? true;
    final focusedContent = _focusedContent(context, mode);
    final inspectedAppleAction = _appleActionFor(_inspected);
    final visibleCalendars =
        _calendarPreferences?.calendarsFor(space) ?? const <CalendarIdentity>{};
    final calendarProblem =
        (_allows(EasyFeature.externalCalendars) &&
                visibleCalendars.any(_isAppleCalendar)
            ? _appleFeed.problem
            : null) ??
        (visibleCalendars.any((id) => id.accountId == workspaceIcsAccountId)
            ? _icsFeed.problem
            : null) ??
        _internalFeed.problem;
    final todayNote = mobile ? _homeNote() : null;
    final canReviewObjectives =
        _allows(EasyFeature.planning) &&
        showTasks &&
        tasks.any((task) => !task.done);
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
              onWhatFitsNow: canReviewObjectives ? _openTaskObjectives : null,
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
              onWhatFitsNow: canReviewObjectives ? _openTaskObjectives : null,
              events: events,
              tasks: tasks,
              onEventTap: _openRecord,
              onTaskTap: _openRecord,
              onTaskToggle: _toggleTask,
            ),
          if (_mountedDestinations.contains(_Destination.calendar))
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
            )
          else
            const SizedBox.shrink(),
          if (_mountedDestinations.contains(_Destination.tasks))
            TasksPage(
              tasks: tasks,
              onToggle: _toggleTask,
              onTaskTap: _openRecord,
            )
          else
            const SizedBox.shrink(),
          if (_mountedDestinations.contains(_Destination.notes))
            NotesPage(notes: notes, onNoteTap: _openRecord)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
    };
    return _categoryScope(
      Listener(
        onPointerDown: (_) => _lastWorkspaceInput = DateTime.now(),
        onPointerSignal: (_) => _lastWorkspaceInput = DateTime.now(),
        child: CallbackShortcuts(
          bindings: shortcuts,
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, _) {
              _lastWorkspaceInput = DateTime.now();
              return KeyEventResult.ignored;
            },
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
                                bottom:
                                    MediaQuery.paddingOf(context).bottom + 20,
                                child: HoldCaptureButton(
                                  onTap: _capture,
                                  onHeldRecord:
                                      kIsWeb ||
                                          !_allows(EasyFeature.captureMedia)
                                      ? null
                                      : (action) => _openVoiceCapture(
                                          heldAction: action,
                                        ),
                                ),
                              ),
                              Positioned.fill(
                                child: OrbitNavigation(
                                  destinations: [
                                    for (final destination
                                        in _Destination.values)
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
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    14,
                                    14,
                                  ),
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
                                      if (_inspected != null &&
                                          width >= 1000) ...[
                                        const SizedBox(width: 12),
                                        SizedBox(
                                          width: width >= 1250 ? 294 : 264,
                                          child: _Surface(
                                            child: _RecordDetails(
                                              record: _inspected!,
                                              onClose: () => setState(
                                                () => _inspected = null,
                                              ),
                                              onEdit: () =>
                                                  _editRecord(_inspected!),
                                              onToggleDone:
                                                  switch (_inspected) {
                                                    TaskItem task =>
                                                      () => _toggleTask(task),
                                                    _ => null,
                                                  },
                                              onDelete: () =>
                                                  _deleteRecord(_inspected!),
                                              noteTargets:
                                                  _inspected is NoteItem
                                                  ? _noteTargets()
                                                  : const [],
                                              onOpenNoteLink: _openNoteLink,
                                              onEstimate:
                                                  _canEstimate(_inspected)
                                                  ? () => _suggestDuration(
                                                      _inspected! as TaskItem,
                                                    )
                                                  : null,
                                              appleActionLabel:
                                                  inspectedAppleAction?.label,
                                              onAppleCopy:
                                                  inspectedAppleAction != null
                                                  ? () => _appleRecordAction(
                                                      _inspected!
                                                          as CalendarEvent,
                                                      inspectedAppleAction,
                                                    )
                                                  : null,
                                              repeatingTask:
                                                  _repeatingTask(_inspected) !=
                                                  null,
                                              onRepeat: switch (_inspected) {
                                                CalendarEvent event
                                                    when _canRepeatEvent(
                                                      event,
                                                    ) =>
                                                  () => _setEventRepeat(event),
                                                TaskItem task
                                                    when _canRepeatTask(task) =>
                                                  () => _setTaskRepeat(task),
                                                _ => null,
                                              },
                                              onAssignPlace:
                                                  _canAssignPlace(_inspected)
                                                  ? () => _assignPlace(
                                                      _inspected!
                                                          as CalendarEvent,
                                                    )
                                                  : null,
                                              onAddSubtask:
                                                  _canAddSubtask(_inspected)
                                                  ? () => _addSubtask(
                                                      _inspected! as TaskItem,
                                                    )
                                                  : null,
                                              onBreakdown:
                                                  _canAddSubtask(_inspected)
                                                  ? () => _breakDownTask(
                                                      _inspected! as TaskItem,
                                                    )
                                                  : null,
                                              reminderSet: _hasRecordReminder(
                                                _inspected,
                                              ),
                                              onReminder:
                                                  _recordReminderTarget(
                                                        _inspected,
                                                      ) !=
                                                      null
                                                  ? () => _editRecordReminder(
                                                      _inspected!,
                                                    )
                                                  : null,
                                              onSchedule:
                                                  _canScheduleTask(_inspected)
                                                  ? () => _openManualBlock(
                                                      _inspected!,
                                                    )
                                                  : null,
                                              onTimingHistory:
                                                  _canSeeTaskTiming(_inspected)
                                                  ? () => _openTaskTiming(
                                                      _inspected! as TaskItem,
                                                    )
                                                  : null,
                                              onTrackActivity:
                                                  _canTrackActivity(_inspected)
                                                  ? () => _openActualActivity(
                                                      _inspected!,
                                                    )
                                                  : null,
                                              onRemoveFutureBlocks:
                                                  _canRemoveFutureBlocks(
                                                    _inspected,
                                                  )
                                                  ? () => _removeFutureBlocks(
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
    SchedulingSettings? settings,
    Set<String>? categories,
  })
  input,
) => planWorkspaceDay(
  window: input.window,
  reservationStart: input.reservationStart,
  settings: input.settings,
  categories: input.categories,
  events: input.events,
  tasks: input.tasks,
);

String _normalizeIcsFile(Uint8List data) =>
    IcsCalendar.parseBytes(data).encode();

int _stableRevision(Object value) => sha256
    .convert(utf8.encode(jsonEncode(value)))
    .bytes
    .take(6)
    .fold(0, (number, byte) => number * 256 + byte);

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
