import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/ffi/fixed.dart';

void main() {
  group('I4F60 fixed-point', () {
    test('scale factor is 2^60', () {
      expect(kFixedOne, 1 << 60);
      expect(fixedFromDouble(1.0), 1 << 60);
    });

    test('encodes the encode-area bounds without surprise', () {
      // ENCODE_AREA = [-2.5, 1.5] x [-2.0, 1.5].
      expect(fixedFromDouble(-2.5), (-2.5 * (1 << 60)).round());
      expect(fixedToDouble(fixedFromDouble(1.5)), closeTo(1.5, 1e-15));
    });

    test('round-trips representative values within precision', () {
      for (final double v in <double>[-2.0, -0.5, 0.0, 0.125, 1.0, 1.49]) {
        expect(fixedToDouble(fixedFromDouble(v)), closeTo(v, 1e-15));
      }
    });
  });
}
