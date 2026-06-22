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

  /// Number of chained stages of the active session (one 32-bit point each).
  /// While a session is live this is the *actual* width — which, for an imported
  /// seed phrase, may be any 3..24-word size, not one of the presets — falling
  /// back to the configured preset before a session starts.
  int _stageCount = 0;
  int get nStages => _stageCount > 0 ? _stageCount : _preset.nStages;

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

  // The reservoirs for the stage currently being recalled (k >= 1), produced by
  // re-running the chained Argon2 derivation when the previous stage's point was
  // selected. `null` while recalling the canonical stage 0. This is distinct
  // from [_reservoirs] (the begin-time values used only for memorise browsing):
  // recall re-derives the chain link by link, exactly as protocol.py decode.
  StageReservoirs? _recallReservoirs;

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

  /// Stages recalled (decoded back) so far — equivalently, the number of
  /// 32-bit points making up the seed available for blind export right now.
  int get recalledStageCount => _recalledChunks.length;

  /// Bits available for blind export so far (`32 ×` [recalledStageCount]).
  int get recalledBitCount =>
      _recalledChunks.length * EncodingConstants.bitsPerPoint;

  /// Whether any seed material has been recalled (so a blind export is
  /// possible). Below the final stage this is a partial, shorter-than-standard
  /// seed; at completion it is the full entropy root.
  bool get canExport => _recalledChunks.isNotEmpty;

  /// The seed recalled **so far** as a BIP39 mnemonic, for an explicit
  /// user-initiated **blind** export (copy → paste into another wallet's
  /// import wizard without reading it). Available at every stage once at least
  /// one point has been recalled: before the final stage it encodes only the
  /// points decoded so far (`32 ×` stages bits — a non-standard, weaker seed);
  /// at completion it is the full entropy root. Returns null before any point
  /// is recalled.
  ///
  /// "The user never sees the seed" holds in the blind-copy sense: this string
  /// is handed to the clipboard, never rendered on screen (ARCHITECTURE.md
  /// §"Stage 0" / §"Invariants"). It is computed on demand and not retained.
  String? exportMnemonic() {
    if (_recalledChunks.isEmpty) return null;
    final List<int> bits = <int>[
      for (final List<int> chunk in _recalledChunks) ...chunk,
    ];
    final String mnemonic = Bip39.entropyBitsToMnemonic(bits);
    Entropy.wipe(bits);
    return mnemonic;
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

  /// Run the full chained Setup pipeline on a **freshly generated** entropy
  /// root of the configured [preset] size.
  Future<void> begin({
    required SizePreset preset,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    _preset = preset;
    return _encodeRoot(
      Entropy.randomBits(preset.entropyBits),
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// Run the chained Setup pipeline on an **imported BIP39 seed phrase** instead
  /// of fresh entropy. The phrase may be sub-standard (any 3..24 words → a
  /// matching number of stages). On an invalid phrase the controller enters the
  /// error phase with a generic message (the seed content is never echoed).
  Future<void> beginFromMnemonic(
    String mnemonic, {
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    final List<int> bits;
    try {
      bits = Bip39.mnemonicToEntropyBits(mnemonic);
    } on FormatException catch (e) {
      _errorMessage = e.message; // generic by construction; no seed content
      _setPhase(SetupPhase.error);
      return Future<void>.value();
    }
    return _encodeRoot(
      bits,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// The shared chained-encode pipeline over a ready entropy [bits] root: for
  /// each stage derive its fractal from all preceding points (stage 0 is
  /// canonical, no derivation) and encode that stage's single 32-bit point,
  /// before entering the memorise phase. Takes ownership of [bits] and wipes it.
  Future<void> _encodeRoot(
    List<int> bits, {
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase != SetupPhase.idle &&
        _phase != SetupPhase.complete &&
        _phase != SetupPhase.error) {
      Entropy.wipe(bits);
      return; // a run is already in progress
    }
    _errorMessage = null;
    _clearRecall();
    final int n = bits.length ~/ EncodingConstants.bitsPerPoint;
    _stageCount = n;
    try {
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
  /// (the chain must be recalled in order). Uses the reservoirs the recall walk
  /// has derived so far (canonical for stage 0).
  void showRecallStage() {
    final int target = recallStageIndex.clamp(0, nStages - 1);
    _displayStageIndex = target;
    final StageReservoirs? res = target == 0 ? null : _recallReservoirs;
    _core.source.reservoirs = res;
    if (res == null) {
      _displayParams = null;
    } else {
      final ({double o, double p, double q}) key = res.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
    }
    notifyListeners();
  }

  /// Handle a select-mode click: decode the point under the cursor on the stage
  /// currently shown, then walk the chain forward, **re-running the chained
  /// Argon2 derivation** to form the next stage's fractal.
  ///
  /// The recall mirrors encoding (protocol.py `decode_entropy`): stage 0 decodes
  /// on the canonical fractal; selecting its point feeds the recalled bits to a
  /// memory-hard Argon2 pass that derives stage 1's `(o,p,q)`; stage 1 decodes
  /// under those reservoirs; and so on. Each link hashes the cumulative bits of
  /// every point recalled so far, so a stage's fractal does not exist until its
  /// derivation finishes — the wall-clock cost the protocol is built on. The
  /// last stage completes the full entropy (concatenated per-stage bits).
  ///
  /// Decoded bits and coordinates stay inside the session and are never logged
  /// (SCOPE.md invariants).
  Future<SelectionOutcome> selectPoint(
    FractalSelection selection, {
    required SizePreset preset,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase == SetupPhase.deriving ||
        _phase == SetupPhase.recallComplete) {
      return SelectionOutcome.busy;
    }
    _preset = preset;

    final int k = _displayStageIndex;
    // Recall must proceed in order: the displayed stage must be the next one to
    // recall. (Guards against decoding a browsed-ahead stage out of sequence.)
    if (k != recallStageIndex) return SelectionOutcome.busy;

    // Decode under the reservoirs this recall walk derived for stage k
    // (canonical for stage 0). These are produced by hashing, not reused from
    // setup — so a genuine cold recall would behave identically.
    final StageReservoirs? r = k == 0 ? null : _recallReservoirs;
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
    notifyListeners();

    if (k == nStages - 1) {
      // Final stage recalled: reconstruct the full entropy root. No further
      // derivation — there is no next fractal to form.
      _recalledChunks.add(result.bits);
      _recalledEntropyBits = <int>[
        for (final List<int> chunk in _recalledChunks) ...chunk,
      ];
      _setPhase(SetupPhase.recallComplete);
      return SelectionOutcome.complete;
    }

    // Derive the next stage's fractal by hashing the cumulative bits of every
    // point recalled so far (points 0..k) — one memory-hard link of the chain.
    final List<int> priorBits = <int>[
      for (final List<int> chunk in _recalledChunks) ...chunk,
      ...result.bits,
    ];
    try {
      _workingStageIndex = k + 1;
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

      // Commit: record this stage's point and advance to the new fractal.
      _recalledChunks.add(result.bits);
      _recallReservoirs = reservoirs;
      _core.source.reservoirs = reservoirs;
      _displayStageIndex = k + 1;
      final ({double o, double p, double q}) key = reservoirs.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
      _selectedMark = null;
      _setPhase(SetupPhase.memorise);
      return SelectionOutcome.advancedStage;
    } on Argon2Cancelled {
      // Roll back: stage k is not advanced, so the user can retry the click.
      Entropy.wipe(priorBits);
      _argon2Job = null;
      _selectedMark = null;
      _setPhase(SetupPhase.memorise);
      return SelectionOutcome.busy;
    }
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

  /// Advance the displayed stage to the next available one, wrapping around —
  /// the `T` hotkey. "Available" means the canonical stage or a stage already
  /// derived, so during a partial recall it only visits stages reached so far.
  /// No-op until a session exists.
  void cycleStage() {
    if (_stageCount <= 1) return;
    for (int step = 1; step <= nStages; step++) {
      final int next = (_displayStageIndex + step) % nStages;
      final bool available = next == 0 ||
          (next < _reservoirs.length && _reservoirs[next] != null);
      if (available) {
        if (next != _displayStageIndex) {
          _applyDisplayStage(next);
          notifyListeners();
        }
        return;
      }
    }
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
    _recallReservoirs?.clear();
    _recallReservoirs = null;
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
    _stageCount = 0;
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
