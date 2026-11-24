import 'dart:isolate';

Future<T> runBackupCrypto<T>(Future<T> Function() action) =>
    Isolate.run(action, debugName: 'easy-backup-crypto');
