import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_reminder.dart';

enum LocalReminderPermission { unavailable, notDetermined, denied, granted }

class LocalReminderCapabilities {
  const LocalReminderCapabilities({
    required this.permission,
    required this.exactScheduling,
    this.canRequestExactScheduling = false,
  });

  static const unavailable = LocalReminderCapabilities(
    permission: LocalReminderPermission.unavailable,
    exactScheduling: false,
  );

  factory LocalReminderCapabilities.fromJson(Map<Object?, Object?> json) =>
      LocalReminderCapabilities(
        permission: LocalReminderPermission.values.byName(
          json['permission'] as String,
        ),
        exactScheduling: json['exactScheduling'] as bool,
        canRequestExactScheduling:
            json['canRequestExactScheduling'] as bool? ?? false,
      );

  final LocalReminderPermission permission;
  final bool exactScheduling;
  final bool canRequestExactScheduling;

  bool get supported => permission != LocalReminderPermission.unavailable;
  bool get canSchedule =>
      permission == LocalReminderPermission.granted && exactScheduling;
}

abstract interface class LocalReminderBackend {
  Future<LocalReminderCapabilities> authorization();
  Future<LocalReminderCapabilities> requestNotificationPermission();
  Future<void> requestExactScheduling();
  Future<List<LocalReminderRequest>> pending();
  Future<void> schedule(LocalReminderRequest request);
  Future<void> cancel(Iterable<String> ids);
}

class PlatformLocalReminderBackend implements LocalReminderBackend {
  const PlatformLocalReminderBackend({
    this.channel = const MethodChannel(channelName),
    this.platform,
  });

  static const channelName = 'app.launchsites.easy/local_reminders';
  final MethodChannel channel;

  /// Override for host-side contract tests.
  final TargetPlatform? platform;

  bool get _supported =>
      !kIsWeb &&
      const {
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.android,
      }.contains(platform ?? defaultTargetPlatform);

  @override
  Future<LocalReminderCapabilities> authorization() =>
      _capabilities('authorization');

  @override
  Future<LocalReminderCapabilities> requestNotificationPermission() =>
      _capabilities('requestNotifications');

  Future<LocalReminderCapabilities> _capabilities(String method) async {
    if (!_supported) return LocalReminderCapabilities.unavailable;
    try {
      final result = await channel.invokeMapMethod<Object?, Object?>(method);
      return result == null
          ? LocalReminderCapabilities.unavailable
          : LocalReminderCapabilities.fromJson(result);
    } on MissingPluginException {
      return LocalReminderCapabilities.unavailable;
    }
  }

  @override
  Future<void> requestExactScheduling() async {
    if (!_supported) return;
    await channel.invokeMethod<void>('requestExactScheduling');
  }

  @override
  Future<List<LocalReminderRequest>> pending() async {
    if (!_supported) return const [];
    final rows = await channel.invokeListMethod<Object?>('pending');
    return List.unmodifiable([
      for (final value in rows ?? const [])
        LocalReminderRequest.fromJson(Map<String, Object?>.from(value as Map)),
    ]);
  }

  @override
  Future<void> schedule(LocalReminderRequest request) async {
    if (!_supported) {
      throw StateError('Local reminders are unavailable on this device.');
    }
    await channel.invokeMethod<void>('schedule', request.toJson());
  }

  @override
  Future<void> cancel(Iterable<String> ids) async {
    final valid = ids.where(isLocalReminderId).toSet().toList();
    if (!_supported || valid.isEmpty) return;
    await channel.invokeMethod<void>('cancel', valid);
  }
}

/// Stores the delivery opt-in outside the workspace and its portable backups.
class LocalReminderSettingsStore {
  const LocalReminderSettingsStore({
    this.storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'easy_local_reminders_v1',
        resetOnError: false,
      ),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
      ),
      mOptions: MacOsOptions(
        accessibility: KeychainAccessibility.unlocked_this_device,
        usesDataProtectionKeychain: false,
      ),
    ),
  });

  static const _key = 'easy.local-reminder-settings.v1';
  final FlutterSecureStorage storage;

  Future<LocalReminderSettings> load() async {
    final value = await storage.read(key: _key);
    if (value == null) return const LocalReminderSettings();
    return LocalReminderSettings.fromJson(
      jsonDecode(value) as Map<String, Object?>,
    );
  }

  Future<void> save(LocalReminderSettings settings) async {
    if (!settings.enabled && !settings.showRecordTitles) {
      await storage.delete(key: _key);
    } else {
      await storage.write(key: _key, value: jsonEncode(settings.toJson()));
    }
  }
}

class LocalReminderReconcileResult {
  const LocalReminderReconcileResult({
    required this.capabilities,
    required this.pending,
    required this.scheduled,
    required this.canceled,
    required this.deferred,
  });

  final LocalReminderCapabilities capabilities;
  final int pending;
  final int scheduled;
  final int canceled;
  final int deferred;
}

class LocalReminderController {
  LocalReminderController({
    required this.backend,
    DateTime Function()? clock,
    this.horizon = const Duration(days: localReminderHorizonDays),
    this.pendingLimit = localReminderPendingLimit,
  }) : clock = clock ?? DateTime.now {
    if (horizon <= Duration.zero ||
        horizon > const Duration(days: localReminderHorizonDays) ||
        pendingLimit < 1 ||
        pendingLimit > localReminderPendingLimit) {
      throw ArgumentError('Invalid local reminder scheduling bounds.');
    }
  }

  final LocalReminderBackend backend;
  final DateTime Function() clock;
  final Duration horizon;
  final int pendingLimit;
  Future<void> _queue = Future.value();

  /// Applies a complete current snapshot. Call after relevant local changes and
  /// foreground resume. Background delivery is owned by the operating system.
  Future<LocalReminderReconcileResult> reconcile({
    required LocalReminderSettings settings,
    required Iterable<LocalReminder> reminders,
  }) {
    final snapshot = List<LocalReminder>.of(reminders);
    final result = _queue.then((_) => _apply(settings, snapshot));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<LocalReminderReconcileResult> _apply(
    LocalReminderSettings settings,
    List<LocalReminder> reminders,
  ) async {
    final capabilities = await backend.authorization();
    if (!capabilities.supported) {
      return LocalReminderReconcileResult(
        capabilities: capabilities,
        pending: 0,
        scheduled: 0,
        canceled: 0,
        deferred: 0,
      );
    }
    final pending = {
      for (final request in await backend.pending()) request.id: request,
    };
    final now = clock().toUtc();
    final limit = now.add(horizon);
    final desired = <String, LocalReminderRequest>{};
    if (settings.enabled && capabilities.canSchedule) {
      for (final item in reminders) {
        if (!item.at.isAfter(now) || item.at.isAfter(limit)) continue;
        final request = item.request(
          showRecordTitle: settings.showRecordTitles,
        );
        final previous = desired[request.id];
        if (previous != null && previous != request) {
          throw StateError('Two current reminders have the same target.');
        }
        desired[request.id] = request;
      }
    }
    final ordered = desired.values.toList()
      ..sort((a, b) {
        final instant = a.at.compareTo(b.at);
        return instant == 0 ? a.id.compareTo(b.id) : instant;
      });
    final active = {
      for (final request in ordered.take(pendingLimit)) request.id: request,
    };
    final removed = pending.keys
        .where((id) => !active.containsKey(id))
        .toList();
    if (removed.isNotEmpty) await backend.cancel(removed);
    var writes = 0;
    for (final request in active.values) {
      if (pending[request.id] == request) continue;
      await backend.schedule(request);
      writes++;
    }
    return LocalReminderReconcileResult(
      capabilities: capabilities,
      pending: active.length,
      scheduled: writes,
      canceled: removed.length,
      deferred: ordered.length - active.length,
    );
  }
}
