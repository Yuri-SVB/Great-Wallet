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
/// orchestration needs to assemble each chain link's Argon2 input (Stage-0
/// salt/pepper followed by the preceding points) and the per-stage chunks.
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

  /// The Argon2 input for a chain link: the cumulative bits of every point that
  /// precedes the stage being derived, packed to bytes.
  ///
  /// This is `bits_to_bytes(prior_bits)` at its **natural length** — one byte
  /// per 8 prior bits — exactly what great-wall-core's `derive_stage_params`
  /// feeds (argon2_pipeline.py: `data = bits_to_bytes(prior_bits)`).
  static Uint8List argon2Input(List<int> priorBits) => bitsToBytes(priorBits);

  /// The Argon2 input for a chain link under the **Stage-0** scheme: the
  /// salt/pepper text bytes followed by the packed bits of every preceding
  /// point. Stage 0 seeds the chain (so the first fractal, stage 1, derives from
  /// the text alone), and every later fractal mixes the text with the prior
  /// points — there is no canonical fractal. The text gates the chain only; it
  /// never enters the entropy, so the BIP39 ↔ Great Wall conversion stays
  /// lossless.
  static Uint8List chainInput(Uint8List textBytes, List<int> priorPointBits) {
    final Uint8List pts = bitsToBytes(priorPointBits);
    final Uint8List out = Uint8List(textBytes.length + pts.length);
    out.setRange(0, textBytes.length, textBytes);
    out.setRange(textBytes.length, out.length, pts);
    return out;
  }

  /// Encode the Stage-0 salt/pepper string to its derivation bytes. The input is
  /// already constrained to a safe ASCII subset (uppercase letters, digits,
  /// hyphen) by the UI, so a plain code-unit encoding is exact and stable.
  static Uint8List saltPepperBytes(String text) =>
      Uint8List.fromList(text.codeUnits);

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
