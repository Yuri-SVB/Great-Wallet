import 'package:great_wall_ux/great_wall_ux.dart';

import '../ffi/core_bindings.dart';
import '../ffi/fixed.dart';
import 'encoding_constants.dart';
import 'stage_params.dart';

/// The integration seam: a great-wall-ux [LeafAreaSource] backed by the real
/// great-wall-core engine.
///
/// The sibling of [CoreEscapeCountSource]. great-wall-ux defines
/// [LeafAreaSource] as the boundary and ships only a stub; this is the
/// production implementation great-wallet plugs in. It maps a [FractalViewport]
/// to the engine's `(origin, step)` scan, routes the canonical / chain-derived
/// `(o, p, q)`, and converts the engine's raw I4F60 leaf rectangles to the
/// doubles the UX layer expects.
///
/// Cost note: enumeration runs many decodes (a full bisection with island
/// discovery per sampled point), so it is far heavier than a raster frame. It
/// is intended to fire when the view *settles* (debounced), not per pan frame,
/// and is a candidate to move off the UI isolate later — the same trajectory as
/// the canonical-island discovery (~220 ms) noted in
/// great-wall-docs/next-steps/canonical-island-entropy-crystals.md §4.
class CoreLeafAreaSource implements LeafAreaSource {
  CoreLeafAreaSource(this._bindings);

  final GreatWallCoreBindings _bindings;

  /// Canonical decode area + params, fetched once from the engine (its single
  /// source of truth — the wallet never hard-codes them; see
  /// [GreatWallCoreBindings.encodeParams]). Leaf enumeration decodes against
  /// exactly these, identically to a tap-decode.
  late final FixedRect _area = _bindings.encodeArea();
  late final CoreDiscoveryParams _params = _bindings.encodeParams();

  /// The reservoirs `(o, p, q)` for the fractal currently displayed — kept in
  /// sync with [CoreEscapeCountSource.reservoirs] by the orchestrator. The same
  /// double→u64 reasoning applies: great-wall-ux's [StageParameters] carries
  /// `double`s that cannot represent the raw `u64` reservoirs losslessly, so the
  /// authoritative values live here, not on the request. Using a different
  /// surface than the one the points were encoded on would make leaf membership
  /// meaningless, so this must match the encode-time `(o, p, q)`.
  StageReservoirs? reservoirs;

  @override
  Future<LeafAreasResult> leafAreas(LeafAreasRequest request) async {
    final CoreLeafAreasResult res = leafAreasRaw(request);
    if (res.tooMany) {
      return LeafAreasResult.tooMany(res.maxLeaves);
    }
    return LeafAreasResult.leaves(<LeafArea>[
      for (final CoreLeafArea leaf in res.leaves)
        LeafArea(
          reMin: fixedToDouble(leaf.rect.reMin),
          reMax: fixedToDouble(leaf.rect.reMax),
          imMin: fixedToDouble(leaf.rect.imMin),
          imMax: fixedToDouble(leaf.rect.imMax),
          path: leaf.path,
        ),
    ]);
  }

  /// Enumerate leaf areas returning the **raw** engine result — the exact I4F60
  /// (`int`) leaf rectangles, not the lossy `double` [LeafArea]s that [leafAreas]
  /// hands the UX layer for drawing. Callers that feed a leaf rect *back into the
  /// engine* (e.g. `canonicalIsland`) MUST use this: island discovery is
  /// sensitive to sub-`double` precision, so a `Fixed → double → Fixed`
  /// round-trip on the rect can change which island is returned — which would
  /// make an `E`-revealed island disagree with the one a click on it resolves.
  CoreLeafAreasResult leafAreasRaw(LeafAreasRequest request) {
    final FractalViewport vp = request.viewport;
    final int w = vp.widthPx;
    final int h = vp.heightPx;

    // Identical mapping to CoreEscapeCountSource so the scan grid lines up with
    // the rendered raster pixel-for-pixel (square pixels in fractal space).
    final int shortPx = w < h ? w : h;
    final double u = (2.0 * vp.halfExtent) / shortPx;
    final double originRe = vp.centreRe + (0.5 - w / 2.0) * u;
    final double originIm = vp.centreIm + (0.5 - h / 2.0) * u;

    // Coarse-grid clamp: raise the scan step so neither axis exceeds the sample
    // cap, regardless of canvas size (the grid is pixels / step). The decode
    // budget is the hard cost cap; this just keeps the loop itself bounded.
    final int maxAxis = w > h ? w : h;
    final int axisCap = EncodingConstants.leafEnumMaxAxisSamples;
    final int minScan = (maxAxis + axisCap - 1) ~/ axisCap; // ceil(maxAxis/cap)
    final int scanStep =
        request.scanStep > minScan ? request.scanStep : minScan;

    // Canonical stage decodes on generic(0,0,0); a chain stage on its
    // reservoirs — matching the encode-time surface (see CoreEscapeCountSource).
    final int o = request.stage == Stage.stage2 ? _requireReservoirs().o : 0;
    final int p = request.stage == Stage.stage2 ? _requireReservoirs().p : 0;
    final int q = request.stage == Stage.stage2 ? _requireReservoirs().q : 0;

    return _bindings.enumerateLeafAreas(
      originRe: originRe,
      originIm: originIm,
      step: u,
      width: w,
      height: h,
      scanStep: scanStep,
      maxLeaves: request.maxLeaves,
      maxDecodes: EncodingConstants.leafEnumMaxDecodes,
      area: _area,
      params: _params,
      numBits: request.numBits,
      o: o,
      p: p,
      q: q,
    );
  }

  StageReservoirs _requireReservoirs() {
    final StageReservoirs? r = reservoirs;
    if (r == null) {
      throw StateError(
        'Perturbed-stage leaf enumeration requested before (o, p, q) were '
        'derived. Set CoreLeafAreaSource.reservoirs after Argon2 completes.',
      );
    }
    return r;
  }
}
