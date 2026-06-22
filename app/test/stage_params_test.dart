import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/stage_params.dart';

void main() {
  group('StageReservoirs.fromArgon2Digest', () {
    test('matches great-wall-core derive_stage2_params for a known digest', () {
      // digest = 0x00..0x1f. Reference (Python argon2_pipeline.derive_stage2_params):
      //   sha256(digest) = 630dcd2966c4336691125448bbb25b4f...
      //   o = u64_be(h[0:8])  = 7137586562153591654
      //   p = u64_be(h[8:16]) = 10453510356443749199
      //   q = u64_be(h[16:24])= 17587300486689436360
      final Uint8List digest =
          Uint8List.fromList(List<int>.generate(32, (int i) => i));
      final StageReservoirs r = StageReservoirs.fromArgon2Digest(digest);

      final BigInt mask = (BigInt.one << 64) - BigInt.one;
      BigInt u(int signed) => BigInt.from(signed) & mask;

      expect(u(r.o), BigInt.parse('7137586562153591654'));
      expect(u(r.p), BigInt.parse('10453510356443749199'));
      expect(u(r.q), BigInt.parse('17587300486689436360'));
    });

    test('redacts (o, p, q) in toString', () {
      final StageReservoirs r = StageReservoirs(o: 1, p: 2, q: 3);
      expect(r.toString(), 'StageReservoirs(<redacted>)');
    });

    test('clear zeroes the reservoirs', () {
      final StageReservoirs r = StageReservoirs(o: 1, p: 2, q: 3)..clear();
      expect(<int>[r.o, r.p, r.q], <int>[0, 0, 0]);
    });
  });

  group('decodeDisplayReservoir', () {
    test('zero reservoir with no baseline is 0', () {
      expect(decodeDisplayReservoir(0, minExp: 3), 0.0);
    });

    test('p baseline contributes 2^-baselineExp', () {
      // p=0 with baselineExp 3 -> +1/8 (matches the p baseline +1/8).
      expect(decodeDisplayReservoir(0, minExp: 4, baselineExp: 3), 0.125);
    });
  });
}
