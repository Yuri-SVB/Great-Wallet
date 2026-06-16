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

    test('no row flip: engine row y maps directly to UX row y', () {
      // The engine and ViewportMath now share the downward imaginary-axis
      // convention, so rows are preserved (only the u8 -> count remap applies).
      final Uint8List pixels = Uint8List.fromList(<int>[
        11, 12, // row 0
        21, 22, // row 1
        31, 32, // row 2
      ]);
      final Uint32List counts = escapeCountsFromPixels(pixels, 2, 3, 64);
      expect(counts, <int>[
        10, 11, // row 0  (v-1)
        20, 21, // row 1
        30, 31, // row 2
      ]);
    });

    test('output length is width*height', () {
      final Uint8List pixels = Uint8List(20);
      expect(escapeCountsFromPixels(pixels, 5, 4, 64).length, 20);
    });
  });
}
