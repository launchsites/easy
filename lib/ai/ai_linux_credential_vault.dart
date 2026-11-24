import 'dart:async';

import 'package:flutter/services.dart';

import 'ai_runtime_settings.dart';

final _reference = RegExp(r'easy\.ai\.[a-f0-9]{64}');

/// Linux Secret Service operations using the runner's async libsecret bridge.
final class AiLinuxCredentialVault implements AiWritableCredentialVault {
  const AiLinuxCredentialVault({
    this.channel = const MethodChannel('app.launchsites.easy/ai_credentials'),
  });

  final MethodChannel channel;

  @override
  bool get persistent => true;

  Future<bool> available() async {
    try {
      return await channel
              .invokeMethod<bool>('available')
              .timeout(const Duration(seconds: 5)) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<String?> read(String reference) => channel.invokeMethod<String>(
    'read',
    {'reference': _validReference(reference)},
  );

  @override
  Future<void> write(String reference, String secret) async {
    if (!validAiKey(secret)) {
      throw const FormatException('Invalid provider credential.');
    }
    await channel.invokeMethod<void>('write', {
      'reference': _validReference(reference),
      'secret': secret,
    });
    if (await read(reference) != secret) {
      throw StateError(
        'The Linux credential service did not confirm saving the key.',
      );
    }
  }

  @override
  Future<void> delete(String reference) => channel.invokeMethod<void>(
    'delete',
    {'reference': _validReference(reference)},
  );
}

String _validReference(String reference) {
  if (_reference.matchAsPrefix(reference)?.end != reference.length) {
    throw const FormatException('Invalid provider credential reference.');
  }
  return reference;
}
