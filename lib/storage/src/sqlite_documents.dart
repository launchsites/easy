import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'contracts.dart';
import 'snapshot_codec.dart';

const _minimumChunk = 16 * 1024;
const _maximumChunk = 64 * 1024;
// Nested JSON string lists can nearly double the validated raw snapshot bytes.
const _maximumDocument = 144 * 1024 * 1024;
const _maximumChunks = _maximumDocument ~/ _minimumChunk + 1;
const _boundaryMask = 0x3fff;
const _uint32Mask = 0xffffffff;
const _corruptDocument = WorkspaceStoreException(
  'A workspace document failed its integrity check.',
);
final _encoder = ZLibCodec(level: 1);
final _gear = _gearValues();

final class SqliteDocuments {
  SqliteDocuments(this.database);

  final Database database;

  /// Keep the original v1 bodies readable while writing all new bodies as
  /// checksummed, compressed chunks. The legacy JSON column remains intact.
  static void migrate(Database database) => database.execute('''
    ALTER TABLE documents ADD COLUMN chunked INTEGER NOT NULL DEFAULT 0 CHECK (chunked IN (0, 1));
    ALTER TABLE documents ADD COLUMN stored_bytes INTEGER NOT NULL DEFAULT 0 CHECK (stored_bytes >= 0);
    CREATE TABLE document_chunks (
      digest TEXT PRIMARY KEY,
      raw_bytes INTEGER NOT NULL CHECK (raw_bytes BETWEEN 1 AND $_maximumChunk),
      compressed BLOB NOT NULL CHECK (length(compressed) BETWEEN 1 AND ${_maximumChunk + 128})
    ) STRICT, WITHOUT ROWID;
    CREATE TABLE document_chunk_refs (
      document TEXT NOT NULL REFERENCES documents(digest) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < $_maximumChunks),
      chunk TEXT NOT NULL REFERENCES document_chunks(digest),
      PRIMARY KEY (document, ordinal)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX document_chunk_usage ON document_chunk_refs (chunk);
    CREATE INDEX revision_workspace_usage ON revisions (workspace);
    CREATE INDEX revision_session_usage ON revisions (gym_sessions);
    CREATE INDEX revision_plan_usage ON revisions (workout_plans);
  ''');

  String add(String text) {
    final raw = utf8.encode(text);
    if (raw.isEmpty || raw.length > _maximumDocument) throw _corruptDocument;
    final digest = sha256.convert(raw).toString();
    if (database.select('SELECT 1 FROM documents WHERE digest = ?', [
      digest,
    ]).isNotEmpty) {
      return digest;
    }
    database.execute(
      'INSERT INTO documents (digest, body, chunked) VALUES (?, ?, 1)',
      [digest, 'null'],
    );
    final find = database.prepare(
      'SELECT length(compressed) AS size FROM document_chunks WHERE digest = ?',
    );
    final insert = database.prepare(
      'INSERT INTO document_chunks VALUES (?, ?, ?)',
    );
    final link = database.prepare(
      'INSERT INTO document_chunk_refs VALUES (?, ?, ?)',
    );
    var ordinal = 0;
    var stored = 0;
    try {
      for (final chunk in _chunks(raw)) {
        final chunkDigest = sha256.convert(chunk).toString();
        final size = find.select([chunkDigest]).firstOrNull?['size'];
        if (size is int) {
          stored += size;
        } else {
          final compressed = Uint8List.fromList(_encoder.encode(chunk));
          insert.execute([chunkDigest, chunk.length, compressed]);
          stored += compressed.length;
        }
        link.execute([digest, ordinal++, chunkDigest]);
      }
    } finally {
      find.close();
      insert.close();
      link.close();
    }
    database.execute('UPDATE documents SET stored_bytes = ? WHERE digest = ?', [
      stored,
      digest,
    ]);
    return digest;
  }

  String read(String digest) {
    final row = database.select(
      'SELECT body, chunked FROM documents WHERE digest = ?',
      [digest],
    ).firstOrNull;
    if (row == null) throw _corruptDocument;
    if (row['chunked'] == 0) {
      final text = row['body'];
      if (text is String &&
          text.length <= _maximumDocument &&
          digestText(text) == digest) {
        return text;
      }
      throw _corruptDocument;
    }
    if (row['chunked'] != 1 || row['body'] != 'null') throw _corruptDocument;
    final statement = database.prepare('''
      SELECT refs.ordinal, refs.chunk, parts.raw_bytes, parts.compressed
      FROM document_chunk_refs AS refs
      LEFT JOIN document_chunks AS parts ON parts.digest = refs.chunk
      WHERE refs.document = ?
      ORDER BY refs.ordinal
    ''');
    final output = BytesBuilder(copy: false);
    var ordinal = 0;
    try {
      final cursor = statement.selectCursor([digest]);
      while (cursor.moveNext()) {
        final part = cursor.current;
        final size = part['raw_bytes'];
        final compressed = part['compressed'];
        if (part['ordinal'] != ordinal++ ||
            ordinal > _maximumChunks ||
            size is! int ||
            size < 1 ||
            size > _maximumChunk ||
            compressed is! Uint8List ||
            compressed.length > _maximumChunk + 128 ||
            size > _maximumDocument - output.length) {
          throw _corruptDocument;
        }
        final sink = _BoundedSink(size);
        final decoder = zlib.decoder.startChunkedConversion(sink);
        decoder.add(compressed);
        decoder.close();
        final raw = sink.bytes.takeBytes();
        if (raw.length != size ||
            sha256.convert(raw).toString() != part['chunk']) {
          throw _corruptDocument;
        }
        output.add(raw);
      }
      final raw = output.takeBytes();
      if (ordinal == 0 || sha256.convert(raw).toString() != digest) {
        throw _corruptDocument;
      }
      return utf8.decode(raw);
    } on FormatException {
      throw _corruptDocument;
    } finally {
      statement.close();
    }
  }

  void removeUnused() {
    database.execute('''
      DELETE FROM documents
      WHERE NOT EXISTS (SELECT 1 FROM revisions WHERE workspace = documents.digest)
        AND NOT EXISTS (SELECT 1 FROM revisions WHERE gym_sessions = documents.digest)
        AND NOT EXISTS (SELECT 1 FROM revisions WHERE workout_plans = documents.digest);
      DELETE FROM document_chunks
      WHERE NOT EXISTS (SELECT 1 FROM document_chunk_refs WHERE chunk = document_chunks.digest);
    ''');
  }
}

Iterable<Uint8List> _chunks(Uint8List raw) sync* {
  var start = 0;
  while (start < raw.length) {
    final maximum = _minimum(start + _maximumChunk, raw.length);
    var end = _minimum(start + _minimumChunk, maximum);
    var hash = 0;
    while (end < maximum) {
      hash = ((hash << 1) + _gear[raw[end++]]) & _uint32Mask;
      if (hash & _boundaryMask == 0) break;
    }
    yield Uint8List.sublistView(raw, start, end);
    start = end;
  }
}

int _minimum(int a, int b) => a < b ? a : b;

Uint32List _gearValues() {
  var state = 0x2b91a385;
  return Uint32List.fromList(
    List.generate(256, (_) {
      state ^= (state << 13) & _uint32Mask;
      state ^= state >> 17;
      state ^= (state << 5) & _uint32Mask;
      return state;
    }),
  );
}

final class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);

  final int limit;
  final bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    if (data.length > limit - bytes.length) throw _corruptDocument;
    bytes.add(data);
  }

  @override
  void close() {}
}
