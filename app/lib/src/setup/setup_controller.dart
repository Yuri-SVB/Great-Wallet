import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/bip39.dart';
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
  recallComplete, // both stages selected back; seed reconstructed
  error,
}

/// Outcome of a select-mode click.
enum SelectionOutcome {
  /// The click did not land on an encodable leaf.
  invalid,

  /// A point was added to the current stage's selection.
  added,

  /// The click decoded to a point already selected this stage.
  duplicate,

  /// Stage 1's points are all selected; `(o, p, q)` was derived and stage 2
  /// is now displayed.
  advancedToStage2,

  /// Both stages selected; the seed has been reconstructed.
  complete,

  /// A derivation is in progress; the click was ignored.
  busy,
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

  Argon2Job? _argon2Job;

  // --- Select-mode recall state ---
  // Marks (canvas coords) of points selected this stage, and their decoded
  // 32-bit chunks. Coercion-relevant: held only for the session, wiped on reset.
  final List<({double re, double im})> _selectedMarks =
      <({double re, double im})>[];
  final List<List<int>> _selectedChunks = <List<int>>[];
  List<int> _recalledStage1Bits = const <int>[];
  List<int>? _recalledEntropyBits;

  /// Points selected so far in the current stage.
  int get selectedCount => _selectedMarks.length;

  /// Points required per stage for the active size preset.
  int get requiredPerStage => _preset.pointsPerStage;

  /// True once both stages have been selected back and the seed reconstructed.
  bool get isRecallComplete => _recalledEntropyBits != null;

  /// The reconstructed seed as a BIP39 mnemonic, for an explicit
  /// user-initiated **blind** export (copy → paste into another wallet's
  /// import wizard without reading it). Returns null until recall is complete.
  ///
  /// "The user never sees the seed" holds in the blind-copy sense: this string
  /// is handed to the clipboard, never rendered on screen (ARCHITECTURE.md
  /// §"Stage 0" / §"Invariants"). It is computed on demand and not retained.
  String? exportMnemonic() {
    final List<int>? bits = _recalledEntropyBits;
    if (bits == null) return null;
    return Bip39.entropyBitsToMnemonic(bits);
  }

  /// `SHA-512(seed-phrase + salt)` as hex, for target apps that accept a
  /// non-BIP39 high-entropy seed. The descriptive [salt] domain-separates one
  /// setup from another, and the 128-hex-char digest is far harder to memorise
  /// from a stray glance than the word list. Returns null until recall is
  /// complete. Mirrors great-wall-core's standalone "Salt & SHA512" button.
  String? exportSaltedDigest(String salt) {
    final String? mnemonic = exportMnemonic();
    if (mnemonic == null) return null;
    return Bip39.saltedDigestHex(mnemonic, salt);
  }

  /// The point markers to overlay for the currently displayed stage. These are
  /// the locations the user must learn to recognise — the only thing they leave
  /// Setup with (as tacit recall, never written down).
  CanvasOverlays overlaysForDisplayStage() {
    final List<EncodedPoint> pts =
        _displayStage == Stage.stage1 ? _stage1Points : _stage2Points;
    return CanvasOverlays(
      points: <PointMarker>[
        // Generated points to memorise (white).
        for (final EncodedPoint pt in pts)
          PointMarker(
            re: fixedToDouble(pt.reRaw),
            im: fixedToDouble(pt.imRaw),
            colour: const Color(0xFFFFFFFF),
            radiusPx: 6,
          ),
        // Points selected this stage in select mode (green).
        for (final ({double re, double im}) m in _selectedMarks)
          PointMarker(
            re: m.re,
            im: m.im,
            colour: const Color(0xFF00E676),
            radiusPx: 7,
          ),
      ],
      // No crosshairs: a centre cross adds nothing here and reads as a stray
      // marker over the fractal.
      crosshairs: false,
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
    _errorMessage = null;
    _clearSelection();
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
      final Argon2Job job = await _core.startStage2Derivation(
        stage1Bits,
        iterations: argon2Iterations,
        profile: profile,
        onProgress: (int done, int total) {
          _argon2Done = done;
          _argon2Total = total;
          notifyListeners();
        },
      );
      _argon2Job = job;
      final Stage2Reservoirs reservoirs = await job.result;
      _argon2Job = null;
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

  /// Cancel an in-progress Argon2 derivation. Kills the worker isolate and
  /// fails the derivation with [Argon2Cancelled], returning the UI to idle.
  void requestStop() {
    _argon2Job?.cancel();
    _argon2Job = null;
  }

  /// Discard the current session and return to the configuration screen,
  /// wiping any in-memory secrets. Safe to call at any time.
  void reset() {
    _argon2Job?.cancel();
    _argon2Job = null;
    _resetSecrets();
    _errorMessage = null;
    _displayStage = Stage.stage1;
    _argon2Done = 0;
    _setPhase(SetupPhase.idle);
  }

  /// Handle a select-mode click: decode the point under the cursor, add it to
  /// the current stage's selection, and advance when the stage is complete.
  ///
  /// This is the click-to-decode recall workflow (SCOPE.md §"Interaction"):
  ///  - Stage 1 points decode on the canonical fractal `(0,0,0)`.
  ///  - When `requiredPerStage` stage-1 points are selected, their bits are run
  ///    through Argon2 to derive `(o, p, q)`; the perturbed stage-2 fractal is
  ///    then displayed and selection resets.
  ///  - Stage 2 points decode under those reservoirs; once complete, the full
  ///    entropy (`stage1 || stage2`) is reconstructed.
  ///
  /// Decoded bits and coordinates stay inside the session and are never logged
  /// (SCOPE.md invariants).
  Future<SelectionOutcome> selectPoint(
    FractalSelection selection, {
    required SizePreset preset,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase == SetupPhase.derivingParams ||
        _phase == SetupPhase.recallComplete) {
      return SelectionOutcome.busy;
    }
    _preset = preset;
    final Stage2Reservoirs? r = _core.source.stage2Reservoirs;
    final bool s2 = _displayStage == Stage.stage2;
    if (s2 && r == null) return SelectionOutcome.busy;

    final CoreDecodeResult result = _core.decodePoint(
      reRaw: fixedFromDouble(selection.re),
      imRaw: fixedFromDouble(selection.im),
      o: s2 ? r!.o : EncodingConstants.stage1O,
      p: s2 ? r!.p : EncodingConstants.stage1P,
      q: s2 ? r!.q : EncodingConstants.stage1Q,
    );
    if (!result.valid) return SelectionOutcome.invalid;

    // Clicking the same leaf again should not double-count it.
    for (final List<int> chunk in _selectedChunks) {
      if (_sameBits(chunk, result.bits)) return SelectionOutcome.duplicate;
    }

    _selectedMarks.add((re: selection.re, im: selection.im));
    _selectedChunks.add(result.bits);
    notifyListeners();

    if (_selectedMarks.length < requiredPerStage) {
      return SelectionOutcome.added;
    }

    // Stage complete: assemble this stage's bits in selection order.
    final List<int> stageBits = <int>[
      for (final List<int> chunk in _selectedChunks) ...chunk,
    ];

    if (!s2) {
      // Stage 1 done: derive (o, p, q) and reveal stage 2.
      _recalledStage1Bits = stageBits;
      try {
        _setPhase(SetupPhase.derivingParams);
        _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
        _argon2Done = 0;
        final Argon2Job job = await _core.startStage2Derivation(
          stageBits,
          iterations: argon2Iterations,
          profile: profile,
          onProgress: (int done, int total) {
            _argon2Done = done;
            _argon2Total = total;
            notifyListeners();
          },
        );
        _argon2Job = job;
        final Stage2Reservoirs reservoirs = await job.result;
        _argon2Job = null;
        _core.source.stage2Reservoirs = reservoirs;
        final ({double o, double p, double q}) key = reservoirs.displayKey;
        _stage2Params = StageParameters(o: key.o, p: key.p, q: key.q);
        _displayStage = Stage.stage2;
        _clearSelection();
        _setPhase(SetupPhase.memorise);
        return SelectionOutcome.advancedToStage2;
      } on Argon2Cancelled {
        _setPhase(SetupPhase.memorise);
        return SelectionOutcome.busy;
      }
    }

    // Stage 2 done: reconstruct full entropy.
    _recalledEntropyBits = <int>[..._recalledStage1Bits, ...stageBits];
    _clearSelection();
    _setPhase(SetupPhase.recallComplete);
    return SelectionOutcome.complete;
  }

  /// Clear the current stage's selection (markers + decoded chunks).
  void clearSelection() {
    if (_selectedMarks.isEmpty) return;
    _clearSelection();
    notifyListeners();
  }

  void _clearSelection() {
    for (final List<int> chunk in _selectedChunks) {
      Entropy.wipe(chunk);
    }
    _selectedMarks.clear();
    _selectedChunks.clear();
  }

  static bool _sameBits(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
    _clearSelection();
    if (_recalledStage1Bits.isNotEmpty) Entropy.wipe(_recalledStage1Bits);
    _recalledStage1Bits = const <int>[];
    final List<int>? rec = _recalledEntropyBits;
    if (rec != null) Entropy.wipe(rec);
    _recalledEntropyBits = null;
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
