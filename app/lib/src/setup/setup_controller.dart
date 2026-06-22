import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/bip39.dart';
import '../core/encoding_constants.dart';
import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import '../core/stage_params.dart';

/// Phases of the Setup flow.
///
/// Setup is "a write-only operation on the user's memory" (ARCHITECTURE.md
/// §"Invariants"): generate a fresh root, encode it onto the chained fractals
/// (one 32-bit point per stage), let the user memorise the points, then destroy
/// the plaintext.
enum SetupPhase {
  idle,

  /// Encoding the current stage's single point onto its fractal (quick).
  encoding,

  /// Running the chained Argon2 derivation that forms the current stage's
  /// fractal from all preceding points (the wall-clock cost).
  deriving,

  /// The user studies the points stage by stage.
  memorise,
  complete,

  /// Every stage selected back; the seed has been reconstructed.
  recallComplete,
  error,
}

/// Outcome of a select-mode click.
enum SelectionOutcome {
  /// The click did not land on an encodable leaf.
  invalid,

  /// This stage's point was decoded and the chain advanced to the next stage.
  advancedStage,

  /// The final stage was selected; the seed has been reconstructed.
  complete,

  /// A derivation is in progress, or the click was out of order; ignored.
  busy,
}

/// Drives the Setup mode and owns the integration between great-wall-core
/// (encode / chained Argon2) and great-wall-ux (the canvas + overlays).
///
/// Implements the **chained protocol** (great-wall-core/burning_ship/
/// protocol.py): the entropy root is split into `nStages` 32-bit chunks, one
/// per stage. Stage 0 is the public canonical fractal `(0,0,0)`; every later
/// stage's fractal `(o,p,q)` is the memory-hard hash of *all preceding points*
/// (`θ_k = SHA-256(Argon2^N(points 0..k-1))`). One stage = one fractal = one
/// haystack; one point = one needle.
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

  /// Number of chained stages for the active preset (one 32-bit point each).
  int get nStages => _preset.nStages;

  /// Which stage the canvas is currently showing (0 = canonical first fractal).
  int _displayStageIndex = 0;
  int get displayStageIndex => _displayStageIndex;

  /// The currently displayed stage mapped onto great-wall-ux's two render
  /// paths: stage 0 is the canonical fractal, every later chained stage is a
  /// perturbation rendered through the same `(o,p,q)` path.
  Stage get displayStage =>
      _displayStageIndex == 0 ? Stage.stage1 : Stage.stage2;

  /// The stage being derived/encoded right now, for progress labels (0-based).
  int _workingStageIndex = 0;
  int get workingStageNumber => _workingStageIndex + 1; // 1-based for display

  int _argon2Done = 0;
  int _argon2Total = 1;
  int get argon2Done => _argon2Done;
  int get argon2Total => _argon2Total;

  // Session-only secret material.
  List<int>? _entropyBits;

  /// One encoded point per stage (index 0 = canonical stage). `null` until that
  /// stage has been encoded.
  List<EncodedPoint?> _points = const <EncodedPoint?>[];

  /// One stage's chain-derived reservoirs per stage; index 0 is the canonical
  /// stage and is always `null` (`(0,0,0)`).
  List<StageReservoirs?> _reservoirs = const <StageReservoirs?>[];

  /// The displayed stage's perturbation as great-wall-ux's display surrogate
  /// (`null` for the canonical stage). The authoritative reservoirs live on
  /// [GreatWallCore.source]; see CoreEscapeCountSource.reservoirs.
  StageParameters? _displayParams;
  StageParameters? get displayStageParams => _displayParams;

  Argon2Job? _argon2Job;

  // --- Select-mode recall state ---
  // The point selected on the stage being recalled (coercion-relevant; held
  // only for the session). With one point per stage, selecting it advances the
  // chain immediately, so this is only kept to mark the final stage's choice.
  ({double re, double im})? _selectedMark;

  // The 32-bit chunks decoded back so far, one per recalled stage, in order.
  final List<List<int>> _recalledChunks = <List<int>>[];
  List<int>? _recalledEntropyBits;

  /// The stage the next select-mode click should recall = number of stages
  /// already recalled (0 at the start of a recall walk).
  int get recallStageIndex => _recalledChunks.length;

  /// Points selected on the stage currently being recalled (0 or 1).
  int get selectedCount => _selectedMark == null ? 0 : 1;

  /// Points required to complete a stage — always one under the chained
  /// protocol (one point = one stage).
  int get requiredPerStage => 1;

  /// True once every stage has been selected back and the seed reconstructed.
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

  /// The point markers to overlay for the currently displayed stage: the single
  /// location the user must learn to recognise (white), plus the point selected
  /// on this stage in select mode (green).
  CanvasOverlays overlaysForDisplayStage() {
    final EncodedPoint? pt = _displayStageIndex < _points.length
        ? _points[_displayStageIndex]
        : null;
    return CanvasOverlays(
      points: <PointMarker>[
        if (pt != null)
          PointMarker(
            re: fixedToDouble(pt.reRaw),
            im: fixedToDouble(pt.imRaw),
            colour: const Color(0xFFFFFFFF),
            radiusPx: 6,
          ),
        if (_selectedMark != null)
          PointMarker(
            re: _selectedMark!.re,
            im: _selectedMark!.im,
            colour: const Color(0xFF00E676),
            radiusPx: 7,
          ),
      ],
      // No crosshairs: a centre cross adds nothing here and reads as a stray
      // marker over the fractal.
      crosshairs: false,
    );
  }

  /// Run the full chained Setup pipeline: generate entropy, then for each stage
  /// derive its fractal from all preceding points (stage 0 is canonical, no
  /// derivation) and encode that stage's single 32-bit point, before entering
  /// the memorise phase.
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
    _clearRecall();
    final int n = preset.nStages;
    try {
      // 1. Fresh entropy root (write-only on memory).
      final List<int> bits = Entropy.randomBits(preset.entropyBits);
      _entropyBits = bits;
      _points = List<EncodedPoint?>.filled(n, null);
      _reservoirs = List<StageReservoirs?>.filled(n, null);

      const int bpp = EncodingConstants.bitsPerPoint;
      for (int k = 0; k < n; k++) {
        _workingStageIndex = k;
        final int o;
        final int p;
        final int q;
        if (k == 0) {
          // Stage 0: the public canonical fractal — no derivation.
          o = EncodingConstants.canonicalO;
          p = EncodingConstants.canonicalP;
          q = EncodingConstants.canonicalQ;
        } else {
          // Stage k: derive (o, p, q) from the cumulative bits of all preceding
          // points (0..k-1) — one link of the memory-hard chain.
          final List<int> priorBits = bits.sublist(0, k * bpp);
          _setPhase(SetupPhase.deriving);
          _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
          _argon2Done = 0;
          final Argon2Job job = await _core.startStageDerivation(
            priorBits,
            iterations: argon2Iterations,
            profile: profile,
            onProgress: (int done, int total) {
              _argon2Done = done;
              _argon2Total = total;
              notifyListeners();
            },
          );
          _argon2Job = job;
          final StageReservoirs reservoirs = await job.result;
          _argon2Job = null;
          Entropy.wipe(priorBits);
          _reservoirs[k] = reservoirs;
          o = reservoirs.o;
          p = reservoirs.p;
          q = reservoirs.q;
        }

        // Encode this stage's single 32-bit point on its fractal.
        _setPhase(SetupPhase.encoding);
        final List<int> chunk = bits.sublist(k * bpp, (k + 1) * bpp);
        final List<EncodedPoint> pts =
            _core.encodeStage(chunk, o: o, p: p, q: q);
        _points[k] = pts.first;
        Entropy.wipe(chunk);
        notifyListeners();
      }

      // 2. Memorise. Plaintext entropy is no longer needed once it lives on the
      // fractals as points — wipe it; keep only the points to display.
      Entropy.wipe(bits);
      _entropyBits = null;

      // Land on stage 0 (the canonical fractal) for memorisation.
      _applyDisplayStage(0);
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

  /// Cancel an in-progress chained derivation. Kills the worker isolate and
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
    _displayStageIndex = 0;
    _argon2Done = 0;
    _setPhase(SetupPhase.idle);
  }

  /// Snap the canvas to the stage the recall walk is currently on. Called when
  /// the user enters select mode so the click always lands on the right fractal
  /// (the chain must be recalled in order).
  void showRecallStage() {
    final int target = recallStageIndex.clamp(0, nStages - 1);
    _applyDisplayStage(target);
    notifyListeners();
  }

  /// Handle a select-mode click: decode the point under the cursor on the stage
  /// currently shown, then walk the chain forward.
  ///
  /// The recall mirrors encoding: stage 0 decodes on the canonical fractal;
  /// each later stage decodes under the reservoirs derived during [begin] for
  /// that stage. Selecting a stage's one point advances to the next stage's
  /// fractal until the last stage completes and the full entropy
  /// (concatenated per-stage bits) is reconstructed.
  ///
  /// NOTE: this in-session memorise→recall check reuses the reservoirs already
  /// derived at [begin] (the costly chain ran once at "Generate"), so verifying
  /// memorisation does not force the user to wait out the whole chain again. A
  /// genuine cold recall on a fresh device — with no stored reservoirs — re-runs
  /// the memory-hard chain link by link, exactly as protocol.py decode does.
  ///
  /// Decoded bits and coordinates stay inside the session and are never logged
  /// (SCOPE.md invariants).
  SelectionOutcome selectPoint(
    FractalSelection selection, {
    required SizePreset preset,
  }) {
    if (_phase == SetupPhase.recallComplete) return SelectionOutcome.busy;
    _preset = preset;

    final int k = _displayStageIndex;
    // Recall must proceed in order: the displayed stage must be the next one to
    // recall. (Guards against decoding a browsed-ahead stage out of sequence.)
    if (k != recallStageIndex) return SelectionOutcome.busy;

    final StageReservoirs? r = k == 0 ? null : _reservoirs[k];
    if (k != 0 && r == null) return SelectionOutcome.busy;

    final CoreDecodeResult result = _core.decodePoint(
      reRaw: fixedFromDouble(selection.re),
      imRaw: fixedFromDouble(selection.im),
      o: r?.o ?? EncodingConstants.canonicalO,
      p: r?.p ?? EncodingConstants.canonicalP,
      q: r?.q ?? EncodingConstants.canonicalQ,
    );
    if (!result.valid) return SelectionOutcome.invalid;

    _selectedMark = (re: selection.re, im: selection.im);
    _recalledChunks.add(result.bits);

    if (k == nStages - 1) {
      // Final stage recalled: reconstruct the full entropy root.
      _recalledEntropyBits = <int>[
        for (final List<int> chunk in _recalledChunks) ...chunk,
      ];
      _setPhase(SetupPhase.recallComplete);
      return SelectionOutcome.complete;
    }

    // Advance to the next stage's fractal (its reservoirs are already derived).
    _selectedMark = null;
    _applyDisplayStage(k + 1);
    notifyListeners();
    return SelectionOutcome.advancedStage;
  }

  /// Clear the current stage's pending selection mark.
  void clearSelection() {
    if (_selectedMark == null) return;
    _selectedMark = null;
    notifyListeners();
  }

  /// Switch the displayed stage during memorisation. Only stages whose fractal
  /// is known (the canonical stage, or a stage already derived) can be shown.
  void showStage(int index) {
    if (index == _displayStageIndex) return;
    if (index < 0 || index >= nStages) return;
    if (index != 0 &&
        (index >= _reservoirs.length || _reservoirs[index] == null)) {
      return;
    }
    _applyDisplayStage(index);
    notifyListeners();
  }

  /// Point the canvas (and the render source) at [index]'s fractal: the
  /// canonical fractal for stage 0, otherwise that stage's chain-derived
  /// reservoirs. Does not notify; callers do.
  void _applyDisplayStage(int index) {
    _displayStageIndex = index;
    final StageReservoirs? res =
        index == 0 || index >= _reservoirs.length ? null : _reservoirs[index];
    _core.source.reservoirs = res;
    if (res == null) {
      _displayParams = null;
    } else {
      final ({double o, double p, double q}) key = res.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
    }
  }

  /// Finish Setup and wipe all session secrets. Call when leaving the flow
  /// (the user has committed the points to memory).
  void finish() {
    _resetSecrets();
    _setPhase(SetupPhase.complete);
  }

  void _clearRecall() {
    _selectedMark = null;
    for (final List<int> chunk in _recalledChunks) {
      Entropy.wipe(chunk);
    }
    _recalledChunks.clear();
    final List<int>? rec = _recalledEntropyBits;
    if (rec != null) Entropy.wipe(rec);
    _recalledEntropyBits = null;
  }

  void _resetSecrets() {
    final List<int>? bits = _entropyBits;
    if (bits != null) Entropy.wipe(bits);
    _entropyBits = null;
    _points = const <EncodedPoint?>[];
    for (final StageReservoirs? r in _reservoirs) {
      r?.clear();
    }
    _reservoirs = const <StageReservoirs?>[];
    _displayParams = null;
    _core.source.reservoirs?.clear();
    _core.source.reservoirs = null;
    _clearRecall();
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
