import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:great_wall_ux/great_wall_ux.dart';

import '../ffi/core_bindings.dart';
import 'stage_params.dart';

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
///  - Route the canonical stage to the canonical renderer and any chain-derived
///    stage to the perturbed renderer using the currently displayed stage's
///    [StageReservoirs].
class CoreEscapeCountSource implements EscapeCountSource {
  CoreEscapeCountSource(this._core);

  final GreatWallCoreBindings _core;

  /// The reservoirs `(o, p, q)` for the fractal currently being rendered — the
  /// chained stage on screen. The Setup/Train orchestrator sets this whenever
  /// the displayed stage changes (to the canonical stage's `null`, or to a
  /// chain-derived stage's reservoirs once Argon2 has produced `(o, p, q)`).
  ///
  /// Why the reservoirs live here and not on the request: great-wall-ux's
  /// [StageParameters] carries three `double`s, but the engine's perturbation
  /// is three raw `u64` reservoirs that cannot be represented losslessly as
  /// doubles. Rather than fork the UX library's public seam, the app keeps the
  /// authoritative `u64`s here and uses [StageParameters] only as a non-secret
  /// repaint key (see [StageReservoirs.displayKey]). Widening the UX seam to
  /// carry raw reservoirs is a sensible follow-up; until then this is the
  /// minimal, library-preserving bridge.
  StageReservoirs? reservoirs;

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

    // The engine samples pixel (cx, cy) at (originRe + cx*u, originIm + cy*u),
    // writing row cy in increasing-imaginary order. We return the buffer in
    // that natural order (no flip); combined with the Flutter image sampler's
    // vertical origin and great-wall-ux's ViewportMath (imaginary axis up),
    // this displays the Burning Ship upright with overlays aligned. See
    // escapeCountsFromPixels for the orientation note.
    final double originRe = vp.centreRe + (0.5 - w / 2.0) * u;
    final double originIm = vp.centreIm + (0.5 - h / 2.0) * u;

    // Every stage renders through the *perturbed* engine path. This is
    // load-bearing, not an optimisation: `bs_encode` always encodes through
    // `escape_count_generic` (great-wall-core/discovery.rs), and at (0,0,0)
    // that formula still applies p's +1/8 baseline. The canonical
    // `bs_render_viewport` (pure z0=0, no shift) draws a *different* fractal,
    // so canonical-stage points — chosen on the baseline fractal — would appear
    // to fall in the canonical "hole". Rendering stage 0 as generic(0,0,0) makes
    // the displayed fractal the same one the points were encoded on. Later
    // stages render with their chain-derived reservoirs.
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

  StageReservoirs _requireReservoirs() {
    final StageReservoirs? r = reservoirs;
    if (r == null) {
      throw StateError(
        'Perturbed-stage render requested before (o, p, q) were derived. '
        'Set CoreEscapeCountSource.reservoirs after Argon2 completes.',
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
/// No row flip: the buffer is returned in the engine's natural row order
/// (`counts[y]` = `originIm + y*step`). Empirically, the Flutter image-sampler
/// pipeline plus great-wall-ux's `ViewportMath` (imaginary axis up) render this
/// upright with overlays, pan, and zoom-to-cursor all aligned. (If a rendering
/// backend ever shows the fractal vertically mirrored, this is the single place
/// to flip rows — `counts[(h-1-y)*w + x]`.)
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
