import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sync_credentials.dart';

const _maximumMarkerBytes = 100;

Future<Directory> _syncDirectory(String? databasePath) async =>
    databasePath == null
    ? Directory.fromUri(
        (await getApplicationSupportDirectory()).uri.resolve('easy/sync/'),
      )
    : File(databasePath).absolute.parent;

Future<File> _marker(String? databasePath) async => File.fromUri(
  (await _syncDirectory(databasePath)).uri.resolve('installation.json'),
);

Future<bool> _fileExists(File file, String invalid) async =>
    switch (await FileSystemEntity.type(file.path, followLinks: false)) {
      FileSystemEntityType.file => true,
      FileSystemEntityType.notFound => false,
      _ => throw SyncVaultException(invalid),
    };

/// Reads the authoritative marker each time. Linux preferences can cache
/// their contents for the life of a process.
Future<String?> readSyncInstallation(String? databasePath) async {
  try {
    final marker = await _marker(databasePath);
    if (!await _fileExists(marker, 'Saved sync configuration is invalid.')) {
      return null;
    }
    final file = await marker.open();
    try {
      final bytes = await file.read(_maximumMarkerBytes + 1);
      if (bytes.length > _maximumMarkerBytes) {
        throw const FormatException('Oversize sync configuration.');
      }
      return utf8.decode(bytes);
    } finally {
      await file.close();
    }
  } on FormatException {
    throw const SyncVaultException('Saved sync configuration is invalid.');
  } on FileSystemException {
    throw const SyncVaultException(
      'Saved sync configuration could not be opened.',
    );
  }
}

/// Called with the installation lock held. The flushed marker is published
/// atomically, so readers always see a complete committed value.
Future<void> writeSyncInstallation(String? databasePath, String value) async {
  if (value.length > _maximumMarkerBytes) {
    throw const SyncVaultException('Saved sync configuration is invalid.');
  }
  try {
    final marker = await _marker(databasePath);
    await _fileExists(marker, 'Saved sync configuration is invalid.');
    final stage = await marker.parent.createTemp('.installation-');
    try {
      final prepared = File.fromUri(stage.uri.resolve('ready'));
      await prepared.writeAsString(value, flush: true);
      await prepared.rename(marker.path);
    } finally {
      await stage.delete(recursive: true);
    }
  } on FileSystemException {
    throw const SyncVaultException('Sync setup could not be saved.');
  }
}

/// Keeps setup atomic across native processes sharing a device profile.
/// The caller obtains the passphrase before entering this scope.
Future<T> lockSyncInstallation<T>(
  String? databasePath,
  Future<T> Function() install,
) async {
  final RandomAccessFile file;
  try {
    final directory = await _syncDirectory(databasePath);
    await directory.create(recursive: true);
    final lock = File.fromUri(directory.uri.resolve('installation.lock'));
    await _fileExists(lock, 'The sync setup lock is invalid.');
    file = await lock.open(mode: FileMode.append);
  } on FileSystemException {
    throw const SyncVaultException('The sync setup lock could not be opened.');
  }
  try {
    try {
      await file.lock(FileLock.blockingExclusive);
    } on FileSystemException {
      throw const SyncVaultException('The sync setup could not be locked.');
    }
    return await install();
  } finally {
    await file.close();
  }
}
