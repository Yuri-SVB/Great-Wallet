import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/entropy.dart';
import '../core/great_wall_core.dart';
import '../core/orbit_protocol.dart';
import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';

/// Where an orbit setup currently is.
enum OrbitSetupPhase {
  /// No session — pick a tier and σ, then [begin].
  idle,

  /// Placing points on the current stage's boards.
  placing,

  /// Running the memory-hard advance `o_{i+1} = H*(K_i)` between stages.
  advancing,

  /// All stages done; [terminalK] holds `K_N`.
  complete,

  /// A step failed; [error] explains.
  error,
}

/// The outcome of placing (or generating) a point on the current board.
enum OrbitPlaceOutcome {
  /// Not in [OrbitSetupPhase.placing] (idle / advancing / done).
  busy,

  /// The tap hit no encodable leaf on this board — nothing recorded.
  invalid,

  /// Recorded; more boards remain on this stage.
  marked,

  /// Recorded the last board of a stage; the orbit advanced to the next stage.
  stageAdvanced,

  /// Recorded the last board of the final stage; the setup is complete.
  complete,
}

/// Interactive orchestration of the 0.4.0 **orbit** Setup — the coercion-
/// resistant flow that places `t_i` (= `r_i`) fractal points per deep stage,
/// combines them by Shamir into `K_i = H(o_i ‖ Sh_i)`, and advances the orbit
/// memory-hard between stages. This is the stateful, board-at-a-time peer of the
/// batch [OrbitProtocol]; it drives the same engine primitives.
///
/// It is a **separate** flow — the legacy 0.3.0 chain [SetupController] is left
/// intact as a fallback (ARCHITECTURE / roadmap: soft flip). Boards are walked
/// one at a time (board `j` of `t_i`), which keeps the shared render source
/// unambiguous and gives a guided sequence.
///
/// SECURITY: decoded bits, points, `Sh_i`, and `K_i` are all coercion-relevant
/// (SCOPE.md). They live only in this controller's state, are never logged, and
/// are wiped on stage rollover and [dispose].
class OrbitSetupController extends ChangeNotifier {
  OrbitSetupController(this._core) : _orbit = OrbitProtocol(_core);

  final GreatWallCore _core;
  final OrbitProtocol _orbit;

  OrbitSetupPhase _phase = OrbitSetupPhase.idle;
  OrbitSetupPhase get phase => _phase;

  int _level = 0;
  int get level => _level;

  List<int> _thresholds = const <int>[];

  /// Per-stage thresholds `t_i` (index 0 = stage 0, `1..N` the deep stages).
  List<int> get thresholds => List<int>.unmodifiable(_thresholds);

  /// Whether the chosen tier is the substandard entry (Setup 1). The screen MUST
  /// surface this loudly.
  bool get substandard =>
      _level > 0 && _core.setupTierSubstandard(_level);

  Uint8List _o = Uint8List(0); // current orbit point o_i
  int _stageIndex = 0;
  int _boardIndex = 0;

  /// Stage index currently being placed (0 = stage 0, `1..N` deep).
  int get stageIndex => _stageIndex;

  /// Board index within the current stage (`0..t_i-1`).
  int get boardIndex => _boardIndex;

  /// Number of stages in this setup (`N + 1`).
  int get stageCount => _thresholds.length;

  /// `t_i` for the current stage, or 0 outside a session.
  int get boardCount =>
      (_stageIndex >= 0 && _stageIndex < _thresholds.length)
          ? _thresholds[_stageIndex]
          : 0;

  // Accumulators for the in-progress stage.
  final List<List<int>> _stageBits = <List<int>>[];
  final List<({int reRaw, int imRaw})> _stagePoints =
      <({int reRaw, int imRaw})>[];
  final List<({int o, int p, int q})> _stageFractals =
      <({int o, int p, int q})>[];

  final List<OrbitStage> _stages = <OrbitStage>[];

  /// The completed stages so far (0-based). Coercion-relevant — do not log.
  List<OrbitStage> get stages => List<OrbitStage>.unmodifiable(_stages);

  Uint8List? _terminalK;

  /// `K_N` once [phase] is [OrbitSetupPhase.complete]; null before.
  Uint8List? get terminalK =>
      _terminalK == null ? null : Uint8List.fromList(_terminalK!);

  String? _error;
  String? get error => _error;

  OrbitAdvanceFn? _advanceFn;

  bool get isComplete => _phase == OrbitSetupPhase.complete;

  /// The current board's perturbation reservoirs `(o, p, q) = θ_i_j split`,
  /// selecting which fractal the user is placing on. Null outside [placing].
  ({int o, int p, int q})? get currentBoardParams {
    if (_phase != OrbitSetupPhase.placing) return null;
    return _orbit.orbitParams(_o, _boardIndex);
  }

  /// Begin an orbit setup for [level] rooted at [sigma] (`o_0 = H(σ)`).
  /// [advanceFn] overrides the memory-hard advance (tests inject a cheap one).
  /// No-ops loudly (sets [error]) on an invalid level.
  void begin({
    required int level,
    required Uint8List sigma,
    OrbitAdvanceFn? advanceFn,
  }) {
    final List<int> thresholds = _core.setupTierThresholds(level);
    if (thresholds.isEmpty) {
      _fail('invalid setup level $level');
      return;
    }
    _wipeStageAccumulators();
    for (final OrbitStage st in _stages) {
      _wipeStage(st);
    }
    _stages.clear();
    _level = level;
    _thresholds = thresholds;
    _advanceFn = advanceFn;
    _o = _core.orbitRoot(sigma);
    _stageIndex = 0;
    _boardIndex = 0;
    _terminalK = null;
    _error = null;
    _phase = OrbitSetupPhase.placing;
    notifyListeners();
  }

  /// Place a point at complex-plane coordinates ([re], [im]) on the current
  /// board: decode it to 32 bits under the board's reservoirs and record it.
  /// Completing a stage triggers the Shamir combine and the (awaited) advance.
  Future<OrbitPlaceOutcome> placeAt(double re, double im) async {
    if (_phase != OrbitSetupPhase.placing) return OrbitPlaceOutcome.busy;
    final ({int o, int p, int q}) prm = _orbit.orbitParams(_o, _boardIndex);
    final int reRaw = fixedFromDouble(re);
    final int imRaw = fixedFromDouble(im);
    final CoreDecodeResult d = _core.decodePoint(
      reRaw: reRaw,
      imRaw: imRaw,
      o: prm.o,
      p: prm.p,
      q: prm.q,
    );
    if (!d.valid) return OrbitPlaceOutcome.invalid;
    return _recordBoard(d.bits, (reRaw: reRaw, imRaw: imRaw), prm);
  }

  /// Generate a random 32-bit point for the current board (the "generate" path,
  /// where the app picks the entropy). Encodes the bits so a real fractal point
  /// is recorded, then advances exactly as [placeAt].
  Future<OrbitPlaceOutcome> placeGenerated() {
    final List<int> bits = Entropy.randomBits(32);
    final Future<OrbitPlaceOutcome> r = placeChunk(bits);
    Entropy.wipe(bits);
    return r;
  }

  /// Record an explicit 32-bit [chunk] on the current board (encoding it to a
  /// real fractal point). Shared by [placeGenerated] and by tests that drive
  /// deterministic entropy; the caller owns [chunk] (this copies what it keeps).
  Future<OrbitPlaceOutcome> placeChunk(List<int> chunk) async {
    if (_phase != OrbitSetupPhase.placing) return OrbitPlaceOutcome.busy;
    if (chunk.length != 32) {
      _fail('a board carries 32 bits, got ${chunk.length}');
      return OrbitPlaceOutcome.busy;
    }
    final ({int o, int p, int q}) prm = _orbit.orbitParams(_o, _boardIndex);
    final List<EncodedPoint> pts =
        _core.encodeStage(List<int>.of(chunk), o: prm.o, p: prm.p, q: prm.q);
    final EncodedPoint pt = pts.first;
    return _recordBoard(
        List<int>.of(chunk), (reRaw: pt.reRaw, imRaw: pt.imRaw), prm);
  }

  /// Common tail for [placeAt] / [placeChunk]: stash the board, and when the
  /// stage's `t_i` boards are all in, Shamir-combine → `K_i`, then advance.
  Future<OrbitPlaceOutcome> _recordBoard(
    List<int> bits,
    ({int reRaw, int imRaw}) point,
    ({int o, int p, int q}) prm,
  ) async {
    _stageBits.add(List<int>.of(bits));
    _stagePoints.add(point);
    _stageFractals.add(prm);
    _boardIndex++;

    if (_boardIndex < boardCount) {
      notifyListeners();
      return OrbitPlaceOutcome.marked;
    }

    // Stage complete: Sh_i over the t_i points, then K_i = H(o_i ‖ Sh_i).
    final int t = boardCount;
    final List<int> xs = <int>[for (int j = 0; j < t; j++) j + 1];
    final List<int> ys = <int>[
      for (final List<int> b in _stageBits) OrbitProtocol.bitsToU32(b),
    ];
    final List<int> sh = _core.shamirInterp(xs, ys);
    final Uint8List shBytes = GreatWallCoreBindings.shToBytes(sh);
    final Uint8List k = _core.masterSecret(_o, shBytes);
    _stages.add(OrbitStage(
      index: _stageIndex,
      oBytes: Uint8List.fromList(_o),
      threshold: t,
      fractals: List<({int o, int p, int q})>.of(_stageFractals),
      points: List<({int reRaw, int imRaw})>.of(_stagePoints),
      sh: List<int>.of(sh),
      k: k,
    ));
    _terminalK = k;

    final bool lastStage = _stageIndex >= stageCount - 1;
    if (lastStage) {
      _wipeStageAccumulators();
      _phase = OrbitSetupPhase.complete;
      notifyListeners();
      return OrbitPlaceOutcome.complete;
    }

    // Advance the orbit (memory-hard by default) before the next stage.
    _phase = OrbitSetupPhase.advancing;
    notifyListeners();
    try {
      final Uint8List next =
          await (_advanceFn ?? _defaultAdvance)(_o, shBytes);
      _o = next;
    } catch (e) {
      _fail('advance failed: $e');
      return OrbitPlaceOutcome.busy;
    }
    _stageIndex++;
    _boardIndex = 0;
    _wipeStageAccumulators();
    _phase = OrbitSetupPhase.placing;
    notifyListeners();
    return OrbitPlaceOutcome.stageAdvanced;
  }

  /// Tear the session back down to [OrbitSetupPhase.idle], wiping all
  /// coercion-relevant material (for a "start over"). Keeps the controller
  /// usable — [begin] can be called again.
  void resetToIdle() {
    _wipeStageAccumulators();
    for (final OrbitStage st in _stages) {
      _wipeStage(st);
    }
    _stages.clear();
    if (_terminalK != null) {
      _terminalK!.fillRange(0, _terminalK!.length, 0);
      _terminalK = null;
    }
    if (_o.isNotEmpty) {
      _o.fillRange(0, _o.length, 0);
      _o = Uint8List(0);
    }
    _level = 0;
    _thresholds = const <int>[];
    _stageIndex = 0;
    _boardIndex = 0;
    _error = null;
    _phase = OrbitSetupPhase.idle;
    notifyListeners();
  }

  Future<Uint8List> _defaultAdvance(Uint8List o, Uint8List shBytes) async {
    final ({Uint8List k, Uint8List next}) r =
        await _core.advanceOrbit(o, shBytes, steps: 1);
    return r.next;
  }

  void _fail(String message) {
    _error = message;
    _phase = OrbitSetupPhase.error;
    notifyListeners();
  }

  void _wipeStageAccumulators() {
    for (final List<int> b in _stageBits) {
      Entropy.wipe(b);
    }
    _stageBits.clear();
    _stagePoints.clear();
    _stageFractals.clear();
  }

  /// Zero a completed stage's byte-backed secrets (its orbit point and `K_i`).
  /// The int-list fields (`sh`, packed point values) are dropped with the stage.
  void _wipeStage(OrbitStage st) {
    st.oBytes.fillRange(0, st.oBytes.length, 0);
    st.k.fillRange(0, st.k.length, 0);
  }

  @override
  void dispose() {
    _wipeStageAccumulators();
    for (final OrbitStage st in _stages) {
      _wipeStage(st);
    }
    if (_terminalK != null) {
      _terminalK!.fillRange(0, _terminalK!.length, 0);
    }
    if (_o.isNotEmpty) _o.fillRange(0, _o.length, 0);
    super.dispose();
  }
}
