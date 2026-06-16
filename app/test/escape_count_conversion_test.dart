import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/core_escape_count_source.dart';

void main() {
  group('escapeCountsFromPixels', () {
    test('maps non-escaping (0) to maxIterations and escaped v to v-1', () {
      // 1x3 row: inside, escape-count 0 (encoded 1), escape-count 9 (encoded 10).
      final Uint8List pixels = Uint8List.fromList(<int>[0, 1, 10]);
      final Uint32List counts = escapeCountsFromPixels(pixels, 3, 1, 64);
      expect(counts, <int>[64, 0, 9]);
    });

    test('flips rows: UX row y reads engine row (h-1-y)', () {
      // 2 wide, 3 tall. Engine rows top->bottom = [A, B, C]; the UX raster must
      // come out bottom->top = [C, B, A] because the imaginary axis is flipped.
      final Uint8List pixels = Uint8List.fromList(<int>[
        11, 12, // engine row 0
        21, 22, // engine row 1
        31, 32, // engine row 2
      ]);
      final Uint32List counts = escapeCountsFromPixels(pixels, 2, 3, 64);
      expect(counts, <int>[
        30, 31, // (31-1, 32-1)  -> engine row 2
        20, 21, // engine row 1
        10, 11, // engine row 0
      ]);
    });

    test('output length is width*height', () {
      final Uint8List pixels = Uint8List(20);
      expect(escapeCountsFromPixels(pixels, 5, 4, 64).length, 20);
    });
  });
}
