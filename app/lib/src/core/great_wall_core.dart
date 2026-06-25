import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/core_bindings.dart';
import '../ffi/library_loader.dart';
import 'core_escape_count_source.dart';
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
  Future<Argon2Job> startStageDerivation(
    Uint8List input, {
    required int iterations,
    Argon2Profile profile = Argon2Profile.basic,
    void Function(int completed, int total)? onProgress,
  }) async {
    final int total = iterations < 1 ? 1 : iterations;

    if (iterations == 0) {
      // Identity case: data.ljust(32, 0)[:32] (argon2_pipeline.py).
      final int n = input.length < 32 ? input.length : 32;
      final Uint8List digest = Uint8List(32)..setRange(0, n, input);
      onProgress?.call(1, total);
      final StageReservoirs r = StageReservoirs.fromArgon2Digest(digest);
      digest.fillRange(0, digest.length, 0);
      return Argon2Job(Future<StageReservoirs>.value(r), () {});
    }

    final ReceivePort port = ReceivePort();
    final Completer<StageReservoirs> completer = Completer<StageReservoirs>();
    final Isolate isolate = await Isolate.spawn<(SendPort, Uint8List, int, int)>(
      _argon2IsolateEntry,
      (port.sendPort, input, iterations, profile.value),
      onError: port.sendPort,
      errorsAreFatal: true,
    );

    void cleanup() => port.close();

    port.listen((dynamic msg) {
      if (msg is int) {
        onProgress?.call(msg, total);
      } else if (msg is Uint8List) {
        final StageReservoirs r = StageReservoirs.fromArgon2Digest(msg);
        msg.fillRange(0, msg.length, 0);
        if (!completer.isCompleted) completer.complete(r);
        cleanup();
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
}

/// Worker-isolate entry: open the engine, run the single Argon2id master pass
/// over the transcript [message] and return its [outLen] bytes.
void _argon2idMasterIsolateEntry((SendPort, Uint8List, int) args) {
  final (SendPort send, Uint8List message, int outLen) = args;
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  final Uint8List out = bindings.argon2idMaster(message, outLen: outLen);
  send.send(out);
}

/// Worker-isolate entry: open the engine, run the Argon2 loop, stream progress
/// (`int` after each pass) and finally the 32-byte digest (`Uint8List`).
void _argon2IsolateEntry((SendPort, Uint8List, int, int) args) {
  final (SendPort send, Uint8List input, int iterations, int profileValue) = args;
  final Argon2Profile profile = Argon2Profile.values[profileValue];
  final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
  Uint8List digest = bindings.argon2Single(input, profile);
  send.send(1);
  for (int i = 1; i < iterations; i++) {
    digest = bindings.argon2Single(digest, profile);
    send.send(i + 1);
  }
  send.send(digest);
}

/// A running stage derivation: its [result], and a [cancel] that kills the
/// worker isolate and fails [result] with [Argon2Cancelled].
class Argon2Job {
  Argon2Job(this.result, this._cancel);

  final Future<StageReservoirs> result;
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
