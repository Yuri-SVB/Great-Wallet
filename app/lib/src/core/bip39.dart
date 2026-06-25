import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bip39_wordlist.dart';
import 'entropy.dart';

/// BIP39 *wire-format* encoding for the seed-export affordance.
///
/// ## Why this lives in the app
///
/// `great-wall-ux` deliberately never touches key derivation / BIP39 / BIP32
/// (SCOPE.md), and the engine's Rust FFI surface (`bs_*`) exposes
/// encode / decode / Argon2 / render but **no** BIP39 — the canonical BIP39
/// implementation is Python-only in great-wall-core
/// (`burning_ship/bip39.py`). The seed-export buttons in Recall need a
/// mnemonic on the Dart side *now*, so the app owns this small, pure
/// wire-format encoder. It is a faithful port of great-wall-core's
/// `bits_to_mnemonic` (same canonical wordlist, same SHA-256 checksum), so an
/// exported phrase round-trips with the standalone byte-for-byte. If the
/// engine later grows a `bs_bip39_*` export, this can be swapped for the FFI
/// path without changing callers.
///
/// SECURITY: a mnemonic and its salted digest are coercion-relevant. This
/// class only *computes* them on demand for an explicit user-initiated
/// blind copy; it never logs, persists, or displays them.
class Bip39 {
  Bip39._();

  /// Encode raw entropy bits (no checksum) into a BIP39 mnemonic.
  ///
  /// Port of `bits_to_mnemonic` (great-wall-core/burning_ship/bip39.py) for the
  /// entropy-only input path: the checksum (entropy_len / 32 bits, taken from
  /// the SHA-256 of the entropy bytes) is computed and appended, then the
  /// `entropy + checksum` stream is split into 11-bit groups, each indexing the
  /// canonical wordlist.
  ///
  /// [entropyBits] must contain a positive multiple of 32 bits. The full-seed
  /// presets are 64 / 128 / 256, but the chained protocol also exports the seed
  /// *partially* during recall (one 32-bit point per stage), so any `32·m` bits
  /// is accepted. Such partial seeds are well-formed — `32·m` entropy + `m`
  /// checksum = `33·m` bits = `3·m` words — but, below the final stage, are a
  /// non-standard (shorter, weaker) length. That is expected: the export is a
  /// blind convenience, and the holder chooses when the seed is "enough".
  static String entropyBitsToMnemonic(List<int> entropyBits) {
    final int n = entropyBits.length;
    if (n == 0 || n % 32 != 0) {
      throw ArgumentError.value(
        n,
        'entropyBits.length',
        'expected a positive multiple of 32 entropy bits',
      );
    }

    final List<int> bits = <int>[...entropyBits, ..._checksumBits(entropyBits)];
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < bits.length; i += 11) {
      int idx = 0;
      for (int j = 0; j < 11; j++) {
        idx = (idx << 1) | bits[i + j];
      }
      if (out.isNotEmpty) out.write(' ');
      out.write(bip39English[idx]);
    }
    return out.toString();
  }

  /// Hard cap: 24 words / 256 entropy bits (constants.MAX_ENTROPY_BITS).
  static const int _maxWords = 24;

  /// Decode a BIP39 mnemonic into its raw **entropy** bits (checksum stripped),
  /// for the "import an existing seed" path that encodes it onto the chained
  /// fractals.
  ///
  /// Port of `mnemonic_to_bits` (great-wall-core/burning_ship/bip39.py): accepts
  /// any multiple of 3 words from 3 to 24 — `words/3` stages, `32·words/3`
  /// entropy bits — so the same sub-standard seeds the partial export can
  /// produce round-trip back in. The BIP39 checksum is verified.
  ///
  /// SECURITY: the mnemonic is coercion-relevant. On bad input this throws a
  /// [FormatException] whose message is deliberately generic — it never echoes
  /// the offending word or any seed content (unlike the Python reference), so an
  /// error surfaced in the UI or a log cannot leak the secret.
  static List<int> mnemonicToEntropyBits(String mnemonic) {
    final List<String> words = mnemonic
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .toList();
    final int n = words.length;
    if (n == 0 || n % 3 != 0) {
      throw const FormatException(
          'A seed phrase must be a multiple of 3 words (3–24).');
    }
    if (n > _maxWords) {
      throw const FormatException(
          'Too many words: the cap is 24 (256-bit entropy).');
    }

    final int entropyLen = (n ~/ 3) * 32; // 32 bits per stage
    final List<int> bits = <int>[];
    for (final String w in words) {
      final int idx = _indexOfWord(w);
      if (idx < 0) {
        throw const FormatException(
            'That is not a valid BIP39 seed phrase (unknown word).');
      }
      for (int b = _bitsPerWord - 1; b >= 0; b--) {
        bits.add((idx >> b) & 1);
      }
    }

    final List<int> entropy = bits.sublist(0, entropyLen);
    final List<int> checksum = bits.sublist(entropyLen);
    final List<int> expected = _checksumBits(entropy);
    if (!_bitsEqual(checksum, expected)) {
      throw const FormatException(
          'Seed phrase checksum is invalid — check for typos.');
    }
    return entropy;
  }

  static const int _bitsPerWord = 11; // log2(2048)

  /// Lazily-built reverse index of the canonical wordlist; `-1` if not present.
  static Map<String, int>? _wordToIndex;
  static int _indexOfWord(String word) {
    final Map<String, int> map = _wordToIndex ??= <String, int>{
      for (int i = 0; i < bip39English.length; i++) bip39English[i]: i,
    };
    return map[word] ?? -1;
  }

  static bool _bitsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The BIP39 checksum bits for [entropyBits]: the first `len / 32` bits of
  /// `SHA-256(entropy_bytes)`, MSB-first. Mirrors `_checksum_bits` in
  /// great-wall-core/burning_ship/bip39.py.
  static List<int> _checksumBits(List<int> entropyBits) {
    final int csLen = entropyBits.length ~/ 32;
    final Uint8List entropyBytes = Entropy.bitsToBytes(entropyBits);
    final Uint8List sha =
        Uint8List.fromList(sha256.convert(entropyBytes).bytes);
    return <int>[
      for (int i = 0; i < csLen; i++) (sha[i ~/ 8] >> (7 - i % 8)) & 1,
    ];
  }
}
