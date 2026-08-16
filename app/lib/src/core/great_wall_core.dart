import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/core_bindings.dart';
import '../ffi/library_loader.dart';
import 'core_escape_count_source.dart';
import 'core_leaf_area_source.dart';
import 'encoding_constants.dart';
import 'stage_params.dart';

/// App-level facade over great-wall-core: opens the engine once, exposes the
/// [EscapeCountSource] for the UX canvas, and wraps the encode / decode /
/// Argon2 calls the orchestration needs.
///
/// One instance is shared for the app's lifetime; the engine's internal
/// thread pool (TECH_STACK.md §"Threading model") parallelises the renders.
class GreatWallCore {
  GreatWallCore._(this.bindings) : source = CoreEscapeCountSource(bindings) {
    // Bits-per-point is a structural protocol constant used in const contexts,
    // so it stays a Dart constant — but the engine remains its authority. Fail
    // loudly on drift rather than encode against a stale width.
    final int engineBpp = bindings.bitsPerPoint();
    if (engineBpp != EncodingConstants.bitsPerPoint) {
      throw StateError(
        'Engine bits-per-point ($engineBpp) does not match the wallet '
        'constant (${EncodingConstants.bitsPerPoint}); the protocol changed. '
        'Update EncodingConstants.bitsPerPoint before encoding anything.',
      );
    }
  }

  /// Open and bind the engine library. Throws [CoreLibraryNotFound] if the
  /// `cdylib` has not been built (run `native/build_core.sh`).
  factory GreatWallCore.open({CoreLibraryLoader loader = const CoreLibraryLoader()}) {
    return GreatWallCore._(GreatWallCoreBindings.open(loader: loader));
  }

  final GreatWallCoreBindings bindings;

  /// The production [EscapeCountSource] handed to great-wall-ux's FractalCanvas.
  final CoreEscapeCountSource source;

  /// The production [LeafAreaSource] — enumerates the canonical leaf areas in a
  /// view. Its `reservoirs` are kept in sync with [source] by the orchestrator
  /// so both decode/render on the same fractal as the displayed stage.
  late final CoreLeafAreaSource leafSource = CoreLeafAreaSource(bindings);

  /// Canonical encode/decode parameters, fetched once from the engine — the
  /// single source of truth for the values that determine encode output. The
  /// wallet never hard-codes these (a stale `maxIter = 64` is what stalled
  /// deep-zoom encodes); it reads whatever the linked engine dictates.
  late final CoreDiscoveryParams encodeParams = bindings.encodeParams();

  /// The canonical encode area, fetched once from the engine.
  late final FixedRect encodeArea = bindings.encodeArea();

  /// Engine algorithm version (e.g. `"0.1.0"`).
  String get engineVersion => bindings.engineVersion();

  /// Canonicalise a Stage-0 salt/pepper string through the engine (uppercase
  /// ASCII, keep only `A-Z0-9-`). Single source of truth shared with
  /// great-wall-core; the wallet never reimplements the rule.
  String canonicalizeSaltPepper(String text) =>
      bindings.saltPepperCanonicalize(text);

  /// Build one chain link's Argon2 input through the engine: the canonical
  /// Stage-0 salt/pepper bytes followed by `bits_to_bytes(priorPointBits)`.
  /// This is the protocol byte layout; it lives in the shared engine so the
  /// wallet and great-wall-core produce identical seeds for the same text.
  Uint8List chainInput(String text, List<int> priorPointBits) =>
      bindings.chainInput(text, priorPointBits);

  /// Encode one stage's 32 bits into a single fractal point.
  ///
  /// `(o, p, q)` selects the fractal: `(0,0,0)` for the canonical stage 0, the
  /// stage's chain-derived reservoirs for any later stage. Under the chained
  /// protocol a stage carries exactly one 32-bit point, but this still accepts
  /// any multiple of 32 bits and returns one point per chunk.
  List<EncodedPoint> encodeStage(
    List<int> stageBits, {
    required int o,
    required int p,
    required int q,
  }) {
    final FixedRect area = encodeArea;
    final CoreDiscoveryParams params = encodeParams;
    final int n = stageBits.length ~/ EncodingConstants.bitsPerPoint;
    final List<EncodedPoint> points = <EncodedPoint>[];
    for (int i = 0; i < n; i++) {
      final List<int> chunk = stageBits.sublist(
        i * EncodingConstants.bitsPerPoint,
        (i + 1) * EncodingConstants.bitsPerPoint,
      );
      final ({int reRaw, int imRaw, FixedRect leafRect}) pt =
          bindings.encodePoint(
        bits: chunk,
        area: area,
        params: params,
        o: o,
        p: p,
        q: q,
      );
      points.add(
        EncodedPoint(reRaw: pt.reRaw, imRaw: pt.imRaw, leafRect: pt.leafRect),
      );
    }
    return points;
  }

  /// Decode a tapped point back to its 32 bits, with a validity flag.
  /// `(o, p, q)` must match the stage the point was encoded under.
  CoreDecodeResult decodePoint({
    required int reRaw,
    required int imRaw,
    required int o,
    required int p,
    required int q,
  }) {
    return bindings.decodeFull(
      pointReRaw: reRaw,
      pointImRaw: imRaw,
      numBits: EncodingConstants.bitsPerPoint,
      area: encodeArea,
      params: encodeParams,
      o: o,
      p: p,
      q: q,
    );
  }

  /// Derive a chained stage's `(o, p, q)` from a ready Argon2 [input], by
  /// running `iterations` Argon2d passes and feeding each digest back as the
  /// next input — the iterative scheme of `derive_stage_params` /
  /// `argon2_iterate` (argon2_pipeline.py). This is one link of the chain; the
  /// caller assembles [input] as the Stage-0 salt/pepper bytes followed by the
  /// packed bits of every preceding point, so the input grows by 32 bits per
  /// stage and every fractal is personalised (there is no canonical fractal).
  ///
  /// `iterations == 0` is the identity case (the input zero-padded/truncated to
  /// the 32-byte digest, no Argon2) used for fast dev runs.
  ///
  /// The whole loop runs in a **single dedicated worker isolate** (which opens
  /// its own engine binding — FFI handles cannot cross isolates), so the heavy,
  /// blocking Argon2 calls never stall the UI isolate (TECH_STACK.md
  /// §"Threading model: two-tier"). The returned [Argon2Job] exposes progress
  /// via [onProgress], the [Argon2Job.result] future, and [Argon2Job.cancel],
  /// which **kills** the isolate — so Stop returns control immediately instead
  /// of waiting out the run. (A single in-flight native pass cannot be
  /// preempted mid-call, but cancel stops listening and tears the isolate down
  /// at once; granularity is one pass, as in the reference.)
  ///
  /// [onCheckpoint] is invoked after **every** completed pass with that pass's
  /// intermediary digest (the chain so far). A caller that keeps the latest can
  /// therefore halt mid-stage — kill the in-flight pass via [Argon2Job.cancel] —
  /// and lose only that single pass, not the whole stage's accumulated work. The
  /// digest is coercion-relevant; the caller owns what it keeps and must wipe it.
  Future<Argon2Job> startStageDerivation(
    Uint8List input, {
    required int iterations,
    Argon2Profile profile = Argon2Profile.basic,
    void Function(int completed, int total)? onProgress,
    void Function(int completed, Uint8List digest)? onCheckpoint,
  }) async {
    final int total = iterations < 1 ? 1 : iterations;

    if (iterations == 0) {
      // Identity case: data.ljust(32, 0)[:32] (argon2_pipeline.py).
      final int n = input.length < 32 ? input.length : 32;
      final Uint8List digest = Uint8List(32)..setRange(0, n, input);
      onProgress?.call(1, total);
      onCheckpoint?.call(1, digest);
      final StageReservoirs r = StageReservoirs.fromArgon2Digest(digest);
      digest.fillRange(0, digest.length, 0);
      return Argon2Job(Future<StageReservoirs>.value(r), () {});
    }

    final ReceivePort port = ReceivePort();
    final Isolate isolate = await Isolate.spawn<(SendPort, Uint8List, int, int)>(
      _argon2IsolateEntry,
      (port.sendPort, input, iterations, profile.value),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    return _listenChain(port, isolate, total, onProgress, onCheckpoint);
  }

  /// Resume a halted stage's Argon2 chain from a preserved intermediary
  /// [fromDigest] (its result after [fromPass] passes), running the remaining
  /// `iterations - fromPass` passes and completing with the stage reservoirs.
  /// The counterpart to [startStageDerivation] for the halt/resume flow; same
  /// streaming, checkpointing, and cancel semantics.
  Future<Argon2Job> resumeStageDerivation(
    Uint8List fromDigest, {
    required int fromPass,
    required int iterations,
    Argon2Profile profile = Argon2Profile.basic,
    void Function(int completed, int total)? onProgress,
    void Function(int completed, Uint8List digest)? onCheckpoint,
  }) async {
    final int total = iterations < 1 ? 1 : iterations;

    if (fromPass >= total) {
      // Nothing left to do — the stash already holds the final digest.
      onProgress?.call(total, total);
      onCheckpoint?.call(total, fromDigest);
      final StageReservoirs r = StageReservoirs.fromArgon2Digest(fromDigest);
      return Argon2Job(Future<StageReservoirs>.value(r), () {});
    }

    final ReceivePort port = ReceivePort();
    final Isolate isolate =
        await Isolate.spawn<(SendPort, Uint8List, int, int, int)>(
      _argon2ResumeIsolateEntry,
      (port.sendPort, fromDigest, fromPass, iterations, profile.value),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    return _listenChain(port, isolate, total, onProgress, onCheckpoint);
  }

  /// Wire a spawned chain isolate's `(pass, digest)` stream to an [Argon2Job]:
  /// forward progress + checkpoints, resolve on the final pass, and expose a
  /// cancel that kills the isolate. Shared by start and resume.
  Argon2Job _listenChain(
    ReceivePort port,
    Isolate isolate,
    int total,
    void Function(int completed, int total)? onProgress,
    void Function(int completed, Uint8List digest)? onCheckpoint,
  ) {
    final Completer<StageReservoirs> completer = Completer<StageReservoirs>();
    void cleanup() => port.close();

    port.listen((dynamic msg) {
      if (msg is (int, Uint8List)) {
        // One completed pass: its index and the resulting intermediary digest.
        // Hand the checkpoint to the caller (it copies what it needs to keep,
        // so a halt mid-stage preserves the digests done so far), then wipe our
        // copy. The final pass (completed == total) also resolves the result.
        final (int completed, Uint8List digest) = msg;
        onProgress?.call(completed, total);
        onCheckpoint?.call(completed, digest);
        if (completed >= total) {
          final StageReservoirs r = StageReservoirs.fromArgon2Digest(digest);
          if (!completer.isCompleted) completer.complete(r);
          cleanup();
        }
        digest.fillRange(0, digest.length, 0);
      } else {
        // Error payload (from the isolate body or onError): [message, stack].
        if (!completer.isCompleted) {
          completer.completeError(StateError('Argon2 isolate failed'));
        }
        cleanup();
      }
    });

    void cancel() {
      if (completer.isCompleted) return;
      isolate.kill(priority: Isolate.immediate);
      cleanup();
      completer.completeError(const Argon2Cancelled());
    }

    return Argon2Job(completer.future, cancel);
  }

  /// Run the master-secret export ([GreatWallCoreBindings.argon2idMaster]) — one
  /// Argon2id pass over the [message] transcript — in a short-lived worker
  /// isolate, so the heavy (64 MiB, 8-pass) blocking call never stalls the UI
  /// isolate. Returns the [outLen]-byte output; the caller renders only the
  /// conventional first 32 hex chars (`MasterSecret.displayHex`).
  ///
  /// Not cancellable (a single pass cannot be preempted mid-call), so unlike
  /// [startStageDerivation] there is no [Argon2Job]; it simply completes.
  Future<Uint8List> argon2idMaster(
    Uint8List message, {
    int outLen = 1024,
  }) async {
    final ReceivePort port = ReceivePort();
    final Completer<Uint8List> completer = Completer<Uint8List>();
    await Isolate.spawn<(SendPort, Uint8List, int)>(
      _argon2idMasterIsolateEntry,
      (port.sendPort, message, outLen),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((dynamic msg) {
      if (msg is Uint8List) {
        if (!completer.isCompleted) completer.complete(msg);
      } else if (!completer.isCompleted) {
        // Error payload (from the isolate body or onError): [message, stack].
        completer.completeError(StateError('Argon2id master export failed'));
      }
      port.close();
    });
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // Orbit protocol (0.4.0) — coercion-resistant per-stage derivation.
  //
  // These wrap the engine's orbit primitives (core_bindings.dart `orbit*` /
  // `shamir*` / `setupTier*`), the Dart peers of protocol.py. The cheap ones
  // (H = SHA-256, GF(2^32) interpolation, tier lookup) run inline; the single
  // memory-hard step (`advanceOrbit`, H* = Argon2d) runs in a worker isolate so
  // it never stalls the UI isolate — exactly like [argon2idMaster].
  // ---------------------------------------------------------------------------

  /// `o_0 = H(sigma)` — the orbit root from the Namtso salt [sigma].
  Uint8List orbitRoot(Uint8List sigma) => bindings.orbitRoot(sigma);

  /// `theta_i_j = H(o_i ‖ j)` — board `j`'s fractal-parameter digest at [oI].
  Uint8List theta(Uint8List oI, int j) => bindings.theta(oI, j);

  /// `K_i = H(o_i ‖ Sh_i)` — the per-stage master secret (cheap `H`). [sh] is the
  /// serialized Shamir polynomial ([GreatWallCoreBindings.shToBytes]).
  Uint8List masterSecret(Uint8List oI, Uint8List sh) =>
      bindings.masterSecret(oI, sh);

  /// Interpolate the full Shamir polynomial `Sh` (subset-invariant) over
  /// GF(2^32) from the `t` fractal points `(xs, ys)`; returns its coefficients.
  List<int> shamirInterp(List<int> xs, List<int> ys) =>
      bindings.shamirInterp(xs, ys);

  /// Evaluate the Shamir polynomial [sh] at abscissa [x] over GF(2^32) (the
  /// engine's field arithmetic; never re-implemented in the app).
  int shamirEval(List<int> sh, int x) => bindings.shamirEval(sh, x);

  /// The next [count] forgetting-resistance share **values** from [sh] —
  /// `Sh` evaluated at the reserved resistance abscissae, entirely engine-side.
  List<int> generateResistanceShares(List<int> sh, int count) =>
      bindings.generateResistanceShares(sh, count);

  /// Canonical per-stage thresholds `t_i` for a setup [level] (index 0 = stage 0,
  /// `1..N` the deep stages); `[]` for an invalid level.
  List<int> setupTierThresholds(int level) =>
      bindings.setupTierThresholds(level);

  /// Whether a setup [level] is the substandard entry tier (Setup 1, 64-bit deep
  /// stage). The UX MUST surface this loudly wherever Setup 1 is offered.
  bool setupTierSubstandard(int level) => bindings.setupTierSubstandard(level);

  /// One orbit step — `K_i = H(o_i ‖ Sh_i)` then `o_{i+1} = H*(K_i)` over [steps]
  /// (`D`) memory-hard Argon2d passes at [profile] — run in a short-lived worker
  /// isolate so the >= 1 GiB/pass blocking call never stalls the UI isolate.
  /// Returns `(k, next)`, each 32 bytes. Not cancellable (a single pass cannot be
  /// preempted mid-call), matching [argon2idMaster].
  ///
  /// [steps] `== 0` is the **pass-through** case — zero memory-hard applications,
  /// so `o_{i+1} = advance_with(K_i, 0) = K_i`. It is computed inline with the
  /// cheap `H` (no isolate, instant), mirroring [startStageDerivation]'s
  /// `iterations == 0` identity. Both this build path and recovery go through the
  /// facade, so a `D == 0` orbit is self-consistent — but it is **not
  /// memory-hard**, so it is a dev / testing convenience, not a production setup.
  Future<({Uint8List k, Uint8List next})> advanceOrbit(
    Uint8List oI,
    Uint8List sh, {
    int steps = 1,
    Argon2Profile profile = Argon2Profile.basic,
  }) async {
    if (steps <= 0) {
      final Uint8List k = masterSecret(oI, sh); // K_i = H(o_i ‖ Sh_i)
      return (k: k, next: Uint8List.fromList(k)); // o_{i+1} = K_i (0 passes)
    }
    final ReceivePort port = ReceivePort();
    final Completer<({Uint8List k, Uint8List next})> completer =
        Completer<({Uint8List k, Uint8List next})>();
    await Isolate.spawn<(SendPort, Uint8List, Uint8List, int, int)>(
      _orbitAdvanceIsolateEntry,
      (port.sendPort, oI, sh, steps, profile.value),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((dynamic msg) {
      if (msg is (Uint8List, Uint8List)) {
        if (!completer.isCompleted) {
          completer.complete((k: msg.$1, next: msg.$2));
        }
      } else if (!completer.isCompleted) {
        // Error payload (from the isolate body or onError): [message, stack].
        completer.completeError(StateError('Orbit advance failed'));
      }
      port.close();
    });
    return completer.future;
  }

  /// Encode a batch of 32-bit [chunks] to fractal points — each under its
  /// matching `[o, p, q]` reservoir in [reservoirs] — in a **worker isolate**.
  ///
  /// The island-discovery search behind an encode is CPU-heavy and, on
  /// sparse-island corner-case values (e.g. all-zeros / all-ones), can take tens
  /// of seconds per point, so it must never run on the UI isolate. Returns one
  /// point per chunk, in order. This is **off the correctness path**: callers use
  /// the points only as display markers for the forgetting-resistance slots
  /// (`K_i` derives from the primary points alone). Errors surface as a
  /// [StateError]; the empty batch resolves to `[]` without spawning.
  Future<List<({int reRaw, int imRaw})>> encodeSharePoints(
    List<List<int>> chunks,
    List<List<int>> reservoirs,
  ) async {
    if (chunks.isEmpty) return const <({int reRaw, int imRaw})>[];
    final ReceivePort port = ReceivePort();
    final Completer<List<({int reRaw, int imRaw})>> completer =
        Completer<List<({int reRaw, int imRaw})>>();
    await Isolate.spawn<(SendPort, List<List<int>>, List<List<int>>)>(
      _encodeSharesIsolateEntry,
      (port.sendPort, chunks, reservoirs),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((dynamic msg) {
      // Success payload is a `List<[reRaw, imRaw]>`; the onError payload is a
      // `[message, stack]` list of strings. Distinguish by element type rather
      // than the reified generic, which is not guaranteed across the boundary.
      if (msg is List && (msg.isEmpty || msg.first is List)) {
        if (!completer.isCompleted) {
          completer.complete(<({int reRaw, int imRaw})>[
            for (final dynamic p in msg)
              (reRaw: (p as List)[0] as int, imRaw: p[1] as int),
          ]);
        }
      } else if (!completer.isCompleted) {
        completer.completeError(StateError('Share-point encode failed'));
      }
      port.close();
    });
    return completer.future;
  }

  /// Decode a batch of fractal [points] (`[reRaw, imRaw]` each) back to their
  /// 32-bit chunks — each under its matching `[o, p, q]` reservoir in
  /// [reservoirs] — in a **worker isolate**. An entry is null where the point
  /// did not decode to a valid leaf under those reservoirs.
  ///
  /// A decode walks the same island-discovery machinery as an encode, so a
  /// whole restored orbit's worth of them (`N` stages × `r_i` points) is
  /// seconds of CPU and must not run on the UI isolate — this is the restore
  /// peer of [encodeSharePoints]. Unlike that one, this **is** on the
  /// correctness path: the decoded chunks are the placed points a settled orbit
  /// vault reconstructs `Sh_i` (hence `K_i`) from, which is why an invalid
  /// decode is reported as null rather than silently dropped. Errors surface as
  /// a [StateError]; the empty batch resolves to `[]` without spawning.
  Future<List<List<int>?>> decodePoints(
    List<List<int>> points,
    List<List<int>> reservoirs,
  ) async {
    if (points.isEmpty) return const <List<int>?>[];
    final ReceivePort port = ReceivePort();
    final Completer<List<List<int>?>> completer = Completer<List<List<int>?>>();
    await Isolate.spawn<(SendPort, List<List<int>>, List<List<int>>)>(
      _decodePointsIsolateEntry,
      (port.sendPort, points, reservoirs),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    port.listen((dynamic msg) {
      // Success payload is a `List<List<int>?>` (null = invalid decode); the
      // onError payload is a `[message, stack]` list of strings. Distinguish by
      // element type rather than the reified generic, which is not guaranteed
      // across the boundary.
      final bool decoded =
          msg is List && (msg.isEmpty || msg.first == null || msg.first is List);
      if (decoded) {
        if (!completer.isCompleted) {
          completer.complete(<List<int>?>[
            for (final dynamic b in msg as List)
              if (b == null)
                null
              else
                <int>[for (final dynamic v in b as List) v as int],
          ]);
        }
      } else if (!completer.isCompleted) {
        completer.completeError(StateError('Point decode failed'));
      }
      port.close();
    });
    return completer.future;
  }

  /// Start a **cancellable** on-device Argon2 micro-benchmark at [profile] in a
  /// worker isolate (heavy, blocking), returning an [Argon2BenchJob] whose
  /// `result` is the **median** seconds per pass (one pass == one derivation
  /// step) over [passes] timed passes. One untimed warm-up pass faults in the
  /// profile's memory first. [onProgress] is called `(done, total)` after the
  /// warm-up and after each timed pass (`total == 1 + passes`), for a
  /// determinate progress bar. `cancel()` kills the isolate and fails `result`
  /// with [Argon2Cancelled]; `result` errors with [StateError] if the profile
  /// can't be allocated (e.g. the 32/128 GiB tiers on a phone).
  Future<Argon2BenchJob> startBenchArgon2({
    Argon2Profile profile = Argon2Profile.basic,
    int passes = 3,
    void Function(int done, int total)? onProgress,
  }) async {
    final ReceivePort port = ReceivePort();
    final Completer<double> completer = Completer<double>();
    final Isolate isolate = await Isolate.spawn<(SendPort, int, int)>(
      _argon2BenchIsolateEntry,
      (port.sendPort, profile.value, passes < 1 ? 1 : passes),
      onError: port.sendPort,
      errorsAreFatal: true,
    );
    void cleanup() => port.close();
    port.listen((dynamic msg) {
      if (msg is (int, int)) {
        // Progress tick — does not complete the job.
        onProgress?.call(msg.$1, msg.$2);
      } else if (msg is double) {
        if (!completer.isCompleted) completer.complete(msg);
        cleanup();
      } else {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Argon2 calibration failed'));
        }
        cleanup();
      }
    });
    void cancel() {
      if (completer.isCompleted) return;
      isolate.kill(priority: Isolate.immediate);
      cleanup();
      completer.completeError(const Argon2Cancelled());
    }
    return Argon2BenchJob(completer.future, cancel);
  }

  /// Convenience wrapper: run a benchmark and await its result (not cancellable).
  Future<double> benchArgon2({
    Argon2Profile profile = Argon2Profile.basic,
    int passes = 3,
  }) async {
    final Argon2BenchJob job =
        await startBenchArgon2(profile: profile, passes: passes);
    return job.result;
  }
}

/// Worker-isolate entry: open the engine, run one untimed warm-up pass, then
/// time [passes] passes at the given profile and return the **median** seconds
/// per pass. Emits a `(done, total)` progress tick after the warm-up and after
/// each timed pass (`total == 1 + passes`).
void _argon2BenchIsolateEntry((SendPort, int, int) args) {
  final (SendPort send, int profileValue, int passes) = args;
  final Argon2Profile profile = Argon2Profile.values[profileValue];
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final Uint8List input = Uint8List(8);
  final int total = 1 + passes;
  // Warm-up (fault in the profile's pages) — not timed.
  bindings.argon2Single(input, profile);
  send.send((1, total));
  final List<double> times = <double>[];
  for (int i = 0; i < passes; i++) {
    final Stopwatch sw = Stopwatch()..start();
    bindings.argon2Single(input, profile);
    sw.stop();
    times.add(sw.elapsedMicroseconds / 1e6);
    send.send((2 + i, total));
  }
  // Median is robust to a stray scheduling/contention spike.
  times.sort();
  final int m = times.length;
  final double median = m.isOdd
      ? times[m ~/ 2]
      : (times[m ~/ 2 - 1] + times[m ~/ 2]) / 2.0;
  send.send(median);
}

/// Worker-isolate entry: open the engine, run the single Argon2id master pass
/// over the transcript [message] and return its [outLen] bytes.
void _argon2idMasterIsolateEntry((SendPort, Uint8List, int) args) {
  final (SendPort send, Uint8List message, int outLen) = args;
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final Uint8List out = bindings.argon2idMaster(message, outLen: outLen);
  send.send(out);
}

/// Worker-isolate entry: open the engine and run one orbit step, sending back
/// `(K_i, o_next)`. The engine zeroizes the raw `{o_i, Sh_i}` copies before the
/// memory-hard advance (orbit.rs `orbit_step`).
void _orbitAdvanceIsolateEntry((SendPort, Uint8List, Uint8List, int, int) args) {
  final (SendPort send, Uint8List oI, Uint8List sh, int steps, int profileValue) =
      args;
  final Argon2Profile profile = Argon2Profile.values[profileValue];
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final ({Uint8List k, Uint8List next}) r =
      bindings.orbitAdvance(oI, sh, steps, profile);
  send.send((r.k, r.next));
}

/// Worker-isolate entry: open the engine and encode each 32-bit chunk to a
/// fractal point under its `[o, p, q]` reservoir, sending back a
/// `List<[reRaw, imRaw]>` in input order. Mirrors [GreatWallCore.encodeStage]
/// off the UI isolate — see [GreatWallCore.encodeSharePoints].
void _encodeSharesIsolateEntry(
    (SendPort, List<List<int>>, List<List<int>>) args) {
  final (SendPort send, List<List<int>> chunks, List<List<int>> reservoirs) =
      args;
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final FixedRect area = bindings.encodeArea();
  final CoreDiscoveryParams params = bindings.encodeParams();
  final List<List<int>> out = <List<int>>[];
  for (int i = 0; i < chunks.length; i++) {
    final List<int> res = reservoirs[i];
    final ({int reRaw, int imRaw, FixedRect leafRect}) pt = bindings.encodePoint(
      bits: chunks[i],
      area: area,
      params: params,
      o: res[0],
      p: res[1],
      q: res[2],
    );
    out.add(<int>[pt.reRaw, pt.imRaw]);
  }
  send.send(out);
}

/// Worker-isolate entry: open the engine and decode each `[reRaw, imRaw]` point
/// under its `[o, p, q]` reservoir, sending back a `List<List<int>?>` of 32-bit
/// chunks in input order (null where the point is not a valid leaf). Mirrors
/// [GreatWallCore.decodePoint] off the UI isolate — see
/// [GreatWallCore.decodePoints].
void _decodePointsIsolateEntry(
    (SendPort, List<List<int>>, List<List<int>>) args) {
  final (SendPort send, List<List<int>> points, List<List<int>> reservoirs) =
      args;
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final FixedRect area = bindings.encodeArea();
  final CoreDiscoveryParams params = bindings.encodeParams();
  final List<List<int>?> out = <List<int>?>[];
  for (int i = 0; i < points.length; i++) {
    final List<int> res = reservoirs[i];
    final CoreDecodeResult d = bindings.decodeFull(
      pointReRaw: points[i][0],
      pointImRaw: points[i][1],
      numBits: EncodingConstants.bitsPerPoint,
      area: area,
      params: params,
      o: res[0],
      p: res[1],
      q: res[2],
    );
    out.add(d.valid ? d.bits : null);
  }
  send.send(out);
}

/// Worker-isolate entry: open the engine, run the Argon2 loop, and after each
/// pass stream back a `(passIndex, digest)` record. Streaming every
/// intermediary digest (not just the count) is what lets a halt mid-stage keep
/// the work done so far: the main isolate retains the latest one, so killing
/// the in-flight pass costs at most that single pass. The last record
/// (`passIndex == iterations`) carries the final digest.
void _argon2IsolateEntry((SendPort, Uint8List, int, int) args) {
  final (SendPort send, Uint8List input, int iterations, int profileValue) = args;
  final Argon2Profile profile = Argon2Profile.values[profileValue];
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  Uint8List digest = bindings.argon2Single(input, profile);
  send.send((1, digest));
  for (int i = 1; i < iterations; i++) {
    digest = bindings.argon2Single(digest, profile);
    send.send((i + 1, digest));
  }
}

/// Worker-isolate entry for a resumed stage: continue the chain from
/// [fromDigest] (the result after [fromPass] passes) for the remaining passes,
/// streaming each `(pass, digest)` exactly like [_argon2IsolateEntry] so the
/// pass indices stay continuous with what the halt had already counted.
void _argon2ResumeIsolateEntry((SendPort, Uint8List, int, int, int) args) {
  final (SendPort send, Uint8List fromDigest, int fromPass, int iterations,
      int profileValue) = args;
  final Argon2Profile profile = Argon2Profile.values[profileValue];
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  Uint8List digest = fromDigest;
  for (int i = fromPass; i < iterations; i++) {
    digest = bindings.argon2Single(digest, profile);
    send.send((i + 1, digest));
  }
}

/// A running stage derivation: its [result], and a [cancel] that kills the
/// worker isolate and fails [result] with [Argon2Cancelled].
class Argon2Job {
  Argon2Job(this.result, this._cancel);

  final Future<StageReservoirs> result;
  final void Function() _cancel;

  void cancel() => _cancel();
}

/// A running calibration benchmark: its [result] (seconds per pass) and a
/// [cancel] that kills the worker isolate and fails [result] with
/// [Argon2Cancelled].
class Argon2BenchJob {
  Argon2BenchJob(this.result, this._cancel);

  final Future<double> result;
  final void Function() _cancel;

  void cancel() => _cancel();
}

/// An encoded fractal point in raw I4F60 coordinates, with the leaf rectangle
/// the bisection settled on. The leaf's centre is this stage's coordinate in
/// the master-secret export transcript (see `MasterSecret.leafCentreRaw`).
class EncodedPoint {
  const EncodedPoint({
    required this.reRaw,
    required this.imRaw,
    required this.leafRect,
  });
  final int reRaw;
  final int imRaw;
  final FixedRect leafRect;

  /// `toString` is redacted: a point's coordinates are coercion-relevant
  /// material (SCOPE.md "no logs of fractal coordinates").
  @override
  String toString() => 'EncodedPoint(<redacted>)';
}

/// Completes [Argon2Job.result] when the derivation is cancelled via
/// [Argon2Job.cancel].
class Argon2Cancelled implements Exception {
  const Argon2Cancelled();
  @override
  String toString() => 'Argon2Cancelled';
}
