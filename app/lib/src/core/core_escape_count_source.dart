import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:great_wall_ux/great_wall_ux.dart';

import '../ffi/core_bindings.dart';
import 'stage2_params.dart';

/// The integration seam: a great-wall-ux [EscapeCountSource] backed by the
/// real great-wall-core engine.
///
/// great-wall-ux never computes escape counts itself — "the Burning Ship is
/// computed by the Rust core" (SCOPE.md). The library defines [EscapeCountSource]
/// as the boundary and ships only stub/demo implementations; **this class is
/// the production implementation that great-wallet plugs in**, satisfying the
/// dependency-matrix row `great-wall-ux -> great-wall-core` at the app layer
/// (ARCHITECTURE.md §"Dependency Graph").
///
/// Responsibilities:
///  - Map a [FractalViewport] to the engine's `(origin, step)` raster call.
///  - Convert the engine's `u8` escape-count buffer to the [Uint32List] the
///    UX layer expects, including the vertical flip that reconciles the two
///    coordinate conventions (see [escapeCountsFromPixels]).
///  - Route stage-1 to the canonical renderer and stage-2 to the perturbed
///    renderer using the session's [Stage2Reservoirs].
class CoreEscapeCountSource implements EscapeCountSource {
  CoreEscapeCountSource(this._core);

  final GreatWallCoreBindings _core;

  /// The active session's stage-2 reservoirs, set by the Setup/Train
  /// orchestrator once Argon2 has produced `(o, p, q)`.
  ///
  /// Why the reservoirs live here and not on the request: great-wall-ux's
  /// [StageParameters] carries three `double`s, but the engine's perturbation
  /// is three raw `u64` reservoirs that cannot be represented losslessly as
  /// doubles. Rather than fork the UX library's public seam, the app keeps the
  /// authoritative `u64`s here and uses [StageParameters] only as a non-secret
  /// repaint key (see [Stage2Reservoirs.displayKey]). Widening the UX seam to
  /// carry raw reservoirs is a sensible follow-up; until then this is the
  /// minimal, library-preserving bridge.
  Stage2Reservoirs? stage2Reservoirs;

  @override
  Future<EscapeCountRaster> escapeCounts(EscapeCountRequest request) async {
    final FractalViewport vp = request.viewport;
    final int w = vp.widthPx;
    final int h = vp.heightPx;
    final int maxIter = request.maxIterations;

    // Units per logical pixel on the shorter axis (square pixels in fractal
    // space) — identical to great-wall-ux's ViewportMath.unitsPerPixel.
    final int shortPx = w < h ? w : h;
    final double u = (2.0 * vp.halfExtent) / shortPx;

    // Top-left sample point. The engine samples pixel (cx, cy) at
    // (originRe + cx*u, originIm + cy*u); pairing this origin with a vertical
    // row flip (below) reproduces ViewportMath's pixel<->coord mapping exactly.
    final double originRe = vp.centreRe + (0.5 - w / 2.0) * u;
    final double originIm = vp.centreIm + (0.5 - h / 2.0) * u;

    // Both stages render through the *perturbed* engine path. This is
    // load-bearing, not an optimisation: `bs_encode` always encodes through
    // `escape_count_generic` (great-wall-core/discovery.rs), and at (0,0,0)
    // that formula still applies p's +1/8 baseline. The canonical
    // `bs_render_viewport` (pure z0=0, no shift) draws a *different* fractal,
    // so stage-1 points — chosen on the baseline fractal — would appear to
    // fall in the canonical "hole". Rendering stage 1 as generic(0,0,0) makes
    // the displayed fractal the same one the points were encoded on.
    final int o = request.stage == Stage.stage2 ? _requireReservoirs().o : 0;
    final int p = request.stage == Stage.stage2 ? _requireReservoirs().p : 0;
    final int q = request.stage == Stage.stage2 ? _requireReservoirs().q : 0;

    final Pointer<Uint8> out = ffi.calloc<Uint8>(w * h);
    try {
      _core.renderViewportGeneric(
        originRe: originRe,
        originIm: originIm,
        step: u,
        width: w,
        height: h,
        maxIter: maxIter,
        o: o,
        p: p,
        q: q,
        out: out,
      );
      final Uint8List pixels = Uint8List.fromList(out.asTypedList(w * h));
      final Uint32List counts = escapeCountsFromPixels(pixels, w, h, maxIter);
      return EscapeCountRaster(
        widthPx: w,
        heightPx: h,
        maxIterations: maxIter,
        counts: counts,
      );
    } finally {
      ffi.calloc.free(out);
    }
  }

  Stage2Reservoirs _requireReservoirs() {
    final Stage2Reservoirs? r = stage2Reservoirs;
    if (r == null) {
      throw StateError(
        'Stage-2 render requested before (o, p, q) were derived. '
        'Set CoreEscapeCountSource.stage2Reservoirs after Argon2 completes.',
      );
    }
    return r;
  }
}

/// Convert great-wall-core's `u8` escape-count buffer into the [Uint32List]
/// great-wall-ux expects.
///
/// Engine encoding (ffi.rs): `0` for non-escaping ("inside the set") pixels,
/// `(escape_count % 255) + 1` otherwise. great-wall-ux's shader expects raw
/// escape counts with non-escaping == `maxIterations` (its demo source fills
/// the inside disk with `maxIter`), so:
///   - `0`          -> `maxIterations`   (inside / non-escaping)
///   - `v` (1..255) -> `v - 1`           (the true escape count)
///
/// No row flip: the engine samples pixel `(cx, cy)` at `originIm + cy*step`
/// (imaginary axis increasing downward), and `ViewportMath` now uses the same
/// downward convention, so engine row `y` maps directly to UX row `y`. This
/// keeps the displayed raster aligned pixel-for-pixel with the coordinate a
/// tap decodes.
///
/// Pure and dependency-free so it is unit-testable without Flutter or FFI.
Uint32List escapeCountsFromPixels(
  Uint8List pixels,
  int width,
  int height,
  int maxIterations,
) {
  final Uint32List counts = Uint32List(width * height);
  for (int i = 0; i < width * height; i++) {
    final int v = pixels[i];
    counts[i] = v == 0 ? maxIterations : (v - 1);
  }
  return counts;
}
