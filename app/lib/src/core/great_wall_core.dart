import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/core_bindings.dart';
import '../ffi/library_loader.dart';
import 'core_escape_count_source.dart';
import 'encoding_constants.dart';
import 'entropy.dart';
import 'stage_params.dart';

/// App-level facade over great-wall-core: opens the engine once, exposes the
/// [EscapeCountSource] for the UX canvas, and wraps the encode / decode /
/// Argon2 calls the orchestration needs.
///
/// One instance is shared for the app's lifetime; the engine's internal
/// thread pool (TECH_STACK.md §"Threading model") parallelises the renders.
class GreatWallCore {
  GreatWallCore._(this.bindings) : source = CoreEscapeCountSource(bindings);

  /// Open and bind the engine library. Throws [CoreLibraryNotFound] if the
  /// `cdylib` has not been built (run `native/build_core.sh`).
  factory GreatWallCore.open({CoreLibraryLoader loader = const CoreLibraryLoader()}) {
    return GreatWallCore._(GreatWallCoreBindings.open(loader: loader));
  }

  final GreatWallCoreBindings bindings;

  /// The production [EscapeCountSource] handed to great-wall-ux's FractalCanvas.
  final CoreEscapeCountSource source;

  /// Engine algorithm version (e.g. `"0.1.0"`).
  String get engineVersion => bindings.engineVersion();

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
    final FixedRect area = EncodingConstants.encodeArea();
    const CoreDiscoveryParams params = EncodingConstants.guiParams;
    final int n = stageBits.length ~/ EncodingConstants.bitsPerPoint;
    final List<EncodedPoint> points = <EncodedPoint>[];
    for (int i = 0; i < n; i++) {
      final List<int> chunk = stageBits.sublist(
        i * EncodingConstants.bitsPerPoint,
        (i + 1) * EncodingConstants.bitsPerPoint,
      );
      final ({int reRaw, int imRaw}) pt = bindings.encodePoint(
        bits: chunk,
        area: area,
        params: params,
        o: o,
        p: p,
        q: q,
      );
      points.add(EncodedPoint(reRaw: pt.reRaw, imRaw: pt.imRaw));
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
      area: EncodingConstants.encodeArea(),
      params: EncodingConstants.guiParams,
      o: o,
      p: p,
      q: q,
    );
  }

  /// Derive a chained stage's `(o, p, q)` from the cumulative bits of every
  /// preceding point, by running `iterations` Argon2d passes and feeding each
  /// digest back as the next input — the iterative scheme of
  /// `derive_stage_params` / `argon2_iterate` (argon2_pipeline.py). This is one
  /// link of the chain: `priorBits` is the concatenation of points `0..k-1`,
  /// so the input grows by 32 bits per stage.
  ///
  /// `iterations == 0` is the identity case (the natural-length input
  /// zero-padded/truncated to the 32-byte digest, no Argon2) used for fast dev
  /// runs.
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
    List<int> priorBits, {
    required int iterations,
    Argon2Profile profile = Argon2Profile.basic,
    void Function(int completed, int total)? onProgress,
  }) async {
    final int total = iterations < 1 ? 1 : iterations;

    if (iterations == 0) {
      // Identity case: data.ljust(32, 0)[:32] (argon2_pipeline.py). The input
      // is the natural-length prior-point bytes (not padded to a fixed width).
      final Uint8List input = Entropy.argon2Input(priorBits);
      final int n = input.length < 32 ? input.length : 32;
      final Uint8List digest = Uint8List(32)..setRange(0, n, input);
      onProgress?.call(1, total);
      final StageReservoirs r = StageReservoirs.fromArgon2Digest(digest);
      digest.fillRange(0, digest.length, 0);
      return Argon2Job(Future<StageReservoirs>.value(r), () {});
    }

    final Uint8List input = Entropy.argon2Input(priorBits);
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

/// An encoded fractal point in raw I4F60 coordinates.
class EncodedPoint {
  const EncodedPoint({required this.reRaw, required this.imRaw});
  final int reRaw;
  final int imRaw;

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
