import 'dart:typed_data';

Future<({Uint8List bytes, int width, int height})> encodeVisionPixels(
  Uint8List original,
  Uint8List Function(Uint8List encoded) pixelChunks,
) async => throw UnsupportedError('Meal photo preparation requires Flutter.');
