import 'dart:io';

import 'package:easy/storage/src/media_staging_native.dart';

Future<void> main(List<String> arguments) async {
  final stage = await MediaFileStage.create(
    Directory(arguments[0]),
    MediaStageKind.values.byName(arguments[1]),
  );
  try {
    final payload = File.fromUri(stage.content.uri.resolve('payload'));
    await payload.writeAsBytes(List.filled(4096, 1), flush: true);
    stdout.writeln(stage.directory.path);
    await stdout.flush();
    await stdin.drain<void>();
  } finally {
    await stage.close();
  }
}
