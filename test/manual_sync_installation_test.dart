import 'dart:io';

import 'package:easy/sync/manual_sync_installation.dart';
import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  const preferenceKey = 'easy.manualSync.installation.v1';
  late SharedPreferencesAsync prefs;
  late Directory temp;
  late _Vault vault;

  setUp(() async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    temp = await Directory.systemTemp.createTemp(
      'easy-manual-sync-installation',
    );
    addTearDown(() => temp.delete(recursive: true));
    prefs = SharedPreferencesAsync();
    vault = _Vault();
  });

  ManualSyncInstallation installation() => ManualSyncInstallation(
    preferences: prefs,
    credentials: SyncDeviceCredentials(vault),
    databasePath: '${temp.path}/journal.sqlite3',
  );

  test(
    'opening Settings has no effects until explicit enable, then reuses keys',
    () async {
      final first = installation();
      expect(await first.openConfigured(), isNull);
      expect(vault.reads, 0);
      expect(await prefs.getString(preferenceKey), isNull);
      expect(await temp.list().isEmpty, isTrue);

      final id = SyncWorkspaceId.generate();
      final created = await first.enable(id);
      expect(created.workspaceId, id);
      final device = created.device.fingerprint;
      expect(await first.openConfigured(), same(created));
      await first.close();
      expect(vault.values, hasLength(2));
      final config = (await prefs.getString(preferenceKey))!;
      for (final secret in vault.values.values) {
        expect(config, isNot(contains(secret)));
      }

      final reopened = installation();
      final session = (await reopened.openConfigured())!;
      expect(session.device.fingerprint, device);
      expect(session.workspaceId, id);
      await expectLater(
        reopened.enable(SyncWorkspaceId.generate()),
        throwsA(isA<SyncPairedWorkspaceException>()),
      );
      expect(vault.values, hasLength(2));
      await reopened.close();
    },
  );

  test(
    'an interrupted setup resumes only the same explicit workspace',
    () async {
      final first = installation();
      final id = SyncWorkspaceId.generate();
      vault.allowJournal = false;
      await expectLater(first.enable(id), throwsA(isA<SyncVaultException>()));
      expect(await prefs.getString(preferenceKey), contains(id.value));
      expect(vault.values, hasLength(1));
      await first.close();

      vault.allowJournal = true;
      final resumed = installation();
      expect(await resumed.openConfigured(), isNull);
      await expectLater(
        resumed.enable(SyncWorkspaceId.generate()),
        throwsA(isA<SyncPairedWorkspaceException>()),
      );
      expect((await resumed.enable(null)).workspaceId, id);
      expect(vault.values, hasLength(2));
      await resumed.close();
    },
  );

  test(
    'failed vault access or malformed configuration creates no identity',
    () async {
      final first = installation();
      vault.allowAccess = false;
      await expectLater(first.enable(null), throwsA(isA<SyncVaultException>()));
      expect(await prefs.getString(preferenceKey), isNull);
      expect(vault.values, isEmpty);
      await first.close();

      vault.allowAccess = true;
      await prefs.setString(preferenceKey, '[1,"broken",true]');
      final second = installation();
      await expectLater(
        second.openConfigured(),
        throwsA(isA<SyncVaultException>()),
      );
      await expectLater(
        second.enable(null),
        throwsA(isA<SyncVaultException>()),
      );
      expect(vault.values, isEmpty);
      expect(await temp.list().isEmpty, isTrue);
      await second.close();
    },
  );

  test('an unopenable configured journal never replaces its keys', () async {
    final first = installation();
    await first.enable(null);
    await first.close();
    final savedCredentials = Map.of(vault.values);
    await File('${temp.path}/journal.sqlite3').delete();

    final reopened = installation();
    await expectLater(
      reopened.openConfigured(),
      throwsA(isA<SyncJournalException>()),
    );
    await expectLater(
      reopened.enable(null),
      throwsA(isA<SyncJournalException>()),
    );
    expect(vault.values, savedCredentials);
    expect(await File('${temp.path}/journal.sqlite3').exists(), isFalse);
    await reopened.close();
  });
}

final class _Vault implements SyncSecretVault {
  final values = <String, String>{};
  int reads = 0;
  bool allowAccess = true;
  bool allowJournal = true;

  @override
  Future<String?> read(String reference) async {
    reads++;
    if (!allowAccess) throw StateError('Vault is locked');
    return values[reference];
  }

  @override
  Future<void> write(String reference, String secret) async {
    if (!allowJournal && reference.contains('.journal.')) {
      throw StateError('Interrupted setup fixture');
    }
    values[reference] = secret;
  }

  @override
  Future<void> delete(String reference) async {
    values.remove(reference);
  }
}
