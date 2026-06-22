/// App-side protocol constants.
///
/// The values that determine encode/decode *output* — the discovery params and
/// the encode area — are NOT kept here: they are read from the engine at
/// runtime ([GreatWallCore.encodeParams] / [GreatWallCore.encodeArea], backed
/// by `bs_encode_params` / `bs_encode_area`), because the engine alone dictates
/// the protocol. A hand-mirrored copy is exactly what drifted before (the
/// wallet held `maxIter = 64` while the protocol moved to 1024, stalling
/// deep-zoom encodes).
///
/// What remains here is structural — values used in compile-time `const`
/// contexts that the engine still validates at startup (see
/// [GreatWallCore]'s bits-per-point check).
class EncodingConstants {
  EncodingConstants._();

  /// Bits encoded per fractal point — and, under the chained protocol, per
  /// stage (one point = one stage = one 32-bit chunk). The engine
  /// (`bs_bits_per_point`) is the authority; [GreatWallCore] asserts this
  /// matches it on open, so a stale value fails loudly instead of mis-encoding.
  static const int bitsPerPoint = 32;

  /// The all-zero perturbation reservoirs that yield the pure canonical Burning
  /// Ship formula. The chained wallet flow no longer uses a canonical fractal
  /// (Stage 0 is text; every fractal is chain-derived), so these are retained
  /// only as the engine's `(0,0,0)` baseline for non-chained / viewer use.
  static const int canonicalO = 0;
  static const int canonicalP = 0;
  static const int canonicalQ = 0;

  /// Escape-iteration cap for *rendering* the fractal canvas (constants.py:
  /// `DEFAULT_MAX_ITER`). This is a purely visual knob — it colours pixels and
  /// does not affect which bits a point encodes to — so it is deliberately
  /// decoupled from, and far smaller than, the engine's encode/decode cap
  /// (`encodeParams.maxIter`, 1024). It is not a determinism-critical protocol
  /// value, so it stays app-side.
  static const int renderMaxIter = 64;

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
