import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/core_bindings.dart';
import '../ffi/library_loader.dart';
import 'core_escape_count_source.dart';
import 'encoding_constants.dart';
import 'entropy.dart';
import 'stage2_params.dart';

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

  /// Encode one stage's worth of bits into fractal points (32 bits/point).
  ///
  /// `(o, p, q)` selects the fractal: `(0,0,0)` for stage 1, the session
  /// reservoirs for stage 2. Returns one encoded point per 32-bit chunk.
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

  /// Derive `(o, p, q)` from stage-1 bits by running `iterations` Argon2d
  /// passes, feeding each digest back as the next input — the iterative
  /// scheme of `run_argon2_iterative` (argon2_pipeline.py).
  ///
  /// `iterations == 0` is the identity case: the 8-byte stage-1 input
  /// right-padded to the 32-byte digest, no Argon2 (used for fast dev runs).
  ///
  /// [onProgress] reports completed passes; [shouldStop] is polled between
  /// passes for cancellation (the in-flight Rust call is not interruptible).
  ///
  /// Each pass runs in a worker isolate via [Isolate.run] (which opens its own
  /// engine binding — FFI handles cannot cross isolates), so the heavy,
  /// blocking Argon2 call never stalls the UI isolate. This is the two-tier
  /// threading model from TECH_STACK.md §"Threading model": the UI isolate
  /// dispatches work units and awaits results instead of blocking, which is
  /// what keeps the OS from raising an "application not responding" dialog.
  Future<Stage2Reservoirs> deriveStage2Reservoirs(
    List<int> stage1Bits, {
    required int iterations,
    Argon2Profile profile = Argon2Profile.basic,
    void Function(int completed, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final int total = iterations < 1 ? 1 : iterations;
    Uint8List digest;
    if (iterations == 0) {
      final Uint8List input = Entropy.stage1Argon2Input(stage1Bits);
      digest = Uint8List(32)..setRange(0, 8, input);
      onProgress?.call(1, total);
    } else {
      final Uint8List input = Entropy.stage1Argon2Input(stage1Bits);
      digest = await _argon2PassInIsolate(input, profile);
      onProgress?.call(1, total);
      for (int i = 1; i < iterations; i++) {
        if (shouldStop?.call() ?? false) {
          throw const Argon2Cancelled();
        }
        digest = await _argon2PassInIsolate(digest, profile);
        onProgress?.call(i + 1, total);
      }
    }
    final Stage2Reservoirs reservoirs = Stage2Reservoirs.fromArgon2Digest(digest);
    // Wipe the digest copy; reservoirs are the only thing the session keeps.
    digest.fillRange(0, digest.length, 0);
    return reservoirs;
  }
}

/// Run one Argon2d pass on a worker isolate.
///
/// The closure captures only sendable values (a copy of [input] and the
/// [profile] enum) and opens a fresh engine binding inside the isolate, since a
/// [DynamicLibrary]/FFI handle from the parent isolate cannot be sent across.
Future<Uint8List> _argon2PassInIsolate(Uint8List input, Argon2Profile profile) {
  final Uint8List inputCopy = Uint8List.fromList(input);
  return Isolate.run<Uint8List>(() {
    final GreatWallCoreBindings bindings = GreatWallCoreBindings.open();
    return bindings.argon2Single(inputCopy, profile);
  });
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

/// Thrown by [GreatWallCore.deriveStage2Reservoirs] when cancelled.
class Argon2Cancelled implements Exception {
  const Argon2Cancelled();
  @override
  String toString() => 'Argon2Cancelled';
}
