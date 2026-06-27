import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'setup_vault.dart';

/// Password encryption for the provisional-key [SetupVault] — deliberately
/// conventional: **AES-256-GCM** (NIST SP 800-38D) for authenticated
/// encryption, keyed by **Argon2id** (RFC 9106) over the password and a random
/// per-file salt. This is the *only* representation in which the vault leaves
/// memory: [sealVault] is the sole producer of bytes for the file (and, later,
/// the QR), and the plaintext vault JSON is zeroed the instant it is encrypted.
///
/// The protection is cryptographically strong; "provisional" refers to the key
/// being a *transient external crutch* held only across the consolidation window
/// and destroyed at graduation (see
/// `next-steps/provisional-key-bootstrapping.md`), not to any weakness here.
class SetupCrypto {
  SetupCrypto._();

  /// File envelope marker + version (so a wrong/old file is rejected, not
  /// misread).
  static const String magic = 'greatwall-provisional-vault';
  static const int version = 1;

  // RFC 9106 §4 "second recommended" Argon2id parameters: 64 MiB, t=3, p=4 —
  // memory-hard yet feasible on mobile. Stored in the envelope so the value can
  // evolve, but clamped to sane bounds on read so a hostile file cannot force an
  // out-of-memory KDF.
  static const int _argonMemKiB = 64 * 1024; // 64 MiB
  static const int _argonIterations = 3;
  static const int _argonParallelism = 4;
  static const int _keyLen = 32; // AES-256
  static const int _saltLen = 16; // 128-bit KDF salt
  static const int _nonceLen = 12; // 96-bit GCM nonce (SP 800-38D default)

  // Bounds for envelope-supplied KDF parameters (anti-DoS on load).
  static const int _minMemKiB = 8 * 1024; // 8 MiB
  static const int _maxMemKiB = 2 * 1024 * 1024; // 2 GiB
  static const int _maxIterations = 16;
  static const int _maxParallelism = 16;

  static final AesGcm _aes = AesGcm.with256bits();

  static Future<SecretKey> _deriveKey(
    String password,
    List<int> salt, {
    required int memKiB,
    required int iterations,
    required int parallelism,
  }) {
    final Argon2id argon2 = Argon2id(
      memory: memKiB,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: _keyLen,
    );
    return argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt, // the package names the Argon2 salt `nonce`
    );
  }

  /// Encrypt [vault] under [password] into the self-describing UTF-8 JSON
  /// envelope written to disk (and rendered as a QR). The caller still owns and
  /// wipes [vault]; the derived plaintext JSON is zeroed here once sealed.
  static Future<Uint8List> sealVault(SetupVault vault, String password) async {
    final Uint8List salt = _randomBytes(_saltLen);
    final SecretKey key = await _deriveKey(
      password,
      salt,
      memKiB: _argonMemKiB,
      iterations: _argonIterations,
      parallelism: _argonParallelism,
    );
    final Uint8List nonce = _randomBytes(_nonceLen);
    final List<int> plaintext = utf8.encode(jsonEncode(vault.toJson()));
    try {
      final SecretBox box = await _aes.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
      );
      final Map<String, dynamic> envelope = <String, dynamic>{
        'f': magic,
        'v': version,
        'kdf': <String, dynamic>{
          'alg': 'argon2id',
          'm': _argonMemKiB,
          't': _argonIterations,
          'p': _argonParallelism,
          'salt': base64.encode(salt),
        },
        'cipher': 'aes-256-gcm',
        'nonce': base64.encode(box.nonce),
        'ct': base64.encode(box.cipherText),
        'tag': base64.encode(box.mac.bytes),
      };
      return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    } finally {
      _zero(plaintext);
    }
  }

  /// Decrypt an envelope produced by [sealVault] back into a [SetupVault]. Throws
  /// a generic [FormatException] (no value echoed) on a non-vault file,
  /// unsupported version, out-of-bounds KDF parameters, a wrong password, or any
  /// tampering — GCM authentication makes "wrong password" and "corrupt"
  /// indistinguishable, as intended.
  static Future<SetupVault> openVault(Uint8List bytes, String password) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not a Great Wall vault file.');
    }
    if (env['f'] != magic || env['v'] != version) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    final Object? kdf = env['kdf'];
    if (kdf is! Map<String, dynamic>) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    final int memKiB = _boundedInt(kdf['m'], _minMemKiB, _maxMemKiB);
    final int iterations = _boundedInt(kdf['t'], 1, _maxIterations);
    final int parallelism = _boundedInt(kdf['p'], 1, _maxParallelism);
    final List<int> salt = _b64(kdf['salt']);
    final List<int> nonce = _b64(env['nonce']);
    final List<int> ct = _b64(env['ct']);
    final List<int> tag = _b64(env['tag']);

    final SecretKey key = await _deriveKey(
      password,
      salt,
      memKiB: memKiB,
      iterations: iterations,
      parallelism: parallelism,
    );
    final SecretBox box = SecretBox(ct, nonce: nonce, mac: Mac(tag));
    List<int> plaintext;
    try {
      plaintext = await _aes.decrypt(box, secretKey: key);
    } on SecretBoxAuthenticationError {
      throw const FormatException(
          'Could not decrypt — wrong password or corrupt file.');
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Could not decrypt — corrupt file.');
      }
      return SetupVault.fromJson(decoded);
    } finally {
      _zero(plaintext);
    }
  }

  static int _boundedInt(Object? v, int lo, int hi) {
    if (v is! int || v < lo || v > hi) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    return v;
  }

  static List<int> _b64(Object? v) {
    if (v is! String) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
    try {
      return base64.decode(v);
    } catch (_) {
      throw const FormatException('Unsupported or corrupt vault file.');
    }
  }

  static Uint8List _randomBytes(int n) {
    final Random rng = Random.secure();
    final Uint8List out = Uint8List(n);
    for (int i = 0; i < n; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  static void _zero(List<int> b) {
    for (int i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }
}
