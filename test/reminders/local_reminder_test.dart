import 'dart:convert';

import 'package:easy/reminders/local_reminder.dart';
import 'package:easy/reminders/local_reminder_backend.dart';
import 'package:easy/task_model.dart';
import 'package:easy/tasks/recurring_task.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 24, 9);
  const enabled = LocalReminderSettings(enabled: true);

  test('reconcile schedules, replaces and cancels a stable request', () async {
    final backend = MemoryReminderBackend();
    final controller = LocalReminderController(
      backend: backend,
      clock: () => now,
    );
    final item = _item('secret-subject', now.add(const Duration(hours: 2)));
    final first = await controller.reconcile(
      settings: enabled,
      reminders: [item],
    );
    expect(first.scheduled, 1);
    expect(item.id, isNot(contains('secret-subject')));
    expect(backend.requests[item.id]!.title, 'Easy');
    expect(backend.requests[item.id]!.body, 'Task reminder');
    final unchanged = await controller.reconcile(
      settings: enabled,
      reminders: [item, item],
    );
    expect(unchanged.scheduled, 0);
    final edited = _item('secret-subject', now.add(const Duration(hours: 4)));
    final result = await controller.reconcile(
      settings: const LocalReminderSettings(
        enabled: true,
        showRecordTitles: true,
      ),
      reminders: [edited],
    );
    expect(edited.id, item.id);
    expect(result.scheduled, 1);
    expect(result.canceled, 0);
    expect(backend.requests.singleRequest.at, edited.at);
    expect(backend.requests.singleRequest.title, 'Private title');
    final removed = await controller.reconcile(
      settings: enabled,
      reminders: [],
    );
    expect(removed.canceled, 1);
    expect(backend.requests, isEmpty);
  });

  test('startup and permission revocation never request access', () async {
    final backend = MemoryReminderBackend()
      ..capabilities = const LocalReminderCapabilities(
        permission: LocalReminderPermission.notDetermined,
        exactScheduling: false,
        canRequestExactScheduling: true,
      );
    final controller = LocalReminderController(
      backend: backend,
      clock: () => now,
    );
    final reminder = _item('record', now.add(const Duration(minutes: 30)));
    final initial = await controller.reconcile(
      settings: enabled,
      reminders: [reminder],
    );
    expect(initial.pending, 0);
    expect(backend.permissionPrompts, 0);
    expect(backend.exactPrompts, 0);

    backend.capabilities = MemoryReminderBackend.granted;
    await controller.reconcile(settings: enabled, reminders: [reminder]);
    expect(backend.requests, hasLength(1));
    backend.capabilities = const LocalReminderCapabilities(
      permission: LocalReminderPermission.granted,
      exactScheduling: false,
      canRequestExactScheduling: true,
    );
    final revoked = await controller.reconcile(
      settings: enabled,
      reminders: [reminder],
    );
    expect(revoked.canceled, 1);
    expect(backend.requests, isEmpty);
    expect(backend.exactPrompts, 0);
  });

  test(
    'a retained Android request is rearmed when its platform token is gone',
    () async {
      final backend = MemoryReminderBackend();
      final reminder = _item('retained', now.add(const Duration(minutes: 5)));
      final request = reminder.request(showRecordTitle: false);
      backend.requests[reminder.id] = LocalReminderRequest.fromJson({
        ...request.toJson(),
        'armed': false,
      });
      final controller = LocalReminderController(
        backend: backend,
        clock: () => now,
      );
      final result = await controller.reconcile(
        settings: enabled,
        reminders: [reminder],
      );
      expect(result.scheduled, 1);
      expect(backend.requests.singleRequest, request);
    },
  );

  test(
    'the earliest reminders fit within both the horizon and pending cap',
    () async {
      final backend = MemoryReminderBackend();
      final controller = LocalReminderController(
        backend: backend,
        clock: () => now,
        pendingLimit: 2,
        horizon: const Duration(days: 2),
      );
      final soon = _item('soon', now.add(const Duration(minutes: 1)));
      final later = _item('later', now.add(const Duration(hours: 3)));
      final overflow = _item('defer', now.add(const Duration(hours: 8)));
      final result = await controller.reconcile(
        settings: enabled,
        reminders: [
          _item('expired', now.subtract(const Duration(minutes: 1))),
          _item('future', now.add(const Duration(days: 3))),
          overflow,
          later,
          soon,
        ],
      );
      expect(result.pending, 2);
      expect(result.deferred, 1);
      expect(backend.requests.keys, [soon.id, later.id]);
      final disabled = await controller.reconcile(
        settings: const LocalReminderSettings(),
        reminders: [soon, later],
      );
      expect(disabled.pending, 0);
      expect(disabled.canceled, 2);
    },
  );

  test(
    'serialized snapshots recover after a partial platform failure',
    () async {
      final backend = MemoryReminderBackend()..failNextSchedule = true;
      final controller = LocalReminderController(
        backend: backend,
        clock: () => now,
      );
      final first = _item('one', now.add(const Duration(hours: 2)));
      final changed = _item('one', now.add(const Duration(hours: 4)));
      final rejected = controller.reconcile(
        settings: enabled,
        reminders: [first],
      );
      final next = controller.reconcile(
        settings: enabled,
        reminders: [changed],
      );
      await expectLater(rejected, throwsStateError);
      expect((await next).scheduled, 1);
      expect(backend.requests.singleRequest.at, changed.at);
    },
  );

  test(
    'record reminders are either absolute or anchored to the current start',
    () {
      final target = ReminderTarget(
        kind: ReminderTargetKind.plannedBlock,
        recordId: 'block',
      );
      final preference = RecordReminderPreference.relative(
        target: target,
        minutesBeforeStart: 30,
      );
      final reopened = RecordReminderPreference.fromJson(
        jsonDecode(jsonEncode(preference.toJson())) as Map<String, Object?>,
      );
      final scheduled = reopened.resolve(
        start: now.add(const Duration(hours: 2)),
      );
      final updated = reopened.resolve(
        start: now.add(const Duration(hours: 3)),
      );
      expect(scheduled?.id, target.notificationId);
      expect(updated?.id, target.notificationId);
      expect(scheduled?.at, now.add(const Duration(minutes: 90)));
      expect(updated?.at, now.add(const Duration(minutes: 150)));
      expect(reopened.resolve(active: false), isNull);
      expect(reopened.resolve(), isNull);

      final absolute = RecordReminderPreference.absolute(
        target: target,
        at: now,
      );
      expect(
        absolute.resolve(start: now.add(const Duration(hours: 10)))?.at,
        now,
      );
      expect(
        () => RecordReminderPreference.relative(
          target: target,
          minutesBeforeStart: -1,
        ),
        throwsArgumentError,
      );
    },
  );

  test('recurrence reminders follow wall clocks, skip DST gaps and ignore completed rows', () {
    final series = RecurringTaskSeries(
      id: 'wake-up',
      task: const TaskItem(id: 'task', title: 'Morning', category: 'personal'),
      startDate: DateTime(2026, 3, 27),
      timeZoneId: 'Europe/London',
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.daily,
        count: 5,
      ),
      reminder: TaskReminderPreference(minuteOfDay: 90),
    );
    final start = DateTime.utc(2026, 3, 27);
    final original = remindersForRecurringTasks([series], now: start);
    expect(original.map((request) => request.at), [
      DateTime.utc(2026, 3, 27, 1, 30),
      DateTime.utc(2026, 3, 28, 1, 30),
      DateTime.utc(2026, 3, 30, 0, 30),
      DateTime.utc(2026, 3, 31, 0, 30),
    ]);
    final rows = series.occurrences(
      windowStart: start,
      windowEnd: DateTime.utc(2026, 4, 2),
    );
    final complete = series.complete(rows[1], at: start);
    final skipped = complete.skip(
      complete.occurrences(
        windowStart: start,
        windowEnd: DateTime.utc(2026, 4, 2),
      )[3],
      scope: InternalOccurrenceScope.one,
    );
    final active = remindersForRecurringTasks([skipped], now: start);
    expect(active.map((request) => request.id), [
      original[0].id,
      original[3].id,
    ]);
  });

  test('a notification can precede its repeat occurrence by a year', () {
    final first = DateTime.utc(2027, 11, 24);
    final series = RecurringTaskSeries(
      id: 'annual',
      task: const TaskItem(id: 'annual', title: 'Annual', category: 'personal'),
      startDate: first,
      timeZoneId: 'Etc/UTC',
      rule: InternalRecurrenceRule(
        frequency: InternalRecurrenceFrequency.yearly,
      ),
      reminder: TaskReminderPreference(minuteOfDay: 601, dayOffset: -365),
    );
    expect(
      remindersForRecurringTasks([series], now: now).single.at,
      DateTime.utc(2026, 11, 24, 10, 1),
    );
  });

  test('civil clock resolves both fall folds and refuses a spring gap', () {
    const zone = 'Europe/London';
    final fold = DateTime.utc(2026, 10, 25, 1, 30);
    expect(
      resolveReminderClock(fold, timeZoneId: zone),
      DateTime.utc(2026, 10, 25, 0, 30),
    );
    expect(
      resolveReminderClock(fold, timeZoneId: zone, laterFold: true),
      DateTime.utc(2026, 10, 25, 1, 30),
    );
    expect(
      resolveReminderClock(DateTime.utc(2026, 3, 29, 1, 30), timeZoneId: zone),
      isNull,
    );
  });

  test(
    'method channel only prompts for the dedicated permission call',
    () async {
      const channel = MethodChannel(PlatformLocalReminderBackend.channelName);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'pending') return const <Object?>[];
        if (call.method == 'authorization' ||
            call.method == 'requestNotifications') {
          return {'permission': 'granted', 'exactScheduling': true};
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const backend = PlatformLocalReminderBackend(
        platform: TargetPlatform.android,
      );
      final controller = LocalReminderController(
        backend: backend,
        clock: () => now,
      );
      final item = _item('record', now.add(const Duration(hours: 1)));
      await controller.reconcile(settings: enabled, reminders: [item]);
      expect(calls.map((entry) => entry.method), [
        'authorization',
        'pending',
        'schedule',
      ]);
      final payload = calls.last.arguments as Map;
      expect(payload['atMilliseconds'], item.at.millisecondsSinceEpoch);
      expect(payload['title'], 'Easy');
      await backend.requestNotificationPermission();
      expect(calls.last.method, 'requestNotifications');
      await backend.cancel(['another-plugin-id']);
      expect(calls.last.method, 'requestNotifications');
    },
  );
}

LocalReminder _item(String id, DateTime at) => LocalReminder(
  target: ReminderTarget(kind: ReminderTargetKind.task, recordId: id),
  at: at,
  recordTitle: 'Private title',
);

extension on Map<String, LocalReminderRequest> {
  LocalReminderRequest get singleRequest => values.single;
}

class MemoryReminderBackend implements LocalReminderBackend {
  static const granted = LocalReminderCapabilities(
    permission: LocalReminderPermission.granted,
    exactScheduling: true,
  );
  LocalReminderCapabilities capabilities = granted;
  final requests = <String, LocalReminderRequest>{};
  bool failNextSchedule = false;
  int permissionPrompts = 0;
  int exactPrompts = 0;

  @override
  Future<LocalReminderCapabilities> authorization() async => capabilities;

  @override
  Future<LocalReminderCapabilities> requestNotificationPermission() async {
    permissionPrompts++;
    capabilities = granted;
    return capabilities;
  }

  @override
  Future<void> requestExactScheduling() async {
    exactPrompts++;
  }

  @override
  Future<List<LocalReminderRequest>> pending() async =>
      requests.values.toList();

  @override
  Future<void> schedule(LocalReminderRequest request) async {
    if (failNextSchedule) {
      failNextSchedule = false;
      throw StateError('Simulated write failure');
    }
    requests[request.id] = request;
  }

  @override
  Future<void> cancel(Iterable<String> ids) async =>
      ids.forEach(requests.remove);
}
