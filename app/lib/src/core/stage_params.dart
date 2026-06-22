import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// One chained stage's perturbation reservoirs `(o, p, q)`.
///
/// Under the chained protocol, stage `k`'s fractal is derived from *all
/// preceding points*: `(o, p, q) = derive(Argon2(bits of points 0..k-1))`.
/// Each is a raw 64-bit entropy reservoir that the engine decodes into a
/// complex perturbation; together they select that stage's personal fractal
/// (ARCHITECTURE.md §"perturbed fractal"). Stage 0 is the canonical fractal and
/// has no reservoirs (`(0, 0, 0)`).
///
/// These exist only as ephemeral state during a rendering session. They are
/// never persisted and never displayed to the user (the redacted [toString]
/// enforces the "no logs of fractal coordinates / (o,p,q)" invariant in
/// TECH_STACK.md). [clear] zeroes the values when the session ends.
class StageReservoirs {
  StageReservoirs({required this.o, required this.p, required this.q});

  int o;
  int p;
  int q;

  /// Derive `(o, p, q)` from a 32-byte Argon2 digest.
  ///
  /// Faithful port of `derive_stage2_params` in
  /// great-wall-core/burning_ship/argon2_pipeline.py (the per-stage parameter
  /// attribution is unchanged under the chained protocol):
  ///
  ///   h = sha256(digest)
  ///   o = u64_be(h[0:8]);  p = u64_be(h[8:16]);  q = u64_be(h[16:24])
  factory StageReservoirs.fromArgon2Digest(Uint8List digest) {
    final List<int> h = sha256.convert(digest).bytes;
    final ByteData bd = ByteData.sublistView(Uint8List.fromList(h));
    return StageReservoirs(
      o: bd.getUint64(0, Endian.big),
      p: bd.getUint64(8, Endian.big),
      q: bd.getUint64(16, Endian.big),
    );
  }

  /// Zero the reservoirs once the session no longer needs them.
  void clear() {
    o = 0;
    p = 0;
    q = 0;
  }

  /// A non-secret, monotone-ish key used purely to drive canvas repaints when
  /// the reservoirs change. It is a low-resolution display proxy, NOT the
  /// reservoirs themselves — see [StageReservoirs] docs and
  /// core_escape_count_source.dart for why the authoritative `u64`s never ride
  /// great-wall-ux's `StageParameters` (which carries `double`s).
  ({double o, double p, double q}) get displayKey => (
        o: decodeDisplayReservoir(o, minExp: 3),
        p: decodeDisplayReservoir(p, minExp: 4, baselineExp: 3),
        q: decodeDisplayReservoir(q, minExp: 5),
      );

  /// `toString` is intentionally redacted — `(o, p, q)` is session-only
  /// material that must not leak into logs.
  @override
  String toString() => 'StageReservoirs(<redacted>)';
}

/// Decode the real component of an entropy reservoir into a magnitude, for the
/// display proxy only. Mirrors the `decode_*_display` Re branch in
/// argon2_pipeline.py: 31 magnitude bits from bit `minExp`, plus an optional
/// baseline `2^-baselineExp` (only `p` carries one).
///
/// This is display-grade math (used to detect "did the reservoirs change?"),
/// not the engine's perturbation math, which runs in Rust over the raw `u64`.
double decodeDisplayReservoir(int reservoir, {required int minExp, int? baselineExp}) {
  const int magnitudeBits = 31;
  double mag = 0;
  for (int j = 0; j < magnitudeBits; j++) {
    if ((reservoir & (1 << j)) != 0) {
      mag += _pow2(-(minExp + j));
    }
  }
  if (baselineExp != null) mag += _pow2(-baselineExp);
  final bool negative = (reservoir & (1 << 31)) != 0; // sign bit for Re
  return negative ? -mag : mag;
}

double _pow2(int e) {
  // Exact powers of two without importing dart:math just for `pow`.
  if (e >= 0) return (1 << e).toDouble();
  return 1.0 / (1 << -e);
}
