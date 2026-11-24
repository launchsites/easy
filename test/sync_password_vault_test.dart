import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy/sync/manual_sync_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

const _passphrase = 'Synthetic vault passphrase ♦ for local testing';
const _deviceRef = 'easy.sync.v1.device';
const _journalRef = 'easy.sync.v1.journal.example';

void main() {
  late Directory temporary;
  late String path;
  final handles = <SyncPasswordVault>[];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('easy-sync-vault-');
    path = temporary.uri.resolve('credentials.easyvault').toFilePath();
  });

  tearDown(() async {
    await Future.wait(handles.map((vault) => vault.close()));
    handles.clear();
    await temporary.delete(recursive: true);
  });

  Future<SyncPasswordVault> open({String password = _passphrase}) async {
    final vault = await openSyncPasswordVault(
      passphrase: password,
      filePath: path,
    );
    handles.add(vault);
    return vault;
  }

  test('password file persists ciphertext and reopening the right password retains identity', () async {
    final initial = await open();
    expect(File(path).existsSync(), isFalse);
    final credentials = SyncDeviceCredentials(initial);
    final identity = await credentials.createIdentity();
    addTearDown(identity.destroy);
    final seed = await identity.copySeedForSecureStorage();
    final privateText = base64Url.encode(seed);
    seed.fillRange(0, seed.length, 0);
    await initial.close();
    final stored = await File(path).readAsBytes();
    expect(latin1.decode(stored), isNot(contains(privateText)));
    expect(latin1.decode(stored), isNot(contains(_deviceRef)));

    await expectLater(
      open(password: 'Incorrect synthetic passphrase'),
      throwsA(isA<SyncVaultException>()),
    );
    expect(await File(path).readAsBytes(), stored);
    final reopened = SyncDeviceCredentials(await open());
    final retained = (await reopened.loadIdentity())!;
    addTearDown(retained.destroy);
    expect(retained.deviceId, identity.deviceId);
  });

  test('multiple handles serialize encrypted writes without dropping another credential', () async {
    final first = await open();
    final second = await open();
    final bytesA = base64Url.encode(Uint8List.fromList(List.filled(32, 11)));
    final bytesB = base64Url.encode(Uint8List.fromList(List.filled(32, 55)));
    await Future.wait([
      first.write(_deviceRef, bytesA),
      second.write(_journalRef, bytesB),
    ]);
    expect(await second.read(_deviceRef), bytesA);
    expect(await first.read(_journalRef), bytesB);
    await second.delete(_deviceRef);
    expect(await first.read(_deviceRef), isNull);
    expect(await first.read(_journalRef), bytesB);
    await second.close();
    await expectLater(
      second.read(_journalRef),
      throwsA(isA<SyncVaultException>()),
    );
  });

  test('altered, oversized and linked credential files fail closed', () async {
    final vault = await open();
    final value = base64Url.encode(Uint8List.fromList(List.filled(32, 33)));
    await vault.write(_deviceRef, value);
    await vault.close();
    final file = File(path);
    final altered = Uint8List.fromList(await file.readAsBytes())..[43] ^= 1;
    await file.writeAsBytes(altered);
    await expectLater(open(), throwsA(isA<SyncVaultException>()));
    expect(await file.readAsBytes(), altered);
    await file.writeAsBytes(Uint8List(513 * 1024));
    await expectLater(open(), throwsA(isA<SyncVaultException>()));
    final target = await file.rename('$path.target');
    await Link(path).create(target.path);
    await expectLater(open(), throwsA(isA<SyncVaultException>()));
    expect(await target.length(), 513 * 1024);
  });

  test(
    'unlock and open handles preserve a missing credential file for recovery',
    () async {
      Future<SyncPasswordVault> unlock() => openSyncPasswordVault(
        passphrase: _passphrase,
        filePath: path,
        createIfMissing: false,
      );
      await expectLater(unlock(), throwsA(isA<SyncVaultException>()));
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.lock').exists(), isFalse);

      final initial = await open();
      final value = base64Url.encode(Uint8List.fromList(List.filled(32, 85)));
      await initial.write(_deviceRef, value);
      final reopened = await unlock();
      handles.add(reopened);
      final stored = await File(path).rename('$path.saved');
      await expectLater(
        initial.write(_journalRef, value),
        throwsA(isA<SyncVaultException>()),
      );
      await expectLater(
        reopened.read(_deviceRef),
        throwsA(isA<SyncVaultException>()),
      );
      expect(await File(path).exists(), isFalse);

      await stored.rename(path);
      expect(await reopened.read(_deviceRef), value);
      expect(await reopened.read(_journalRef), isNull);
    },
  );
}
