import '../ffi/core_bindings.dart';

/// Protocol constants shared by the encode/decode paths, mirrored from
/// great-wall-core/burning_ship/constants.py so app-side encodes round-trip
/// bit-for-bit with the reference engine.
///
/// These are *protocol* values, not preferences: changing any of them changes
/// which fractal location a given bit-chunk maps to and would invalidate
/// existing encodings (ARCHITECTURE.md §"Determinism guarantees").
class EncodingConstants {
  EncodingConstants._();

  /// Bits encoded per fractal point — and, under the chained protocol, per
  /// stage (one point = one stage = one 32-bit chunk).
  static const int bitsPerPoint = 32;

  /// The all-zero perturbation reservoirs that yield the pure canonical Burning
  /// Ship formula. The chained wallet flow no longer uses a canonical fractal
  /// (Stage 0 is text; every fractal is chain-derived), so these are retained
  /// only as the engine's `(0,0,0)` baseline for non-chained / viewer use.
  static const int canonicalO = 0;
  static const int canonicalP = 0;
  static const int canonicalQ = 0;

  /// The encoding area — the BS region where island density supports 32-bit
  /// encoding: `[-2.5, 1.5] x [-2.0, 1.5]` (constants.py: `ENCODE_AREA`).
  static FixedRect encodeArea() =>
      FixedRect.fromDoubles(-2.5, 1.5, -2.0, 1.5);

  /// Escape-iteration cap for ENCODE/DECODE island discovery (constants.py:
  /// `ENCODE_MAX_ITER`). Intentionally decoupled from — and much larger than —
  /// the render cap (64): as the bisection tree zooms toward the Burning Ship
  /// set boundary, escape counts climb toward the cap, and a low cap (64) makes
  /// almost every sample read as "non-escaping", starving island discovery —
  /// deep levels then burn 100k+ samples and the encode effectively stalls
  /// (the default vanity phrase + "MAIN-STASH" + N=1 freeze at Stage 2). 1024
  /// (the engine's own DiscoveryParams default) keeps boundary-adjacent points
  /// escaping so discovery stays fast at every level; escape_count
  /// short-circuits on escape, so the higher cap only costs extra work for the
  /// rare genuinely-non-escaping samples. Requires engine ENGINE_VERSION >=
  /// 0.2.0 (output-changing change; encode and decode share the cap so the
  /// bijection is preserved).
  static const int encodeMaxIter = 1024;

  /// GUI discovery params (constants.py: `GUI_PARAMS`) — the presets the
  /// reference viewer encodes with.
  static const CoreDiscoveryParams guiParams = CoreDiscoveryParams(
    maxIter: encodeMaxIter,
    targetGood: 32,
    maxFloodPoints: 256,
    minGridCells: 1024 * 1024,
    pMaxShift: 3,
    exclusionThresholdNum: 1023,
    rngSeed: 0x42,
  );

  /// Number of fractal point stages for an entropy width: one 32-bit point per
  /// fractal (`entropy_bits / BITS_PER_POINT`). The text Stage 0 is separate and
  /// not counted here.
  static int nStagesFor(int entropyBits) => entropyBits ~/ bitsPerPoint;
}

/// A wallet size preset (constants.py: `SIZE_PRESETS`). Each fractal stage
/// encodes exactly one 32-bit point, so the entropy width fixes the number of
/// fractal point stages: `nStages = entropyBits / 32`. (The chain also has a
/// text Stage 0 that seeds the fractals but carries no point and no entropy.)
enum SizePreset {
  mini(entropyBits: 64, bip39Words: 6),
  defaultPreset(entropyBits: 128, bip39Words: 12),
  large(entropyBits: 256, bip39Words: 24);

  const SizePreset({
    required this.entropyBits,
    required this.bip39Words,
  });

  /// Total raw entropy width (the concatenation of every fractal's 32 bits).
  final int entropyBits;

  /// Equivalent BIP39 word count (the wire format the user never sees).
  final int bip39Words;

  /// Number of fractal point stages (one 32-bit point each), i.e. the secret,
  /// chain-derived haystacks. The setup flow adds one text Stage 0 on top.
  int get nStages => EncodingConstants.nStagesFor(entropyBits);
}
