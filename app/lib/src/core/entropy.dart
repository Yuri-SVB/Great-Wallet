import 'dart:math';
import 'dart:typed_data';

/// Bit/byte helpers for the entropy that flows between the user's fractal
/// recall and the wallet seed.
///
/// The full key-derivation chain (raw entropy -> BIP39 mnemonic ->
/// PBKDF2 seed -> BIP32 xpriv) is great-wall-core's responsibility and is NOT
/// re-implemented here (SCOPE.md: "Key derivation, BIP39, BIP32 ... never
/// handled in the UX layer"; it belongs to the engine/app boundary, surfaced
/// over FFI in a later pass). This file covers only the bit plumbing the Setup
/// orchestration needs to assemble `stage-1 || stage-2` and hand the engine
/// 8-byte chunks for Argon2.
class Entropy {
  Entropy._();

  /// Pack a list of 0/1 ints MSB-first into bytes. Trailing bits in a final
  /// partial byte are left-aligned (shifted up), matching `bits_to_bytes` in
  /// great-wall-core/burning_ship/encoding.py.
  static Uint8List bitsToBytes(List<int> bits) {
    final int nBytes = (bits.length + 7) ~/ 8;
    final Uint8List out = Uint8List(nBytes);
    for (int i = 0; i < bits.length; i++) {
      if (bits[i] != 0) {
        out[i >> 3] |= 1 << (7 - (i & 7));
      }
    }
    return out;
  }

  /// Expand bytes to a list of 0/1 ints, MSB-first. Inverse of [bitsToBytes]
  /// for whole-byte inputs.
  static List<int> bytesToBits(Uint8List bytes) {
    final List<int> bits = List<int>.filled(bytes.length * 8, 0);
    for (int i = 0; i < bytes.length; i++) {
      for (int j = 0; j < 8; j++) {
        bits[i * 8 + j] = (bytes[i] >> (7 - j)) & 1;
      }
    }
    return bits;
  }

  /// The Argon2 input derived from stage-1 bits.
  ///
  /// This is `bits_to_bytes(stage1_bits)` at its **natural length** — 4 bytes
  /// for the mini preset, 8 for default, 16 for large — exactly what
  /// great-wall-core's `run_argon2_iterative` feeds
  /// (argon2_pipeline.py: `data = bits_to_bytes(stage1_bits)`). No padding or
  /// truncation: the engine's Argon2 accepts any input length, and padding to a
  /// fixed 8 bytes would change the digest (hence `(o, p, q)` and the stage-2
  /// fractal) for any preset other than default.
  static Uint8List stage1Argon2Input(List<int> stage1Bits) =>
      bitsToBytes(stage1Bits);

  /// Generate `bitCount` cryptographically-random bits using a secure RNG.
  ///
  /// Setup is a "write-only operation on the user's memory" (ARCHITECTURE.md
  /// §"Invariants"): a fresh root is generated here, encoded onto the fractal,
  /// and the plaintext destroyed. `bitCount` must be a multiple of 8.
  static List<int> randomBits(int bitCount, {Random? random}) {
    assert(bitCount % 8 == 0, 'bitCount must be a whole number of bytes');
    final Random rng = random ?? Random.secure();
    final Uint8List bytes = Uint8List(bitCount ~/ 8);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytesToBits(bytes);
  }

  /// Overwrite a bit list with zeros once it is no longer needed.
  static void wipe(List<int> bits) {
    for (int i = 0; i < bits.length; i++) {
      bits[i] = 0;
    }
  }
}
