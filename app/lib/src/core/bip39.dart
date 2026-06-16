import 'dart:convert';
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

  /// Entropy bit-lengths BIP39 accepts here (mini / default / large presets).
  static const Set<int> _validEntropyBits = <int>{64, 128, 256};

  /// Encode raw entropy bits (no checksum) into a BIP39 mnemonic.
  ///
  /// Port of `bits_to_mnemonic` (great-wall-core/burning_ship/bip39.py) for the
  /// entropy-only input path: the checksum (entropy_len / 32 bits, taken from
  /// the SHA-256 of the entropy bytes) is computed and appended, then the
  /// `entropy + checksum` stream is split into 11-bit groups, each indexing the
  /// canonical wordlist.
  ///
  /// [entropyBits] must contain exactly 64, 128, or 256 bits.
  static String entropyBitsToMnemonic(List<int> entropyBits) {
    final int n = entropyBits.length;
    if (!_validEntropyBits.contains(n)) {
      throw ArgumentError.value(
        n,
        'entropyBits.length',
        'expected one of $_validEntropyBits entropy bits',
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

  /// `SHA-512(utf8(mnemonic + salt))` as a lowercase hex string.
  ///
  /// Matches great-wall-core's standalone "Salt & SHA512" button exactly
  /// (viewer.py: `hashlib.sha512((mnemonic + salt).encode("utf-8")).hexdigest()`).
  /// Intended for target wallets / apps that accept a non-BIP39 high-entropy
  /// seed: a 128-hex-char digest is far harder to accidentally memorise from a
  /// stray glance than the word list, and the descriptive salt domain-separates
  /// one setup from another (see ARCHITECTURE.md §"Stage 0").
  static String saltedDigestHex(String mnemonic, String salt) {
    final Uint8List data = Uint8List.fromList(utf8.encode(mnemonic + salt));
    return sha512.convert(data).toString();
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
