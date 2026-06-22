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

  /// Canonical (stage-0) perturbation reservoirs: all zero yields the canonical
  /// Burning Ship formula. Stage 0 is the public, shared fractal; every later
  /// stage's `(o, p, q)` is chain-derived from all preceding points
  /// (protocol.py: `CANONICAL_O/P/Q`).
  static const int canonicalO = 0;
  static const int canonicalP = 0;
  static const int canonicalQ = 0;

  /// The encoding area — the BS region where island density supports 32-bit
  /// encoding: `[-2.5, 1.5] x [-2.0, 1.5]` (constants.py: `ENCODE_AREA`).
  static FixedRect encodeArea() =>
      FixedRect.fromDoubles(-2.5, 1.5, -2.0, 1.5);

  /// GUI discovery params (constants.py: `GUI_PARAMS`) — the presets the
  /// reference viewer encodes with.
  static const CoreDiscoveryParams guiParams = CoreDiscoveryParams(
    maxIter: 64,
    targetGood: 32,
    maxFloodPoints: 256,
    minGridCells: 1024 * 1024,
    pMaxShift: 3,
    exclusionThresholdNum: 1023,
    rngSeed: 0x42,
  );

  /// Number of chained stages for an entropy width: one 32-bit point per stage
  /// (protocol.py: `n_stages_for`, `n_stages = entropy_bits / BITS_PER_POINT`).
  static int nStagesFor(int entropyBits) => entropyBits ~/ bitsPerPoint;
}

/// A wallet size preset (constants.py: `SIZE_PRESETS`). Under the chained
/// protocol each stage encodes exactly one 32-bit point, so the entropy width
/// fixes the number of stages: `nStages = entropyBits / 32`. Stage 0 is the
/// public canonical fractal; the remaining `nStages - 1` are secret,
/// chain-derived fractals the user learns to recognise.
enum SizePreset {
  mini(entropyBits: 64, bip39Words: 6),
  defaultPreset(entropyBits: 128, bip39Words: 12),
  large(entropyBits: 256, bip39Words: 24);

  const SizePreset({
    required this.entropyBits,
    required this.bip39Words,
  });

  /// Total raw entropy width (the concatenation of every stage's 32 bits).
  final int entropyBits;

  /// Equivalent BIP39 word count (the wire format the user never sees).
  final int bip39Words;

  /// Number of chained stages (one 32-bit point each). The first is the public
  /// canonical fractal; the rest are secret, chain-derived haystacks.
  int get nStages => EncodingConstants.nStagesFor(entropyBits);
}
