import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/bip39.dart';

/// Parity vectors captured from great-wall-core/burning_ship/bip39.py
/// (`bits_to_mnemonic`) and viewer.py's SHA-512 export. If these match, a seed
/// phrase exported by the wallet round-trips with the standalone byte-for-byte.
void main() {
  List<int> bitsFromHex(String hex, int nBits) {
    final BigInt v = BigInt.parse(hex, radix: 16);
    return <int>[
      for (int i = 0; i < nBits; i++)
        ((v >> (nBits - 1 - i)) & BigInt.one).toInt(),
    ];
  }

  group('Bip39.entropyBitsToMnemonic matches great-wall-core', () {
    test('64-bit all-zero', () {
      expect(
        Bip39.entropyBitsToMnemonic(List<int>.filled(64, 0)),
        'abandon abandon abandon abandon abandon able',
      );
    });

    test('128-bit all-zero', () {
      expect(
        Bip39.entropyBitsToMnemonic(List<int>.filled(128, 0)),
        'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon about',
      );
    });

    test('256-bit all-zero', () {
      expect(
        Bip39.entropyBitsToMnemonic(List<int>.filled(256, 0)),
        'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon abandon abandon art',
      );
    });

    test('128-bit all-one', () {
      expect(
        Bip39.entropyBitsToMnemonic(List<int>.filled(128, 1)),
        'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong',
      );
    });

    test('128-bit pattern', () {
      expect(
        Bip39.entropyBitsToMnemonic(
          bitsFromHex('0123456789abcdeffedcba9876543210', 128),
        ),
        'abuse boss fly battle rubber wave window nuclear observe razor '
            'arrive calm',
      );
    });

    test('64-bit pattern', () {
      expect(
        Bip39.entropyBitsToMnemonic(bitsFromHex('0f1e2d3c4b5a6978', 64)),
        'audit vapor excuse note pledge rough',
      );
    });

    test('256-bit pattern', () {
      expect(
        Bip39.entropyBitsToMnemonic(
          bitsFromHex(
            '00112233445566778899aabbccddeeff'
            'ffeeddccbbaa99887766554433221100',
            256,
          ),
        ),
        'abandon math mimic master filter design carbon crystal rookie group '
            'knife zoo year humble cream inspire office dry sunset pride drip '
            'much dune bulb',
      );
    });

    test('rejects a non-BIP39 entropy length', () {
      expect(
        () => Bip39.entropyBitsToMnemonic(List<int>.filled(100, 0)),
        throwsArgumentError,
      );
    });
  });

  test('saltedDigestHex matches great-wall-core SHA-512(mnemonic + salt)', () {
    const String mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';
    expect(
      Bip39.saltedDigestHex(mnemonic, 'main wallet'),
      '219da384b9b82f4d77b87252f5a23b210a36bba9acdd311dfa87073b94baa24d'
      '3c4c87e30ae0dd45010135111b4a503b7a5837e5c1d85f8cea7696f543ec72f9',
    );
  });
}
