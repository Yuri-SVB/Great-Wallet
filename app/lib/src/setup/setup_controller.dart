import 'dart:typed_data';

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
/// Implements the **chained protocol** with a text Stage 0. Stage 0 is a
/// salt/pepper *text* (no fractal, no point) that seeds the chain; the entropy
/// root is then split into one 32-bit chunk per fractal stage. Every fractal
/// `(o,p,q)` is the memory-hard hash of the Stage-0 text plus *all preceding
/// points* (`θ_k = SHA-256(Argon2^N(text ‖ points 1..k-1))`), so even the first
/// fractal is personalised — there is no app-canonical fractal. The text never
/// enters the entropy, so the BIP39 ↔ Great Wall conversion stays lossless. One
/// fractal = one haystack; one point = one needle.
///
/// SECURITY: the generated entropy and the encoded points are coercion-relevant.
/// They are held only for the duration of the memorisation phase and wiped by
/// [finish]/[dispose]. Nothing here is logged or persisted (SCOPE.md invariants).
class SetupController extends ChangeNotifier {
  SetupController(this._core);

  final GreatWallCore _core;

  SetupPhase _phase = SetupPhase.idle;
  SetupPhase get phase => _phase;

  /// True when the active session is a **cold-start recall** (the salt was
  /// entered and the points are being re-derived link by link), as opposed to
  /// a fresh/imported setup. Drives the recall-specific control copy.
  bool _isRecallSession = false;
  bool get isRecallSession => _isRecallSession;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  SizePreset _preset = SizePreset.defaultPreset;
  SizePreset get preset => _preset;

  /// Total number of displayed stages of the active session: the Stage-0 text
  /// stage plus one per 32-bit fractal point (`pointStageCount + 1`). For an
  /// imported seed phrase the point count may be any 3..24-word size, not one of
  /// the presets. Falls back to the configured preset before a session starts.
  int _stageCount = 0;
  int get nStages => _stageCount > 0 ? _stageCount : _preset.nStages + 1;

  /// Number of fractal point stages (`nStages - 1`): Stage 0 carries no point.
  int get pointStageCount => nStages - 1;

  /// Which stage the canvas is currently showing. Stage 0 is the salt/pepper
  /// text stage (no fractal, no point); stages 1..N are the chain-derived
  /// fractals, one 32-bit point each.
  int _displayStageIndex = 0;
  int get displayStageIndex => _displayStageIndex;

  /// True when the displayed stage is the Stage-0 text stage (no canvas).
  bool get isTextStage => _displayStageIndex == 0;

  /// The displayed fractal mapped onto great-wall-ux's render paths. Every
  /// chained fractal is a perturbation now (Stage 0 is text, not a fractal), so
  /// fractal stages always use the perturbed path; only matters for stages >= 1.
  Stage get displayStage =>
      _displayStageIndex == 0 ? Stage.stage1 : Stage.stage2;

  /// The Stage-0 salt/pepper text (held for the session so recall can re-derive
  /// the chain; wiped on reset/finish). Shown only behind a reveal toggle.
  String _chainText = '';
  String get saltPepper => _chainText;

  /// The fractal stage being derived/encoded right now, for progress labels
  /// (its 0-based display index, i.e. 1..N).
  int _workingStageIndex = 1;
  int get workingStageNumber => _workingStageIndex;

  int _argon2Done = 0;
  int _argon2Total = 1;
  int get argon2Done => _argon2Done;
  int get argon2Total => _argon2Total;

  // Session-only secret material.
  List<int>? _entropyBits;

  /// One encoded point per stage; index 0 (the text stage) is always `null`,
  /// indices 1..N hold each fractal's point. `null` until that stage is encoded.
  List<EncodedPoint?> _points = const <EncodedPoint?>[];

  /// Each fractal's chain-derived reservoirs; index 0 (the text stage) is always
  /// `null`. Every later stage is derived from the text + all preceding points.
  List<StageReservoirs?> _reservoirs = const <StageReservoirs?>[];

  /// The displayed stage's perturbation as great-wall-ux's display surrogate
  /// (`null` for the Stage-0 text stage). The authoritative reservoirs live on
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

  // The reservoirs for the fractal currently being recalled. The first fractal
  // reuses the value derived at setup; every later fractal is re-derived from
  // the text + recalled points when the previous point is selected, so the user
  // sees the Argon2 work happen (the chain link by link, as protocol.py decode).
  StageReservoirs? _recallReservoirs;

  /// Display index of the next fractal a select-mode click should recall. Stage
  /// 0 is the text stage, so the first fractal to recall is stage 1; it advances
  /// as points come back (`recalled points + 1`).
  int get recallStageIndex => _recalledChunks.length + 1;

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
  /// root of the configured [preset] size. [text] is the Stage-0 salt/pepper
  /// that seeds the fractal chain.
  Future<void> begin({
    required SizePreset preset,
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) {
    _preset = preset;
    return _encodeRoot(
      Entropy.randomBits(preset.entropyBits),
      text: text,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// Run the chained Setup pipeline on an **imported BIP39 seed phrase** instead
  /// of fresh entropy. The phrase may be sub-standard (any 3..24 words → a
  /// matching number of point stages). [text] is the Stage-0 salt/pepper. On an
  /// invalid phrase the controller enters the error phase with a generic message
  /// (the seed content is never echoed).
  Future<void> beginFromMnemonic(
    String mnemonic, {
    required String text,
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
      text: text,
      argon2Iterations: argon2Iterations,
      profile: profile,
    );
  }

  /// The shared chained-encode pipeline over a ready entropy [bits] root.
  ///
  /// Stage 0 is the salt/pepper [text] — it carries no point; it seeds the
  /// chain. Each fractal stage `k` (1..N) derives its `(o,p,q)` from the text
  /// plus all preceding points and encodes that stage's single 32-bit entropy
  /// chunk (chunk `k-1`). There is no canonical fractal: even the first fractal
  /// is personalised by the text. The text never enters the entropy, so the
  /// recalled seed equals [bits] exactly (lossless BIP39 round-trip). Takes
  /// ownership of [bits] and wipes it.
  Future<void> _encodeRoot(
    List<int> bits, {
    required String text,
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
    _isRecallSession = false;
    final int pointStages = bits.length ~/ EncodingConstants.bitsPerPoint;
    _stageCount = pointStages + 1; // + the Stage-0 text stage
    // Canonicalise through the engine so the stored/displayed text is exactly
    // what gets hashed (the protocol rule lives in core, not here).
    _chainText = _core.canonicalizeSaltPepper(text);
    try {
      _entropyBits = bits;
      _points = List<EncodedPoint?>.filled(pointStages + 1, null);
      _reservoirs = List<StageReservoirs?>.filled(pointStages + 1, null);

      const int bpp = EncodingConstants.bitsPerPoint;
      for (int k = 1; k <= pointStages; k++) {
        _workingStageIndex = k;
        // Stage k's fractal derives from the text + every preceding point
        // (chunks 0..k-2) — one link of the memory-hard chain. Stage 1 derives
        // from the text alone.
        final List<int> priorPointBits = bits.sublist(0, (k - 1) * bpp);
        final Uint8List input = _core.chainInput(_chainText, priorPointBits);
        _setPhase(SetupPhase.deriving);
        _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
        _argon2Done = 0;
        final Argon2Job job = await _core.startStageDerivation(
          input,
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
        Entropy.wipe(priorPointBits);
        _reservoirs[k] = reservoirs;

        // Encode this stage's single 32-bit point (entropy chunk k-1).
        _setPhase(SetupPhase.encoding);
        final List<int> chunk = bits.sublist((k - 1) * bpp, k * bpp);
        final List<EncodedPoint> pts = _core.encodeStage(
          chunk,
          o: reservoirs.o,
          p: reservoirs.p,
          q: reservoirs.q,
        );
        _points[k] = pts.first;
        Entropy.wipe(chunk);
        notifyListeners();
      }

      // Memorise. Plaintext entropy is no longer needed once it lives on the
      // fractals as points — wipe it; keep only the points (and the Stage-0
      // text, which recall needs to re-derive the chain) to display.
      Entropy.wipe(bits);
      _entropyBits = null;

      // Land on the first fractal (Stage 1) to memorise; Stage 0 (text) is
      // reachable with the stage navigation / T.
      _applyDisplayStage(pointStages >= 1 ? 1 : 0);
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

  /// Begin a **cold-start recall**: no setup ran this session. Derives the
  /// Stage-1 fractal from the salt/pepper [text] alone (the first chain link,
  /// `chainInput(text, [])`), then enters the select walk so the user clicks
  /// their memorised point on each stage in turn — exactly as [selectPoint]
  /// continues the chain.
  ///
  /// [preset] fixes how many point stages the seed has (so the walk knows when
  /// it is complete); [argon2Iterations] and [profile] MUST match the original
  /// setup or every derived fractal will differ and no point will decode.
  /// Nothing is encoded and no target markers are shown — recall reconstructs
  /// the seed purely from the user's clicks. Secrets stay in-session and are
  /// never logged (SCOPE.md invariants).
  Future<void> beginRecall({
    required SizePreset preset,
    required String text,
    required int argon2Iterations,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (_phase == SetupPhase.deriving ||
        _phase == SetupPhase.recallComplete) {
      return;
    }
    // Start from a clean session; no encoded points exist in a recall.
    _resetSecrets();
    _errorMessage = null;
    _preset = preset;
    _stageCount = preset.nStages + 1; // Stage-0 text + one per point stage
    _chainText = _core.canonicalizeSaltPepper(text);
    _points = List<EncodedPoint?>.filled(_stageCount, null);
    _reservoirs = List<StageReservoirs?>.filled(_stageCount, null);
    try {
      _workingStageIndex = 1;
      _setPhase(SetupPhase.deriving);
      _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
      _argon2Done = 0;
      final Uint8List input = _core.chainInput(_chainText, const <int>[]);
      final Argon2Job job = await _core.startStageDerivation(
        input,
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
      // Land on Stage 1, ready for the first select-mode click.
      _recallReservoirs = reservoirs;
      _applyReservoirs(1, reservoirs);
      _selectedMark = null;
      _isRecallSession = true;
      _setPhase(SetupPhase.memorise);
    } on Argon2Cancelled {
      _resetSecrets();
      _setPhase(SetupPhase.idle);
    } catch (e) {
      _resetSecrets();
      _errorMessage = 'Recall failed: ${e.runtimeType}';
      _setPhase(SetupPhase.error);
    }
  }

  /// Snap the canvas to the fractal stage the recall walk is on. Called when the
  /// user enters select mode so the click lands on the right fractal (the chain
  /// must be recalled in order). The first fractal reuses the setup-derived
  /// reservoirs (Stage 0 — the text — is reused in-session, not re-entered; its
  /// recall verification belongs to CPNF). No-op once recall is complete.
  void showRecallStage() {
    if (isRecallComplete || _stageCount == 0) return;
    final int target = recallStageIndex; // 1..N
    _recallReservoirs ??=
        (target < _reservoirs.length) ? _reservoirs[target] : null;
    _applyReservoirs(target, _recallReservoirs);
    notifyListeners();
  }

  /// Handle a select-mode click: decode the point under the cursor on the
  /// fractal currently shown, then walk the chain forward, **re-running the
  /// chained Argon2 derivation** to form the next stage's fractal.
  ///
  /// The recall mirrors encoding (protocol.py `decode_entropy`): the first
  /// fractal (Stage 1) is derived from the Stage-0 text; decoding its point
  /// feeds the recalled bits + text to a memory-hard Argon2 pass that derives
  /// Stage 2's `(o,p,q)`; and so on. Each link hashes the text plus every point
  /// recalled so far, so a stage's fractal does not exist until its derivation
  /// finishes — the wall-clock cost the protocol is built on. The last stage
  /// completes the full entropy (concatenated per-point bits).
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
    // Recall must proceed in order: the displayed fractal must be the next one
    // to recall. Stage 0 (text) has no point to select.
    if (k == 0 || k != recallStageIndex) return SelectionOutcome.busy;

    // Decode under the reservoirs for the fractal being recalled.
    final StageReservoirs? r = _recallReservoirs;
    if (r == null) return SelectionOutcome.busy;

    final CoreDecodeResult result = _core.decodePoint(
      reRaw: fixedFromDouble(selection.re),
      imRaw: fixedFromDouble(selection.im),
      o: r.o,
      p: r.p,
      q: r.q,
    );
    if (!result.valid) return SelectionOutcome.invalid;

    _selectedMark = (re: selection.re, im: selection.im);
    notifyListeners();

    if (k == nStages - 1) {
      // Final fractal recalled: reconstruct the full entropy root. No further
      // derivation — there is no next fractal to form.
      _recalledChunks.add(result.bits);
      _recalledEntropyBits = <int>[
        for (final List<int> chunk in _recalledChunks) ...chunk,
      ];
      _setPhase(SetupPhase.recallComplete);
      return SelectionOutcome.complete;
    }

    // Derive the next fractal by hashing the text + every point recalled so far
    // (points 0..k-1, i.e. all prior chunks and this one) — one chain link.
    final List<int> priorPointBits = <int>[
      for (final List<int> chunk in _recalledChunks) ...chunk,
      ...result.bits,
    ];
    final Uint8List input = _core.chainInput(_chainText, priorPointBits);
    try {
      _workingStageIndex = k + 1;
      _setPhase(SetupPhase.deriving);
      _argon2Total = argon2Iterations < 1 ? 1 : argon2Iterations;
      _argon2Done = 0;
      final Argon2Job job = await _core.startStageDerivation(
        input,
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
      Entropy.wipe(priorPointBits);

      // Commit: record this stage's point and advance to the new fractal.
      _recalledChunks.add(result.bits);
      _recallReservoirs = reservoirs;
      _applyReservoirs(k + 1, reservoirs);
      _selectedMark = null;
      _setPhase(SetupPhase.memorise);
      return SelectionOutcome.advancedStage;
    } on Argon2Cancelled {
      // Roll back: stage k is not advanced, so the user can retry the click.
      Entropy.wipe(priorPointBits);
      _argon2Job = null;
      _selectedMark = null;
      _setPhase(SetupPhase.memorise);
      return SelectionOutcome.busy;
    }
  }

  /// Point the canvas + render source at [index] using explicit [res] reservoirs
  /// (used by the recall walk, which carries its own re-derived reservoirs).
  void _applyReservoirs(int index, StageReservoirs? res) {
    _displayStageIndex = index;
    _core.source.reservoirs = res;
    if (res == null) {
      _displayParams = null;
    } else {
      final ({double o, double p, double q}) key = res.displayKey;
      _displayParams = StageParameters(o: key.o, p: key.p, q: key.q);
    }
  }

  /// Clear the current stage's pending selection mark.
  void clearSelection() {
    if (_selectedMark == null) return;
    _selectedMark = null;
    notifyListeners();
  }

  /// Switch the displayed stage during memorisation. Only stages that can be
  /// shown — the Stage-0 text stage, or a fractal already derived — are allowed.
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
  /// the `T` hotkey. "Available" means the Stage-0 text stage or a fractal
  /// already derived, so during a partial recall it only visits stages reached
  /// so far. No-op until a session exists.
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

  /// Point the canvas (and the render source) at [index]: nothing for the
  /// Stage-0 text stage, otherwise that fractal's stored chain-derived
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
    _chainText = '';
    _isRecallSession = false;
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
