import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/entropy.dart';

void main() {
  group('Entropy.bitsToBytes', () {
    test('packs MSB-first like great-wall-core bits_to_bytes', () {
      // 0b1000_0001, 0b0100_0000
      final List<int> bits = <int>[1, 0, 0, 0, 0, 0, 0, 1, 0, 1];
      final Uint8List bytes = Entropy.bitsToBytes(bits);
      expect(bytes.length, 2);
      expect(bytes[0], 0x81);
      expect(bytes[1], 0x40); // trailing bits left-aligned
    });

    test('round-trips whole bytes through bytesToBits', () {
      final Uint8List bytes = Uint8List.fromList(<int>[0xAB, 0xCD, 0x12]);
      final List<int> bits = Entropy.bytesToBits(bytes);
      expect(bits.length, 24);
      expect(Entropy.bitsToBytes(bits), bytes);
    });
  });

  group('Entropy.stage1Argon2Input', () {
    test('always returns 8 bytes (right-padded)', () {
      final List<int> shortBits = List<int>.filled(32, 1); // 4 bytes
      final Uint8List input = Entropy.stage1Argon2Input(shortBits);
      expect(input.length, 8);
      expect(input.sublist(0, 4), <int>[0xFF, 0xFF, 0xFF, 0xFF]);
      expect(input.sublist(4), <int>[0, 0, 0, 0]);
    });
  });

  group('Entropy.randomBits', () {
    test('produces the requested number of bits, all 0/1', () {
      final List<int> bits = Entropy.randomBits(128);
      expect(bits.length, 128);
      expect(bits.every((int b) => b == 0 || b == 1), isTrue);
    });
  });

  group('Entropy.wipe', () {
    test('zeroes the list in place', () {
      final List<int> bits = <int>[1, 1, 0, 1];
      Entropy.wipe(bits);
      expect(bits, <int>[0, 0, 0, 0]);
    });
  });
}
