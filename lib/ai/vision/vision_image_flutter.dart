import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'vision_image.dart';

Future<({Uint8List bytes, int width, int height})> encodeVisionPixels(
  Uint8List original,
  Uint8List Function(Uint8List encoded) pixelChunks,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(original);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 || height < 1) {
      throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
    }
    if (height > 50000000 ~/ width) {
      throw const AiVisionImageException(AiVisionImageFailure.sourceTooLarge);
    }
    final originalEdge = math.max(width, height);
    var longest = math.min(originalEdge, AiVisionImage.maxEdge);
    while (true) {
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, width * longest ~/ originalEdge),
        targetHeight: math.max(1, height * longest ~/ originalEdge),
      );
      ui.Image? pixels;
      try {
        pixels = (await codec.getNextFrame()).image;
        final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) {
          throw const AiVisionImageException(AiVisionImageFailure.invalidImage);
        }
        final data = pixelChunks(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        if (data.length <= AiVisionImage.maxBytes) {
          return (bytes: data, width: pixels.width, height: pixels.height);
        }
      } finally {
        pixels?.dispose();
        codec.dispose();
      }
      if (longest <= 128) {
        throw const AiVisionImageException(
          AiVisionImageFailure.derivativeTooLarge,
        );
      }
      longest = math.max(128, longest * 3 ~/ 4);
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}
