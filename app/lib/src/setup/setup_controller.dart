import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/encoding_constants.dart';
import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import '../core/stage2_params.dart';

/// Phases of the Setup flow.
///
/// Setup is "a write-only operation on the user's memory" (ARCHITECTURE.md
/// §"Invariants"): generate a fresh root, encode it onto the two-stage fractal,
/// let the user memorise the points, then destroy the plaintext.
enum SetupPhase {
  idle,
  encodingStage1,
  derivingParams, // Argon2: stage-1 bits -> (o, p, q)
  encodingStage2,
  memorise, // user studies stage-1 then stage-2 points
  complete,
  error,
}

/// Drives the Setup mode and owns the integration between great-wall-core
/// (encode / Argon2) and great-wall-ux (the canvas + overlays).
///
/// SECURITY: the generated entropy and the encoded points are coercion-relevant.
/// They are held only for the duration of the memorisation phase and wiped by
/// [finish]/[dispose]. Nothing here is logged or persisted (SCOPE.md invariants).
class SetupController extends ChangeNotifier {
  SetupController(this._core);

  final GreatWallCore _core;

  SetupPhase _phase = SetupPhase.idle;
  SetupPhase get phase => _phase;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  SizePreset _preset = SizePreset.defaultPreset;
  SizePreset get preset => _preset;

  /// Which stage the canvas is currently showing during memorisation.
  Stage _displayStage = Stage.stage1;
  Stage get displayStage => _displayStage;

  int _argon2Done = 0;
  int _argon2Total = 1;
  int get argon2Done => _argon2Done;
  int get argon2Total => _argon2Total;

  // Session-only secret material.
  List<int>? _entropyBits;
  List<EncodedPoint> _stage1Points = const <EncodedPoint>[];
  List<EncodedPoint> _stage2Points = const <EncodedPoint>[];
  StageParameters? _stage2Params;

  /// Stage-2 perturbation parameters as great-wall-ux's display surrogate.
  /// The authoritative reservoirs live on [GreatWallCore.source]; see
  /// CoreEscapeCountSource.stage2Reservoirs.
  StageParameters? get stage2Params => _stage2Params;

  bool _stopRequested = false;

  /// The point markers to overlay for the currently displayed stage. These are
  /// the locations the user must learn to recognise — the only thing they leave
  /// Setup with (as tacit recall, never written down).
  CanvasOverlays overlaysForDisplayStage() {
    final List<EncodedPoint> pts =
        _displayStage == Stage.stage1 ? _stage1Points : _stage2Points;
    return CanvasOverlays(
      points: <PointMarker>[
        for (final EncodedPoint pt in pts)
          PointMarker(
            re: fixedToDouble(pt.reRaw),
            im: fixedToDouble(pt.imRaw),
            colour: const Color(0xFFFFFFFF),
            radiusPx: 6,
          ),
      ],
      crosshairs: true,
    );
  }

  /// Run the full Setup pipeline: generate entropy, encode stage 1, derive
  /// `(o, p, q)` via Argon2, encode stage 2, then enter the memorise phase.
  Future<void> begin({
    required SizePreset preset,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase != SetupPhase.idle &&
        _phase != SetupPhase.complete &&
        _phase != SetupPhase.error) {
      return; // a run is already in progress
    }
    _preset = preset;
    _stopRequested = false;
    _errorMessage = null;
    try {
      // 1. Fresh entropy root (write-only on memory).
      final List<int> bits = Entropy.randomBits(preset.entropyBits);
      _entropyBits = bits;
      final int bps = preset.bitsPerStage;
      final List<int> stage1Bits = bits.sublist(0, bps);
      final List<int> stage2Bits = bits.sublist(bps);

      // 2. Encode stage 1 on the canonical fractal.
      _setPhase(SetupPhase.encodingStage1);
      _stage1Points = _core.encodeStage(
        stage1Bits,
        o: EncodingConstants.stage1O,
        p: EncodingConstants.stage1P,
        q: EncodingConstants.stage1Q,
      );
      _displayStage = Stage.stage1;
      notifyListeners();

      // 3. Argon2: stage-1 bits -> (o, p, q).
      _setPhase(SetupPhase.derivingParams);
      _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
      _argon2Done = 0;
      final Stage2Reservoirs reservoirs = await _core.deriveStage2Reservoirs(
        stage1Bits,
        iterations: argon2Iterations,
        profile: profile,
        onProgress: (int done, int total) {
          _argon2Done = done;
          _argon2Total = total;
          notifyListeners();
        },
        shouldStop: () => _stopRequested,
      );
      // Hand the authoritative reservoirs to the render source and build the
      // UX-facing display surrogate.
      _core.source.stage2Reservoirs = reservoirs;
      final ({double o, double p, double q}) key = reservoirs.displayKey;
      _stage2Params = StageParameters(o: key.o, p: key.p, q: key.q);

      // 4. Encode stage 2 on the perturbed fractal.
      _setPhase(SetupPhase.encodingStage2);
      _stage2Points = _core.encodeStage(
        stage2Bits,
        o: reservoirs.o,
        p: reservoirs.p,
        q: reservoirs.q,
      );

      // 5. Memorise. Plaintext entropy is no longer needed once it lives on
      // the fractal as points — wipe it; keep only the points to display.
      Entropy.wipe(stage1Bits);
      Entropy.wipe(stage2Bits);
      Entropy.wipe(bits);
      _entropyBits = null;

      _setPhase(SetupPhase.memorise);
    } on Argon2Cancelled {
      _resetSecrets();
      _setPhase(SetupPhase.idle);
    } catch (e) {
      _resetSecrets();
      // Error text is deliberately generic — never include coordinates/bits.
      _errorMessage = 'Setup failed: ${e.runtimeType}';
      _setPhase(SetupPhase.error);
    }
  }

  /// Cancel an in-progress Argon2 derivation (polled between passes).
  void requestStop() {
    _stopRequested = true;
  }

  /// Decode the point under a select-mode tap and report whether it landed on
  /// a valid encodable leaf. Uses the currently displayed stage's `(o, p, q)`:
  /// `(0,0,0)` for stage 1, the session reservoirs for stage 2 — the same
  /// formula the points were encoded with.
  ///
  /// The boolean is all that surfaces; the decoded bits and coordinates stay
  /// inside the engine call and are never logged (SCOPE.md invariants).
  bool probeSelection(FractalSelection selection) {
    final Stage2Reservoirs? r = _core.source.stage2Reservoirs;
    final bool s2 = _displayStage == Stage.stage2;
    final CoreDecodeResult result = _core.decodePoint(
      reRaw: fixedFromDouble(selection.re),
      imRaw: fixedFromDouble(selection.im),
      o: s2 ? (r?.o ?? 0) : EncodingConstants.stage1O,
      p: s2 ? (r?.p ?? 0) : EncodingConstants.stage1P,
      q: s2 ? (r?.q ?? 0) : EncodingConstants.stage1Q,
    );
    return result.valid;
  }

  /// Switch the displayed stage during memorisation.
  void showStage(Stage stage) {
    if (stage == _displayStage) return;
    if (stage == Stage.stage2 && _core.source.stage2Reservoirs == null) return;
    _displayStage = stage;
    notifyListeners();
  }

  /// Finish Setup and wipe all session secrets. Call when leaving the flow
  /// (the user has committed the points to memory).
  void finish() {
    _resetSecrets();
    _setPhase(SetupPhase.complete);
  }

  void _resetSecrets() {
    final List<int>? bits = _entropyBits;
    if (bits != null) Entropy.wipe(bits);
    _entropyBits = null;
    _stage1Points = const <EncodedPoint>[];
    _stage2Points = const <EncodedPoint>[];
    _stage2Params = null;
    _core.source.stage2Reservoirs?.clear();
    _core.source.stage2Reservoirs = null;
  }

  void _setPhase(SetupPhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _resetSecrets();
    super.dispose();
  }
}
