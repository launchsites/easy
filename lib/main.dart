import 'dart:async';

import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_page.dart';
import 'capture/capture_archive.dart';
import 'capture/capture_interpreter.dart';
import 'capture/capture_review_sheet.dart';
import 'gym_mode_ui.dart';
import 'gym_session.dart';
import 'list_pages.dart';
import 'mobile_home.dart';
import 'orbit_navigation.dart';
import 'quick_capture.dart';
import 'record_editor.dart';
import 'scheduling/plan_day_sheet.dart';
import 'scheduling/planner.dart';
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

class _Workspace extends StatefulWidget {
  const _Workspace({required this.openStore});

  final WorkspaceStoreOpener openStore;

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  final _legacyPreferences = SharedPreferencesAsync();
  WorkspaceStore? _store;
  int? _persistedRevision;
  var _openingStore = false;
  var _reviewSaving = false;
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final store = _store;
    if (store != null) {
      unawaited(_pendingSave.then((_) => store.close()));
    }
    super.dispose();
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
      final snapshot = revision.snapshot;
      final data = WorkspaceData.decode(snapshot.workspaceJson);
      final sessions = _decodeRecords(
        snapshot.gymSessionJson,
        GymSession.decode,
      );
      final plans = _decodeRecords(
        snapshot.workoutPlanJson,
        WorkoutPlan.decode,
      );
      if (!mounted) return;
      setState(() {
        _persistedRevision = revision.revision;
        _data = data;
        _gymSessions = sessions;
        _workoutPlans = plans;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      _openingStore = false;
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
  }) {
    if (_reviewSaving) {
      return Future.error(StateError('A reviewed change is being saved.'));
    }
    setState(() => _reviewSaving = true);
    final operation = _pendingSave.then((_) async {
      try {
        if (!mounted || !identical(_data, previous)) {
          throw StateError('The workspace changed after review.');
        }
        await _saveMutation(
          WorkspaceMutation.workspace(updated.encode()),
          operationId: operationId,
        );
        if (mounted) setState(() => _assignData(updated));
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
    );
  }

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
    if (day != _calendarDate) setState(() => _calendarDate = day);
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
    for (final note in _data.notes) {
      if (note.category?.toLowerCase() != _space) continue;
      if (_space == null && !note.noteToSelf) continue;
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
    final result = await _showEditor(
      QuickCapture(
        date: destination == _Destination.calendar ? _calendarDate : _today,
        kind:
            kind ??
            switch (destination) {
              _Destination.calendar => RecordKind.event,
              _Destination.notes => RecordKind.note,
              _ => RecordKind.task,
            },
        initialTaskDate: _today,
        initialCategory: _space,
        noteToSelf: noteToSelf,
        allowReview: !noteToSelf,
      ),
    );
    if (result == null || !mounted) return;
    if (result case final CaptureReviewRequest request) {
      await _openCaptureReview(request.text);
      return;
    }
    _saveRecord(result);
    if (result is CalendarEvent && destination == _Destination.calendar) {
      _changeDate(result.start);
    }
  }

  Future<void> _planDay() async {
    if (_reviewSaving) return;
    final prior = _data;
    final result = await _showEditor(
      PlanDaySheet(day: _today, events: prior.events, tasks: prior.tasks),
    );
    if (!mounted || result is! PlanSelection || result.tasks.isEmpty) return;
    final beforeAcceptance = _data;
    final current = await compute(_reviewSchedule, (
      window: result.window,
      reservationStart: result.reservationStart,
      events: beforeAcceptance.events,
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

  Future<void> _openCaptureReview(String text) async {
    final sheet = CaptureReviewSheet(
      initialText: text,
      drafts: _data.captures,
      onReview: _reviewCaptureText,
      onApply: _applyCaptureReview,
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

  CaptureInput _captureInput(CaptureArchiveEntry source) => CaptureInput(
    id: source.id,
    revision: source.revision,
    text: source.text,
    context: CaptureContext(
      anchor: source.capturedAt,
      revision: _contentRevision,
      focusCategory: _space,
      selectedRecordId: _inspected == null ? null : _recordId(_inspected!),
      categories: {
        for (final category in spaceColors.keys) category: spaceName(category),
      },
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
    return interpretCapture(_captureInput(source));
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
          notes.add(
            NoteItem(
              id: id,
              title: draft.title,
              body: draft.details,
              updated: source.capturedAt,
              category: draft.category ?? 'gym',
            ),
          );
        case CaptureMealDraft():
          notes.add(
            NoteItem(
              id: id,
              title: draft.title,
              body: draft.description,
              updated: source.capturedAt,
              category: draft.category ?? 'health',
            ),
          );
        case CaptureCompleteTaskDraft():
          final index = tasks.indexWhere((task) => task.id == draft.targetId);
          if (index < 0 || tasks[index].done) {
            return 'Review the task’s current state.';
          }
          tasks[index] = tasks[index].withDone(true);
      }
    }

    await _commitReviewedData(
      previous,
      previous.copyWith(
        tasks: tasks,
        events: events,
        notes: notes,
        captures: _upsert(
          previous.captures,
          source.markApplied(),
          (entry) => entry.id,
        ),
      ),
      operationId: '${source.id}-apply-${source.revision}',
    );
    return null;
  }

  Future<void> _editRecord(Object existing) async {
    final result = await _showEditor(
      RecordEditor(
        date: _destination == _Destination.calendar ? _calendarDate : _today,
        kind: _recordKind(existing),
        event: existing is CalendarEvent ? existing : null,
        task: existing is TaskItem ? existing : null,
        taskItems: _data.tasks,
        note: existing is NoteItem ? existing : null,
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

  Future<void> _openRecord(Object record) async {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => _inspected = record);
      return;
    }
    final action = await showModalBottomSheet<String>(
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
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') await _editRecord(record);
    if (action == 'delete') await _deleteRecord(record);
  }

  Future<void> _search() async {
    if (_reviewSaving) return;
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _SearchDialog(
        records: [..._data.events, ..._data.tasks, ..._data.notes],
      ),
    );
    if (result == null || !mounted) return;
    _navigate(switch (result) {
      CalendarEvent() => _Destination.calendar,
      TaskItem() => _Destination.tasks,
      _ => _Destination.notes,
    });
    _changeSpace(null);
    if (result is CalendarEvent) _changeDate(result.start);
    await _openRecord(result);
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
    final events = space == null
        ? _data.events
        : _data.events
              .where((item) => item.category.toLowerCase() == space)
              .toList();
    final tasks = space == null
        ? _data.tasks
        : _data.tasks
              .where((item) => item.category.toLowerCase() == space)
              .toList();
    final notes = space == null
        ? _data.notes
        : _data.notes
              .where((item) => item.category?.toLowerCase() == space)
              .toList();
    final todayNote = mobile ? _homeNote() : null;
    final canPlan = _data.tasks.any(
      (task) => !task.done && (task.estimatedMinutes ?? 0) > 0,
    );
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
              modeControl: _ModeControl(
                mode: space,
                showCurrentMode: false,
                onModeChanged: _changeSpace,
              ),
              note: todayNote,
              focusedContent: space == 'gym' ? _gymOverview(context) : null,
              onPlanDay: canPlan && space != 'gym' ? _planDay : null,
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
              onPlanDay: canPlan ? _planDay : null,
              events: events,
              tasks: tasks,
              onEventTap: _openRecord,
              onTaskTap: _openRecord,
              onTaskToggle: _toggleTask,
            ),
          CalendarPage(
            date: _calendarDate,
            events: events,
            onDateChanged: _changeDate,
            onEventTap: _openRecord,
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
                                  displayBrand:
                                      _destination != _Destination.calendar,
                                  onSpaceChanged: _changeSpace,
                                  onSearch: _search,
                                ),
                              Expanded(child: page),
                            ],
                          ),
                          Positioned(
                            right: 20,
                            bottom: MediaQuery.paddingOf(context).bottom + 20,
                            child: FloatingActionButton(
                              heroTag: 'capture',
                              tooltip: 'Add item',
                              onPressed: _capture,
                              backgroundColor: accent,
                              foregroundColor: Colors.white,
                              shape: const CircleBorder(),
                              elevation: 3,
                              highlightElevation: 1,
                              hoverElevation: 5,
                              child: const Icon(Icons.add_rounded, size: 27),
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
                                    onNavigate: _navigate,
                                    onSpaceChanged: _changeSpace,
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
    required this.displayBrand,
    required this.onSpaceChanged,
    required this.onSearch,
  });

  final String? space;
  final bool displayBrand;
  final ValueChanged<String?> onSpaceChanged;
  final VoidCallback onSearch;

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
          _ModeControl(mode: space, onModeChanged: onSpaceChanged),
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
    required this.onModeChanged,
    this.showCurrentMode = true,
  });

  final String? mode;
  final ValueChanged<String?> onModeChanged;
  final bool showCurrentMode;

  @override
  Widget build(BuildContext context) {
    final current = mode;
    final foreground = current == null ? muted : spaceColor(current);
    return MenuAnchor(
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.expand_more_rounded, size: 17),
        iconAlignment: IconAlignment.end,
        label: Text(
          showCurrentMode && current != null ? spaceName(current) : 'Mode',
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
        for (final mode in spaceColors.keys)
          MenuItemButton(
            onPressed: () => onModeChanged(mode),
            leadingIcon: Icon(Icons.circle, color: spaceColor(mode), size: 8),
            trailingIcon: current == mode
                ? const Icon(Icons.check, size: 18)
                : null,
            child: Text(spaceName(mode)),
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
    required this.onNavigate,
    required this.onSpaceChanged,
  });

  final _Destination destination;
  final bool compact;
  final String? space;
  final ValueChanged<_Destination> onNavigate;
  final ValueChanged<String?> onSpaceChanged;

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
                'Spaces',
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
          for (final category in spaceColors.keys)
            _SidebarButton(
              label: spaceName(category),
              icon: Icons.circle,
              color: Color.lerp(spaceColor(category), sidebarText, .43)!,
              selected: space == category,
              compact: compact,
              onTap: () => onSpaceChanged(category),
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
  });

  final Object record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onClose;

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
        (Icons.circle_outlined, spaceName(item.category)),
      ],
      TaskItem() => [
        (Icons.check_box_outlined, item.done ? 'Completed' : 'Open'),
        if (item.date != null) (Icons.calendar_today_outlined, day(item.date!)),
        (Icons.circle_outlined, spaceName(item.category)),
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
            if (item is NoteItem && item.body.trim().isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 14),
              SelectableText(
                item.body,
                style: const TextStyle(height: 1.6, fontSize: 14),
              ),
            ],
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
              ],
            ),
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
