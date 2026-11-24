import 'dart:convert';
import 'dart:typed_data';

import 'package:easy/storage/encrypted_backup.dart';
import 'package:easy/storage/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _password = 'Synthetic Example 📓';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encrypted backup uses a fresh salt and nonce for each write', () async {
    final payload = _bytes('Local schedule, café at 19:30. 📓');
    final encrypted = await Future.wait([
      encryptWorkspaceBackup(payload, _password),
      encryptWorkspaceBackup(payload, _password),
    ]);
    expect(isEncryptedWorkspaceBackup(payload), isFalse);
    expect(isEncryptedWorkspaceBackup(encrypted.first), isTrue);
    expect(encrypted.first, isNot(encrypted.last));
    expect(latin1.decode(encrypted.first), isNot(contains('Local schedule')));
    expect(await decryptWorkspaceBackup(encrypted.first, _password), payload);
    expect(await decryptWorkspaceBackup(encrypted.last, _password), payload);
  });

  test('opens an independent Argon2id and AES-GCM reference fixture', () async {
    // Generated with Python cryptography. Salt is bytes 0..15, nonce is
    // bytes 16..27, and AAD is magic + version + salt + nonce.
    final bytes = base64Decode(
      'RUFTWUJLUAABAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaG529gXFoySc3Z7qX'
      'AA0ZtxA9G421uFa1cBz/b21seEKgsvvmzgey/i+sqGFHf8O6pQ==',
    );
    expect(
      utf8.decode(
        await decryptWorkspaceBackup(bytes, 'Synthetic cross platform fixture'),
      ),
      'Independent AES-GCM test fixture',
    );
  });

  test(
    'wrong passwords, edited headers and damaged tags fail closed',
    () async {
      final original = await encryptWorkspaceBackup(
        _bytes('Synthetic data protected by authentication.'),
        _password,
      );
      final authenticationFailure = throwsA(
        isA<WorkspaceBackupAuthenticationException>(),
      );
      await expectLater(
        decryptWorkspaceBackup(original, 'wrong password'),
        authenticationFailure,
      );
      for (final vector in [9, 25, 37, original.length - 1]) {
        final damaged = Uint8List.fromList(original);
        damaged[vector] ^= 1;
        await expectLater(
          decryptWorkspaceBackup(damaged, _password),
          authenticationFailure,
        );
      }
      expect(
        utf8.decode(await decryptWorkspaceBackup(original, _password)),
        'Synthetic data protected by authentication.',
      );
    },
  );

  test(
    'malformed envelopes and unsupported versions fail before decryption',
    () async {
      final data = await encryptWorkspaceBackup(_bytes('fixture'), _password);
      final newer = Uint8List.fromList(data)..[8] = 0x7f;
      expect(isEncryptedWorkspaceBackup(newer), isTrue);
      await expectLater(
        decryptWorkspaceBackup(newer, _password),
        throwsFormatException,
      );
      await expectLater(
        decryptWorkspaceBackup(Uint8List.sublistView(data, 0, 13), _password),
        throwsFormatException,
      );
      await expectLater(
        decryptWorkspaceBackup(_bytes('plain backup'), _password),
        throwsFormatException,
      );
      await expectLater(
        encryptWorkspaceBackup(_bytes('fixture'), ''),
        throwsArgumentError,
      );
      await expectLater(
        decryptWorkspaceBackup(data, 'é' * 513),
        throwsArgumentError,
      );
    },
  );

  test(
    'encrypted store backup still requires preview and fresh revision',
    () async {
      final previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
      const empty = '{"events":[],"notes":[],"tasks":[]}';
      const changed = '{"events":[],"notes":[],"tasks":[],"futureField":true}';
      final store = await openPreferenceWorkspaceStore(
        preferences: SharedPreferencesAsync(),
        readLegacy: () async => WorkspaceSnapshot(
          workspaceJson: empty,
          gymSessionJson: const [],
          workoutPlanJson: const [],
        ),
      );
      addTearDown(store.close);
      final data = await store.createEncryptedBackup(_password);
      expect(isEncryptedWorkspaceBackup(data), isTrue);
      await store.save(const WorkspaceMutation.workspace(changed));
      final preview = await store.previewEncryptedBackup(data, _password);
      expect((await store.read()).snapshot.workspaceJson, changed);
      expect(preview.snapshot.workspaceJson, empty);
      await expectLater(
        store.restoreBackup(preview, expectedRevision: 1),
        throwsA(isA<WorkspaceRevisionConflict>()),
      );
      expect(
        (await store.restoreBackup(preview, expectedRevision: 2)).revision,
        3,
      );

      final encryptedInvalid = await encryptWorkspaceBackup(
        _bytes('invalid'),
        _password,
      );
      await expectLater(
        store.previewEncryptedBackup(encryptedInvalid, _password),
        throwsFormatException,
      );
      expect((await store.read()).revision, 3);
    },
  );
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
