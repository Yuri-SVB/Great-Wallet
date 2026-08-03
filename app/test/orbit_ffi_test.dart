import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';

/// Cross-language smoke test for the orbit-protocol (0.4.0) FFI through the Dart
/// bridge (core_bindings.dart) — the peer of great-wall-core's test_orbit_ffi.py.
///
/// Verifies the built Rust engine's `bs_orbit_root` / `bs_theta` /
/// `bs_master_secret` / `bs_shamir_interp` / `bs_setup_tier_*` as seen through
/// Dart, cross-checked with `package:crypto` (for H = SHA-256) and a tiny
/// independent GF(2^32) reference (for Shamir). This is what lets you
/// `flutter test` the latest engine commits end-to-end via Dart.
///
/// REQUIRES the engine `.so`/`.dylib`/`.dll` to be built (`native/build_core.sh`,
/// i.e. `cargo build --release` in great-wall-core/burning_ship/rust_engine) AND
/// great-wallet's great-wall-core submodule to point at the orbit commit — an
/// older pin has no `bs_orbit_*` symbols and the lookups throw. If the library
/// cannot be opened at all — or opens but predates the orbit symbols, so a
/// `bs_orbit_*` lookup fails — every test is skipped with the reason (a fresh or
/// stale checkout is not a test failure; the skip message names the cause,
/// including the missing symbol for an old pin). Rebuild + repin to run them.
///
/// `orbitAdvance` is intentionally not exercised here (it runs real Argon2d at
/// >= 1 GiB, minutes per run); the Rust `orbit_step_with` test covers its
/// orchestration, and its `K_i` out-param equals `masterSecret(o, sh)` — the
/// cheap commitment this file does verify.
void main() {
  GreatWallCoreBindings? bindings;
  String? openError;

  setUpAll(() {
    try {
      bindings = GreatWallCoreBindings.open();
    } on CoreLibraryNotFound catch (e) {
      openError = e.toString();
    } on ArgumentError catch (e) {
      // dlopen succeeded but a symbol lookup failed (old pin without the orbit
      // ABI), or dlopen failed for a reason other than "not found".
      openError = 'engine library unusable: $e';
    }
  });

  group('orbit_root (o_0 = H(sigma) = SHA-256)', () {
    test("matches package:crypto SHA-256 for b'abc'", () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final Uint8List msg = _ascii('abc');
      expect(
        b.orbitRoot(msg),
        _sha256(msg),
        reason: "orbit_root(b'abc') must equal SHA-256(b'abc')",
      );
    });

    test('matches over a 128-byte sigma (Namtso 1024-bit width)', () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final Uint8List sigma =
          Uint8List.fromList(List<int>.generate(128, (int i) => i));
      expect(b.orbitRoot(sigma), _sha256(sigma));
      // Deterministic, and sensitive to the last byte.
      expect(b.orbitRoot(sigma), b.orbitRoot(sigma));
      final Uint8List perturbed = Uint8List.fromList(sigma)..[127] = 0;
      expect(b.orbitRoot(sigma), isNot(b.orbitRoot(perturbed)));
    });
  });

  group('theta (theta_i_j = H(o_i || j), big-endian j)', () {
    test('matches H(o || j) and separates by board / orbit point', () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final Uint8List o = _fill(32, 7);
      // j is a big-endian u32 appended to o_i.
      final Uint8List expected0 = _sha256(_concat(o, _u32be(0)));
      expect(b.theta(o, 0), expected0);
      expect(b.theta(o, 3), isNot(b.theta(o, 4)),
          reason: 'distinct board index -> distinct fractal');
      expect(b.theta(o, 0), isNot(b.theta(_fill(32, 8), 0)),
          reason: 'distinct orbit point -> distinct fractal');
    });
  });

  group('master_secret (K_i = H(o_i || Sh_i))', () {
    test('matches H(o || sh) and separates by Sh', () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final Uint8List o = _fill(32, 1);
      final Uint8List sh = Uint8List.fromList(
          <int>[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]);
      expect(b.masterSecret(o, sh), _sha256(_concat(o, sh)));
      final Uint8List sh2 = Uint8List.fromList(sh)..[sh.length - 1] = 0x89;
      expect(b.masterSecret(o, sh), isNot(b.masterSecret(o, sh2)),
          reason: 'distinct Sh -> distinct K_i');
    });
  });

  group('shamir_interp (full Sh over GF(2^32), subset-invariant)', () {
    test('recovers the polynomial and is subset-invariant', () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final _Rng rng = _Rng(0xC0FFEE);
      for (int t = 2; t <= 5; t++) {
        final int s = t + 3; // t primary + 3 forgetting-resistance shares
        final List<int> coeffs =
            List<int>.generate(t, (_) => rng.nextU32NonZero());
        final List<int> xs = <int>[
          for (int k = 0; k < t; k++) _primaryAbscissa(k),
          for (int k = 0; k < s - t; k++) _resistanceAbscissa(k),
        ];
        final List<int> ys = xs.map((int x) => _gfEval(coeffs, x)).toList();

        // width: the first t points -> t coefficients, recovering the poly.
        final List<int> sh0 =
            b.shamirInterp(xs.sublist(0, t), ys.sublist(0, t));
        expect(sh0.length, t, reason: 't=$t: Sh has t coefficients');
        expect(sh0, coeffs, reason: 't=$t: recovers the original polynomial');

        // subset-invariance: several distinct t-subsets -> identical Sh bytes.
        final List<List<int>> subsets = <List<int>>[
          <int>[for (int i = 0; i < t; i++) i],
          <int>[for (int i = 1; i < t + 1; i++) i],
          <int>[for (int i = s - t; i < s; i++) i],
        ];
        final Set<String> wireForms = <String>{};
        for (final List<int> sub in subsets) {
          final List<int> sx = <int>[for (final int i in sub) xs[i]];
          final List<int> sy = <int>[for (final int i in sub) ys[i]];
          final List<int> sh = b.shamirInterp(sx, sy);
          expect(sh, coeffs,
              reason: 't=$t: any t of $s shares reconstruct the identical Sh');
          wireForms.add(_hex(GreatWallCoreBindings.shToBytes(sh)));
        }
        expect(wireForms.length, 1,
            reason: 't=$t: identical Sh wire bytes across subsets (K_i stable)');
      }
    });
  });

  group('setup tiers (canonical per-stage thresholds t_i)', () {
    test('canonical tiers, substandard flag, and r_i > 2 on deep stages', () {
      final GreatWallCoreBindings? b = bindings;
      if (b == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      expect(b.setupTierThresholds(1), <int>[2, 2],
          reason: 'Setup 1 -> [2, 2] (entry)');
      expect(b.setupTierThresholds(2), <int>[2, 3],
          reason: 'Setup 2 -> [2, 3] (standard)');
      expect(b.setupTierThresholds(3), <int>[2, 3, 3]);
      expect(b.setupTierThresholds(4), <int>[2, 3, 3, 3]);

      expect(b.setupTierSubstandard(1), isTrue,
          reason: 'Setup 1 is substandard (64-bit deep stage)');
      for (int k = 2; k < 10; k++) {
        expect(b.setupTierSubstandard(k), isFalse,
            reason: 'Setup $k is standard');
      }

      expect(b.setupTierThresholds(0), isEmpty,
          reason: 'invalid level 0 -> []');

      // The r_i > 2 rule: every deep stage of a standard setup is >= 3.
      for (int k = 2; k < 10; k++) {
        final List<int> deep = b.setupTierThresholds(k).sublist(1);
        for (final int t in deep) {
          expect(t > 2, isTrue, reason: 'Setup $k: every deep r_i > 2');
        }
      }
    });
  });
}

// --- helpers -----------------------------------------------------------------

Uint8List _sha256(Uint8List data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _fill(int len, int value) => Uint8List(len)..fillRange(0, len, value);

Uint8List _u32be(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xFF
  ..[1] = (v >> 16) & 0xFF
  ..[2] = (v >> 8) & 0xFF
  ..[3] = v & 0xFF;

Uint8List _concat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setAll(0, a)
  ..setAll(a.length, b);

String _hex(Uint8List bytes) {
  final StringBuffer sb = StringBuffer();
  for (final int b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

// --- independent GF(2^32) reference (mirrors src/shamir.rs; reduction 0x8D) ---

const int _kReduction = 0x8D;

int _gfMul(int a, int b) {
  int acc = 0;
  int x = a & 0xFFFFFFFF;
  int y = b & 0xFFFFFFFF;
  while (y != 0) {
    if (y & 1 != 0) acc ^= x;
    final int carry = x & 0x80000000;
    x = (x << 1) & 0xFFFFFFFF;
    if (carry != 0) x ^= _kReduction;
    y >>= 1;
  }
  return acc & 0xFFFFFFFF;
}

/// Horner evaluation of a polynomial (ascending-power coeffs) at x over GF(2^32).
int _gfEval(List<int> coeffs, int x) {
  int acc = 0;
  for (int i = coeffs.length - 1; i >= 0; i--) {
    acc = _gfMul(acc, x) ^ coeffs[i];
  }
  return acc & 0xFFFFFFFF;
}

int _primaryAbscissa(int k) => k + 1;

int _resistanceAbscissa(int k) => 0x80000000 | (k + 1);

/// Tiny deterministic LCG so the vectors are reproducible without `Random`'s
/// implementation-defined stream. Numerical Recipes' 32-bit LCG constants.
class _Rng {
  _Rng(this._state);
  int _state;

  int _nextU32() {
    _state = (0x19660D * _state + 0x3C6EF35F) & 0xFFFFFFFF;
    return _state;
  }

  /// A non-zero u32 (Shamir coefficients avoid 0 so the polynomial stays degree
  /// t-1; matches the Python reference's randrange(1, 1<<32)).
  int nextU32NonZero() {
    int v = _nextU32();
    while (v == 0) {
      v = _nextU32();
    }
    return v;
  }
}
