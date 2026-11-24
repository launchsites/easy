import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:easy/storage/attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';

final _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a'
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAACAAIDASIA'
  'AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEB'
  'AAAAAAAAAAAAAAAAAAAABP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ALYAYb//'
  '2Q==',
);

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+bB6s'
  'AAAAASUVORK5CYII=',
);

void main() {
  late Directory sandbox;
  late Directory root;
  late AttachmentStore store;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easy-attachments-test-');
    root = Directory.fromUri(sandbox.uri.resolve('attachments'));
    store = (await openAttachmentStore(directoryPath: root.path))!;
  });

  tearDown(() async {
    await store.close();
    await sandbox.delete(recursive: true);
  });

  test(
    'identifies and round-trips common photo and audio containers',
    () async {
      final fixtures = [
        (_jpeg, AttachmentKind.photo, AttachmentFormat.jpeg, 'image/jpg'),
        (_png, AttachmentKind.photo, AttachmentFormat.png, 'image/png'),
        (_heic(), AttachmentKind.photo, AttachmentFormat.heic, 'image/heif'),
        (_wave(), AttachmentKind.audio, AttachmentFormat.wav, 'audio/x-wav'),
        (_m4a(), AttachmentKind.audio, AttachmentFormat.m4a, 'audio/x-m4a'),
      ];
      for (final (bytes, kind, format, mime) in fixtures) {
        final ref = await store.putBytes(
          bytes,
          kind: kind,
          declaredMimeType: mime,
        );
        expect(ref.id, sha256.convert(bytes).toString());
        expect(ref.format, format);
        expect(ref.byteLength, bytes.length);
        expect(AttachmentRef.fromJson(ref.toJson()).toJson(), ref.toJson());
        final restored = await store.read(ref.id);
        expect(restored.bytes, bytes);
        expect(restored.ref.toJson(), ref.toJson());
      }
    },
  );

  test('concurrent duplicates share one complete verified payload', () async {
    final parts = [_png.sublist(0, 10), _png.sublist(10)];
    final results = await Future.wait([
      store.putBytes(_png, kind: AttachmentKind.photo),
      store.putStream(
        Stream.fromIterable(parts),
        kind: AttachmentKind.photo,
        expectedLength: _png.length,
      ),
      store.putBytes(_png, kind: AttachmentKind.photo),
    ]);
    expect(results.map((result) => result.id).toSet(), hasLength(1));
    expect(await root.list().toList(), hasLength(1));
    await store.close();
    store = (await openAttachmentStore(directoryPath: root.path))!;
    expect((await store.read(results.first.id)).bytes, _png);
  });

  test(
    'bad media, misleading types and image bombs leave no residue',
    () async {
      final pngBomb = Uint8List.fromList(_png);
      ByteData.sublistView(pngBomb).setUint32(16, 100000000);
      final badBmff = _m4a()..[0] = 0x7f;

      for (final (bytes, kind) in [
        (_png, AttachmentKind.audio),
        (pngBomb, AttachmentKind.photo),
        (
          Uint8List.sublistView(_jpeg, 0, _jpeg.length - 2),
          AttachmentKind.photo,
        ),
        (Uint8List.sublistView(_wave(), 0, 14), AttachmentKind.audio),
        (_m4a(handler: 'vide'), AttachmentKind.audio),
        (badBmff, AttachmentKind.audio),
        (_heic(brand: 'avif'), AttachmentKind.photo),
      ]) {
        await expectLater(
          store.putBytes(bytes, kind: kind),
          throwsFormatException,
        );
      }
      await expectLater(
        store.putBytes(
          _png,
          kind: AttachmentKind.photo,
          declaredMimeType: 'image/jpeg',
        ),
        throwsFormatException,
      );
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'stream validation is bounded and failed input is never published',
    () async {
      await store.close();
      store = (await openAttachmentStore(
        directoryPath: root.path,
        limits: const AttachmentLimits(maxPhotoBytes: 16, maxAudioBytes: 32),
      ))!;
      await expectLater(
        store.putStream(
          Stream.fromIterable([_png.sublist(0, 9), _png.sublist(9)]),
          kind: AttachmentKind.photo,
        ),
        throwsFormatException,
      );
      await expectLater(
        store.putStream(
          Stream.fromIterable([
            [-1, 300],
          ]),
          kind: AttachmentKind.photo,
        ),
        throwsFormatException,
      );
      await expectLater(
        store.putStream(
          Stream.value([0]),
          kind: AttachmentKind.photo,
          expectedLength: 2,
        ),
        throwsFormatException,
      );
      await expectLater(
        store.putStream(
          Stream<List<int>>.error(StateError('synthetic stream failure')),
          kind: AttachmentKind.audio,
        ),
        throwsStateError,
      );
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'rejects invalid identifiers and app-managed location symlinks',
    () async {
      final outside = Directory.fromUri(sandbox.uri.resolve('outside'));
      await outside.create();
      await File.fromUri(outside.uri.resolve('payload')).writeAsBytes(_png);
      final digest = sha256.convert(_png).toString();

      for (final invalid in [
        '../outside',
        '/outside/fixture',
        digest.toUpperCase(),
        '$digest\n',
      ]) {
        await expectLater(store.read(invalid), throwsFormatException);
      }
      final link = Link.fromUri(root.uri.resolve(digest));
      await link.create(outside.path);
      await expectLater(
        store.read(digest),
        throwsA(isA<AttachmentStoreException>()),
      );
      await expectLater(
        store.putBytes(_png, kind: AttachmentKind.photo),
        throwsA(isA<AttachmentStoreException>()),
      );
      await link.delete();
      final inner = await Directory.fromUri(root.uri.resolve(digest)).create();
      await Link.fromUri(inner.uri.resolve('payload'))
          .create(File.fromUri(outside.uri.resolve('payload')).path);
      await expectLater(
        store.read(digest),
        throwsA(isA<AttachmentStoreException>()),
      );
    },
  );

  test(
    'corruption fails verification and duplicate import preserves evidence',
    () async {
      final bytes = _wave();
      final ref = await store.putBytes(bytes, kind: AttachmentKind.audio);
      final corrupted = Uint8List.fromList(bytes)..[44] ^= 1;
      final file = File.fromUri(root.uri.resolve('${ref.id}/payload'));
      await file.writeAsBytes(corrupted);
      await expectLater(
        store.read(ref.id),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.message,
            'message',
            contains('integrity'),
          ),
        ),
      );
      await expectLater(
        store.putBytes(bytes, kind: AttachmentKind.audio),
        throwsA(isA<AttachmentStoreException>()),
      );
      expect(await file.readAsBytes(), corrupted);
      expect(await root.list().toList(), hasLength(1));
    },
  );

  test(
    'closing drains an in-flight stream and forbids later operations',
    () async {
      final stream = StreamController<List<int>>();
      final write = store.putStream(stream.stream, kind: AttachmentKind.photo);
      final closed = store.close();
      stream.add(_png);
      await stream.close();
      final ref = await write;
      await closed;
      await expectLater(
        store.read(ref.id),
        throwsA(isA<AttachmentStoreException>()),
      );
      store = (await openAttachmentStore(directoryPath: root.path))!;
      expect((await store.read(ref.id)).bytes, _png);
    },
  );
}

Uint8List _wave() {
  const payload = [0, 0, 1, 0, 255, 255, 0, 0];
  final bytes = Uint8List(44 + payload.length);
  final view = ByteData.sublistView(bytes);
  bytes
    ..setAll(0, ascii.encode('RIFF'))
    ..setAll(8, ascii.encode('WAVEfmt '))
    ..setAll(36, ascii.encode('data'))
    ..setAll(44, payload);
  view
    ..setUint32(4, bytes.length - 8, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, payload.length, Endian.little);
  return bytes;
}

// Minimal structural fixtures for the container probes. They are not
// decoded audio or image fixtures.
Uint8List _m4a({String handler = 'soun'}) => Uint8List.fromList([
  ..._box('ftyp', [...ascii.encode('M4A '), 0, 0, 0, 0]),
  ..._box(
    'moov',
    _box(
      'trak',
      _box(
        'mdia',
        _box('hdlr', [...List.filled(8, 0), ...ascii.encode(handler)]),
      ),
    ),
  ),
  ..._box('mdat', [5, 1, 2]),
]);

Uint8List _heic({String brand = 'heic'}) => Uint8List.fromList([
  ..._box('ftyp', [...ascii.encode(brand), 0, 0, 0, 0]),
  ..._box('meta', [
    0, 0, 0, 0, // version and flags
    ..._box(
      'iprp',
      _box('ipco', _box('ispe', [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2])),
    ),
  ]),
]);

Uint8List _box(String type, List<int> payload) {
  final bytes = Uint8List(8 + payload.length);
  ByteData.sublistView(bytes).setUint32(0, bytes.length);
  bytes
    ..setAll(4, ascii.encode(type))
    ..setAll(8, payload);
  return bytes;
}
