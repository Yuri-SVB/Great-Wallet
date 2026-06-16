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

  /// Bits encoded per fractal point.
  static const int bitsPerPoint = 32;

  /// Stage-1 perturbation reservoirs: all zero yields the canonical Burning
  /// Ship formula (z0 = 0, additive shift only the baseline, no linear term).
  static const int stage1O = 0;
  static const int stage1P = 0;
  static const int stage1Q = 0;

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
}

/// A wallet size preset (constants.py: `SIZE_PRESETS`). Determines how many
/// points the user memorises per stage and the resulting entropy width.
enum SizePreset {
  mini(pointsPerStage: 1, entropyBits: 64, bip39Words: 6),
  defaultPreset(pointsPerStage: 2, entropyBits: 128, bip39Words: 12),
  large(pointsPerStage: 4, entropyBits: 256, bip39Words: 24);

  const SizePreset({
    required this.pointsPerStage,
    required this.entropyBits,
    required this.bip39Words,
  });

  /// Points the user identifies per stage (stage 1 and stage 2 each).
  final int pointsPerStage;

  /// Total raw entropy width (stage-1 || stage-2 bits).
  final int entropyBits;

  /// Equivalent BIP39 word count (the wire format the user never sees).
  final int bip39Words;

  /// Bits encoded in one stage = `pointsPerStage * bitsPerPoint`. By
  /// construction this is `entropyBits / 2`.
  int get bitsPerStage => pointsPerStage * EncodingConstants.bitsPerPoint;
}
