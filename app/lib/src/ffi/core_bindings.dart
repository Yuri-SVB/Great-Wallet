import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fixed.dart';
import 'library_loader.dart';

/// Raw `dart:ffi` binding to great-wall-core's C ABI
/// (great-wall-core/burning_ship/rust_engine/src/ffi.rs).
///
/// This is the *only* place in great-wallet that talks to the engine's
/// `extern "C"` symbols. It is a faithful Dart port of the Python ctypes
/// bridge (great-wall-core/burning_ship/burning_ship_engine.py): same
/// argument order, same raw-`i64` fixed-point convention, same buffer
/// ownership rules.
///
/// Per great-wall-docs/great-wall-ux/TECH_STACK.md §"FFI: hybrid", the
/// per-frame pixel-buffer path (`renderViewport*`) uses raw `dart:ffi` to
/// avoid bridge overhead and copies; the control plane (encode/decode/argon2)
/// rides the same binding for simplicity.
///
/// SECURITY: nothing here logs coordinates, escape counts, decoded bits, or
/// `(o, p, q)`. Those are coercion-relevant (SCOPE.md invariants) and stay in
/// ephemeral buffers that callers are expected to zero and free.
class GreatWallCoreBindings {
  GreatWallCoreBindings._(this._lib) {
    _renderViewport = _lib.lookupFunction<_RenderViewportC, _RenderViewportDart>(
      'bs_render_viewport',
    );
    _renderViewportGeneric =
        _lib.lookupFunction<_RenderViewportGenericC, _RenderViewportGenericDart>(
      'bs_render_viewport_generic',
    );
    _encode = _lib.lookupFunction<_EncodeC, _EncodeDart>('bs_encode');
    _encodeResultPoint =
        _lib.lookupFunction<_EncodeResultPointC, _EncodeResultPointDart>(
      'bs_encode_result_point',
    );
    _encodeResultFinalRect =
        _lib.lookupFunction<_EncodeResultFinalRectC, _EncodeResultFinalRectDart>(
      'bs_encode_result_final_rect',
    );
    _encodeResultFree =
        _lib.lookupFunction<_EncodeResultFreeC, _EncodeResultFreeDart>(
      'bs_encode_result_free',
    );
    _decodeFull =
        _lib.lookupFunction<_DecodeFullC, _DecodeFullDart>('bs_decode_full');
    _leafAreasCompute =
        _lib.lookupFunction<_LeafAreasComputeC, _LeafAreasComputeDart>(
      'bs_leaf_areas_compute',
    );
    _leafAreasStatus =
        _lib.lookupFunction<_LeafAreasStatusC, _LeafAreasStatusDart>(
      'bs_leaf_areas_status',
    );
    _leafAreasCount =
        _lib.lookupFunction<_LeafAreasCountC, _LeafAreasCountDart>(
      'bs_leaf_areas_count',
    );
    _leafAreasRect =
        _lib.lookupFunction<_LeafAreasRectC, _LeafAreasRectDart>(
      'bs_leaf_areas_rect',
    );
    _leafAreasPath =
        _lib.lookupFunction<_LeafAreasPathC, _LeafAreasPathDart>(
      'bs_leaf_areas_path',
    );
    _leafAreasFree =
        _lib.lookupFunction<_LeafAreasFreeC, _LeafAreasFreeDart>(
      'bs_leaf_areas_free',
    );
    _argon2Single =
        _lib.lookupFunction<_Argon2SingleC, _Argon2SingleDart>('bs_argon2_single');
    _argon2idMaster =
        _lib.lookupFunction<_Argon2idMasterC, _Argon2idMasterDart>(
      'bs_argon2id_master',
    );
    _saltPepperCanonicalize =
        _lib.lookupFunction<_SaltPepperCanonicalizeC, _SaltPepperCanonicalizeDart>(
            'bs_salt_pepper_canonicalize');
    _chainInput =
        _lib.lookupFunction<_ChainInputC, _ChainInputDart>('bs_chain_input');
    _encodeParams =
        _lib.lookupFunction<_EncodeParamsC, _EncodeParamsDart>('bs_encode_params');
    _encodeArea =
        _lib.lookupFunction<_EncodeAreaC, _EncodeAreaDart>('bs_encode_area');
    _bitsPerPoint = _lib
        .lookupFunction<_BitsPerPointC, _BitsPerPointDart>('bs_bits_per_point');
    _getPrecision =
        _lib.lookupFunction<_GetPrecisionC, _GetPrecisionDart>('bs_get_precision');
    _engineVersion =
        _lib.lookupFunction<_EngineVersionC, _EngineVersionDart>(
      'bs_engine_version',
    );
  }

  /// Open the engine library and bind its symbols. Verifies the fixed-point
  /// layout matches [kFracBits] so a future engine ABI drift fails loudly.
  factory GreatWallCoreBindings.open({CoreLibraryLoader loader = const CoreLibraryLoader()}) {
    final GreatWallCoreBindings b = GreatWallCoreBindings._(loader.open());
    final int frac = b.precision().fracBits;
    if (frac != kFracBits) {
      throw StateError(
        'Engine fixed-point layout changed: expected $kFracBits fractional '
        'bits (I4F60), engine reports $frac. Update fixed.dart before '
        'encoding anything — coordinates would otherwise be misscaled.',
      );
    }
    return b;
  }

  final DynamicLibrary _lib;

  late final _RenderViewportDart _renderViewport;
  late final _RenderViewportGenericDart _renderViewportGeneric;
  late final _EncodeDart _encode;
  late final _EncodeResultPointDart _encodeResultPoint;
  late final _EncodeResultFinalRectDart _encodeResultFinalRect;
  late final _EncodeResultFreeDart _encodeResultFree;
  late final _DecodeFullDart _decodeFull;
  late final _LeafAreasComputeDart _leafAreasCompute;
  late final _LeafAreasStatusDart _leafAreasStatus;
  late final _LeafAreasCountDart _leafAreasCount;
  late final _LeafAreasRectDart _leafAreasRect;
  late final _LeafAreasPathDart _leafAreasPath;
  late final _LeafAreasFreeDart _leafAreasFree;
  late final _Argon2SingleDart _argon2Single;
  late final _Argon2idMasterDart _argon2idMaster;
  late final _SaltPepperCanonicalizeDart _saltPepperCanonicalize;
  late final _ChainInputDart _chainInput;
  late final _EncodeParamsDart _encodeParams;
  late final _EncodeAreaDart _encodeArea;
  late final _BitsPerPointDart _bitsPerPoint;
  late final _GetPrecisionDart _getPrecision;
  late final _EngineVersionDart _engineVersion;

  // -------------------------------------------------------------------------
  // Metadata
  // -------------------------------------------------------------------------

  /// `(fracBits, intBits)` of the engine's fixed-point type.
  ({int fracBits, int intBits}) precision() {
    final Pointer<Uint32> frac = calloc<Uint32>();
    final Pointer<Uint32> intb = calloc<Uint32>();
    try {
      _getPrecision(frac, intb);
      return (fracBits: frac.value, intBits: intb.value);
    } finally {
      calloc
        ..free(frac)
        ..free(intb);
    }
  }

  /// The engine algorithm version string (e.g. `"0.1.0"`). A mismatch between
  /// the version the app was tested against and the linked engine is a signal
  /// that encodings may not be reproducible.
  String engineVersion() {
    const int bufLen = 32;
    final Pointer<Uint8> buf = calloc<Uint8>(bufLen);
    try {
      final int len = _engineVersion(buf, bufLen);
      final int n = len < bufLen ? len : bufLen - 1;
      return String.fromCharCodes(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  // -------------------------------------------------------------------------
  // Rendering (per-frame hot path)
  // -------------------------------------------------------------------------

  /// Render the canonical (stage-1) Burning Ship escape-count map into [out].
  ///
  /// `out` must hold `width * height` bytes. The engine writes `0` for
  /// non-escaping pixels and `(escape_count % 255) + 1` otherwise — the same
  /// `u8` encoding the Python bridge documents. Coordinate convention:
  /// pixel `(cx, cy)` samples `(originRe + cx*step, originIm + cy*step)`.
  void renderViewport({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int maxIter,
    required Pointer<Uint8> out,
  }) {
    _renderViewport(originRe, originIm, step, width, height, maxIter, out);
  }

  /// Render the perturbed (stage-2) Burning Ship using the entropy reservoirs
  /// `(o, p, q)` (each a raw `u64`, exactly as the engine and Python bridge
  /// expect — see argon2_pipeline.py / constants.py §"Perturbation encoding").
  void renderViewportGeneric({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int maxIter,
    required int o,
    required int p,
    required int q,
    required Pointer<Uint8> out,
  }) {
    _renderViewportGeneric(
      originRe,
      originIm,
      step,
      width,
      height,
      maxIter,
      o,
      p,
      q,
      out,
    );
  }

  // -------------------------------------------------------------------------
  // Encode / decode (bijection)
  // -------------------------------------------------------------------------

  /// Encode [bits] (a list of 0/1) into a fractal location under [params] and
  /// the perturbation reservoirs `(o, p, q)`. Returns the encoded point as raw
  /// I4F60 `i64` coordinates, plus the **leaf rectangle** the bisection settled
  /// on (its centre is the master-secret export's per-stage coordinate — see
  /// `MasterSecret.leafCentreRaw`).
  ///
  /// `area` bounds are raw `i64`. The opaque result handle is queried and freed
  /// internally; only the point and leaf rect are returned (the app does not
  /// surface bisection steps — that is debug-mode UX territory).
  ({int reRaw, int imRaw, FixedRect leafRect}) encodePoint({
    required List<int> bits,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final Pointer<Uint8> bitsPtr = calloc<Uint8>(bits.length);
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    final Pointer<Int64> reOut = calloc<Int64>();
    final Pointer<Int64> imOut = calloc<Int64>();
    // bs_encode_result_final_rect writes four separate Fixed (i64) out-params.
    final Pointer<Int64> reMinOut = calloc<Int64>();
    final Pointer<Int64> reMaxOut = calloc<Int64>();
    final Pointer<Int64> imMinOut = calloc<Int64>();
    final Pointer<Int64> imMaxOut = calloc<Int64>();
    try {
      bitsPtr.asTypedList(bits.length).setAll(0, bits);
      final Pointer<Void> handle = _encode(
        bitsPtr,
        bits.length,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        o,
        p,
        q,
        ppPtr,
        ppLen,
      );
      if (handle == nullptr) {
        throw StateError('bs_encode returned NULL handle');
      }
      try {
        _encodeResultPoint(handle, reOut, imOut);
        _encodeResultFinalRect(
          handle,
          reMinOut,
          reMaxOut,
          imMinOut,
          imMaxOut,
        );
        return (
          reRaw: reOut.value,
          imRaw: imOut.value,
          leafRect: FixedRect(
            reMin: reMinOut.value,
            reMax: reMaxOut.value,
            imMin: imMinOut.value,
            imMax: imMaxOut.value,
          ),
        );
      } finally {
        _encodeResultFree(handle);
      }
    } finally {
      _zeroAndFree(bitsPtr, bits.length);
      if (ppPtr != nullptr) calloc.free(ppPtr);
      calloc
        ..free(reOut)
        ..free(imOut)
        ..free(reMinOut)
        ..free(reMaxOut)
        ..free(imMinOut)
        ..free(imMaxOut);
    }
  }

  /// Decode a fractal point (raw I4F60 coordinates) back to [numBits] bits,
  /// also returning the leaf rectangle and a validity flag.
  ///
  /// `valid == false` means the point fell in a contracted-away region — i.e.
  /// the user clicked off any encodable leaf. The caller (Setup/Train) uses
  /// this to reject a stray tap without leaking *where* it landed.
  CoreDecodeResult decodeFull({
    required int pointReRaw,
    required int pointImRaw,
    required int numBits,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    final int pathBufLen = pathPrefix.length + numBits + 2;
    final Pointer<Uint8> outBits = calloc<Uint8>(numBits);
    final Pointer<Int64> outRect = calloc<Int64>(4);
    final Pointer<Uint8> outValid = calloc<Uint8>();
    final Pointer<Uint8> outPath = calloc<Uint8>(pathBufLen);
    final Pointer<Uint32> outPathLen = calloc<Uint32>();
    try {
      _decodeFull(
        pointReRaw,
        pointImRaw,
        numBits,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        o,
        p,
        q,
        ppPtr,
        ppLen,
        outBits,
        outRect,
        outValid,
        outPath,
        pathBufLen,
        outPathLen,
      );
      final List<int> bits = List<int>.from(outBits.asTypedList(numBits));
      final FixedRect rect = FixedRect(
        reMin: outRect[0],
        reMax: outRect[1],
        imMin: outRect[2],
        imMax: outRect[3],
      );
      return CoreDecodeResult(
        bits: bits,
        leafRect: rect,
        valid: outValid.value != 0,
      );
    } finally {
      _zeroAndFree(outBits, numBits);
      if (ppPtr != nullptr) calloc.free(ppPtr);
      calloc
        ..free(outRect)
        ..free(outValid)
        ..free(outPath)
        ..free(outPathLen);
    }
  }

  // -------------------------------------------------------------------------
  // Viewport leaf-area enumeration
  // -------------------------------------------------------------------------

  /// Enumerate the distinct canonical leaf areas present in a view
  /// (`bs_leaf_areas_*`). The view is described as for [renderViewport]: pixel
  /// `(col, row)` samples `(originRe + col*step, originIm + col*step)`; the scan
  /// steps by [scanStep] pixels. `(o, p, q)` must select the same fractal the
  /// points were encoded on (`(0,0,0)` for the canonical stage, the stage's
  /// reservoirs otherwise) — leaf membership is meaningless on any other surface.
  ///
  /// Returns either the (capped) list of leaf areas — each a leaf rectangle in
  /// raw I4F60 bounds plus its bisection path (canonical identity) — or a
  /// "too many" result when more than [maxLeaves] distinct areas are present.
  /// The opaque handle is queried and freed internally.
  CoreLeafAreasResult enumerateLeafAreas({
    required double originRe,
    required double originIm,
    required double step,
    required int width,
    required int height,
    required int scanStep,
    required int maxLeaves,
    required FixedRect area,
    required CoreDiscoveryParams params,
    required int numBits,
    required int o,
    required int p,
    required int q,
    String pathPrefix = 'O',
  }) {
    final (Pointer<Uint8> ppPtr, int ppLen) = _allocAscii(pathPrefix);
    // A leaf path is the prefix plus one direction letter per bisection level.
    final int pathBufLen = pathPrefix.length + numBits + 2;
    final Pointer<Int64> outRect = calloc<Int64>(4);
    final Pointer<Uint8> outPath = calloc<Uint8>(pathBufLen);
    try {
      final Pointer<Void> handle = _leafAreasCompute(
        originRe,
        originIm,
        step,
        width,
        height,
        scanStep,
        maxLeaves,
        area.reMin,
        area.reMax,
        area.imMin,
        area.imMax,
        params.maxIter,
        params.targetGood,
        params.maxFloodPoints,
        params.minGridCells,
        params.pMaxShift,
        params.exclusionThresholdNum,
        params.rngSeed,
        numBits,
        o,
        p,
        q,
        ppPtr,
        ppLen,
      );
      if (handle == nullptr) {
        throw StateError('bs_leaf_areas_compute returned NULL handle');
      }
      try {
        // status: 0 = list available, 1 = too many (zoom in).
        if (_leafAreasStatus(handle) == 1) {
          return CoreLeafAreasResult.tooMany(maxLeaves);
        }
        final int count = _leafAreasCount(handle);
        final List<CoreLeafArea> leaves = <CoreLeafArea>[];
        for (int i = 0; i < count; i++) {
          _leafAreasRect(handle, i, outRect);
          final FixedRect rect = FixedRect(
            reMin: outRect[0],
            reMax: outRect[1],
            imMin: outRect[2],
            imMax: outRect[3],
          );
          final int len = _leafAreasPath(handle, i, outPath, pathBufLen);
          final int take = len < pathBufLen ? len : pathBufLen - 1;
          final String path = String.fromCharCodes(outPath.asTypedList(take));
          leaves.add(CoreLeafArea(rect: rect, path: path));
        }
        return CoreLeafAreasResult.leaves(leaves);
      } finally {
        _leafAreasFree(handle);
      }
    } finally {
      if (ppPtr != nullptr) calloc.free(ppPtr);
      // The path bytes are directional bits; wipe them before freeing.
      _zeroAndFree(outPath, pathBufLen);
      calloc.free(outRect);
    }
  }

  // -------------------------------------------------------------------------
  // Argon2 (stage-1 bits -> 256-bit digest)
  // -------------------------------------------------------------------------

  /// Run a single Argon2d pass on [input] under [profile]. Returns the 32-byte
  /// digest. Iteration (feeding the digest back in for `gui_iterations` cycles)
  /// is driven from Dart so progress can be reported and the run cancelled
  /// between passes — matching `run_argon2_iterative` in argon2_pipeline.py.
  Uint8List argon2Single(Uint8List input, Argon2Profile profile) {
    final Pointer<Uint8> inPtr = calloc<Uint8>(input.length);
    final Pointer<Uint8> outPtr = calloc<Uint8>(32);
    try {
      inPtr.asTypedList(input.length).setAll(0, input);
      _argon2Single(inPtr, input.length, profile.value, outPtr);
      return Uint8List.fromList(outPtr.asTypedList(32));
    } finally {
      _zeroAndFree(inPtr, input.length);
      _zeroAndFree(outPtr, 32);
    }
  }

  /// Run the **master-secret export** — one Argon2id pass over the reproducible
  /// setup-transcript [message] (`bs_argon2id_master`). Uses the fixed master
  /// profile (Argon2id, `m = 64 MiB`, `t = 8`, `p = 2`) and the fixed salt
  /// `b"greatwall"`; all per-setup uniqueness rides in [message]. Returns
  /// [outLen] bytes (the protocol's `l = 1024`); the consumer takes only what it
  /// needs.
  ///
  /// This is a heavy, blocking native call — callers run it off the UI isolate
  /// (see `GreatWallCore.argon2idMaster`).
  Uint8List argon2idMaster(Uint8List message, {int outLen = 1024}) {
    final int inLen = message.isEmpty ? 1 : message.length;
    final Pointer<Uint8> inPtr = calloc<Uint8>(inLen);
    final Pointer<Uint8> outPtr = calloc<Uint8>(outLen);
    try {
      if (message.isNotEmpty) {
        inPtr.asTypedList(message.length).setAll(0, message);
      }
      _argon2idMaster(inPtr, message.length, outPtr, outLen);
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } finally {
      _zeroAndFree(inPtr, inLen);
      _zeroAndFree(outPtr, outLen);
    }
  }

  /// Canonicalise a Stage-0 salt/pepper string via the engine (the protocol
  /// rule: uppercase ASCII, keep only `A-Z0-9-`). Returns the canonical string.
  /// Defined in the shared engine so it is byte-identical to great-wall-core
  /// (`bs_salt_pepper_canonicalize`).
  String saltPepperCanonicalize(String text) {
    final (Pointer<Uint8> inPtr, int inLen) = _allocAscii(text);
    try {
      final int n = _saltPepperCanonicalize(inPtr, inLen, nullptr, 0);
      if (n == 0) return '';
      final Pointer<Uint8> outPtr = calloc<Uint8>(n);
      try {
        _saltPepperCanonicalize(inPtr, inLen, outPtr, n);
        return String.fromCharCodes(outPtr.asTypedList(n));
      } finally {
        _zeroAndFree(outPtr, n);
      }
    } finally {
      if (inPtr != nullptr) _zeroAndFree(inPtr, inLen);
    }
  }

  /// Build one chain link's Argon2 input via the engine: the canonical
  /// salt/pepper bytes followed by `bits_to_bytes(priorBits)`
  /// (`bs_chain_input`). [text] is the raw salt/pepper; [priorBits] is the
  /// concatenated bits (0/1) of every preceding point. Single source of truth
  /// shared with great-wall-core, so the same text yields the same seed.
  Uint8List chainInput(String text, List<int> priorBits) {
    final (Pointer<Uint8> tPtr, int tLen) = _allocAscii(text);
    final int nBits = priorBits.length;
    final Pointer<Uint8> bPtr = nBits == 0 ? nullptr : calloc<Uint8>(nBits);
    try {
      if (nBits != 0) bPtr.asTypedList(nBits).setAll(0, priorBits);
      final int n = _chainInput(tPtr, tLen, bPtr, nBits, nullptr, 0);
      final Pointer<Uint8> outPtr = calloc<Uint8>(n == 0 ? 1 : n);
      try {
        _chainInput(tPtr, tLen, bPtr, nBits, outPtr, n);
        return Uint8List.fromList(outPtr.asTypedList(n));
      } finally {
        _zeroAndFree(outPtr, n == 0 ? 1 : n);
      }
    } finally {
      if (tPtr != nullptr) _zeroAndFree(tPtr, tLen);
      if (bPtr != nullptr) _zeroAndFree(bPtr, nBits);
    }
  }

  // -------------------------------------------------------------------------
  // Canonical protocol parameters (engine is the single source of truth)
  // -------------------------------------------------------------------------

  /// The canonical encode/decode discovery parameters, read straight from the
  /// engine (`bs_encode_params`). The wallet must not hard-code these — a stale
  /// copy (`maxIter = 64`) is what stalled deep-zoom encodes; the engine
  /// dictates the protocol.
  CoreDiscoveryParams encodeParams() {
    final Pointer<Uint32> maxIter = calloc<Uint32>();
    final Pointer<Uint32> targetGood = calloc<Uint32>();
    final Pointer<Uint64> maxFloodPoints = calloc<Uint64>();
    final Pointer<Uint64> minGridCells = calloc<Uint64>();
    final Pointer<Uint32> pMaxShift = calloc<Uint32>();
    final Pointer<Uint32> exclusionThresholdNum = calloc<Uint32>();
    final Pointer<Uint64> rngSeed = calloc<Uint64>();
    try {
      _encodeParams(maxIter, targetGood, maxFloodPoints, minGridCells,
          pMaxShift, exclusionThresholdNum, rngSeed);
      return CoreDiscoveryParams(
        maxIter: maxIter.value,
        targetGood: targetGood.value,
        maxFloodPoints: maxFloodPoints.value,
        minGridCells: minGridCells.value,
        pMaxShift: pMaxShift.value,
        exclusionThresholdNum: exclusionThresholdNum.value,
        rngSeed: rngSeed.value,
      );
    } finally {
      calloc
        ..free(maxIter)
        ..free(targetGood)
        ..free(maxFloodPoints)
        ..free(minGridCells)
        ..free(pMaxShift)
        ..free(exclusionThresholdNum)
        ..free(rngSeed);
    }
  }

  /// The canonical encode area as raw I4F60 `i64` bounds (`bs_encode_area`).
  FixedRect encodeArea() {
    final Pointer<Int64> reMin = calloc<Int64>();
    final Pointer<Int64> reMax = calloc<Int64>();
    final Pointer<Int64> imMin = calloc<Int64>();
    final Pointer<Int64> imMax = calloc<Int64>();
    try {
      _encodeArea(reMin, reMax, imMin, imMax);
      return FixedRect(
        reMin: reMin.value,
        reMax: reMax.value,
        imMin: imMin.value,
        imMax: imMax.value,
      );
    } finally {
      calloc
        ..free(reMin)
        ..free(reMax)
        ..free(imMin)
        ..free(imMax);
    }
  }

  /// Bits encoded per fractal point/stage (`bs_bits_per_point`).
  int bitsPerPoint() => _bitsPerPoint();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  (Pointer<Uint8>, int) _allocAscii(String s) {
    if (s.isEmpty) return (nullptr, 0);
    final List<int> bytes = s.codeUnits;
    final Pointer<Uint8> ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return (ptr, bytes.length);
  }

  void _zeroAndFree(Pointer<Uint8> ptr, int len) {
    // Wipe secret-bearing buffers before returning them to the allocator.
    ptr.asTypedList(len).fillRange(0, len, 0);
    calloc.free(ptr);
  }
}

/// Argon2 cost profile. Values match the Rust `PROFILE_*` constants and the
/// Python bridge (burning_ship_engine.py).
enum Argon2Profile {
  /// Mobile-accessible: 1 GiB.
  basic(0),

  /// Desktop-only: 32 GiB.
  advanced(1),

  /// Server-class: 128 GiB.
  greatWall(2);

  const Argon2Profile(this.value);
  final int value;
}

/// A rectangle in the complex plane, as raw I4F60 `i64` bounds.
class FixedRect {
  const FixedRect({
    required this.reMin,
    required this.reMax,
    required this.imMin,
    required this.imMax,
  });

  factory FixedRect.fromDoubles(
    double reMin,
    double reMax,
    double imMin,
    double imMax,
  ) =>
      FixedRect(
        reMin: fixedFromDouble(reMin),
        reMax: fixedFromDouble(reMax),
        imMin: fixedFromDouble(imMin),
        imMax: fixedFromDouble(imMax),
      );

  final int reMin;
  final int reMax;
  final int imMin;
  final int imMax;
}

/// Discovery / bisection parameters. Integer-only, mirroring the Rust
/// `DiscoveryParams`. These are *protocol* values that determine encode output;
/// the engine is their single source of truth ([GreatWallCoreBindings
/// .encodeParams], backed by `bs_encode_params`). All fields are required on
/// purpose — there are deliberately no defaults, so a stale literal (e.g. a
/// `maxIter` of 64) can never silently stand in for the engine's value.
class CoreDiscoveryParams {
  const CoreDiscoveryParams({
    required this.maxIter,
    required this.targetGood,
    required this.maxFloodPoints,
    required this.minGridCells,
    required this.pMaxShift,
    required this.exclusionThresholdNum,
    required this.rngSeed,
  });

  final int maxIter;
  final int targetGood;
  final int maxFloodPoints;
  final int minGridCells;
  final int pMaxShift;
  final int exclusionThresholdNum;
  final int rngSeed;
}

/// Result of [GreatWallCoreBindings.decodeFull].
class CoreDecodeResult {
  const CoreDecodeResult({
    required this.bits,
    required this.leafRect,
    required this.valid,
  });

  final List<int> bits;
  final FixedRect leafRect;
  final bool valid;
}

/// One leaf area from [GreatWallCoreBindings.enumerateLeafAreas]: the leaf
/// rectangle in raw I4F60 bounds, plus its bisection [path] — the canonical
/// identity, stable across frames and zoom levels.
class CoreLeafArea {
  const CoreLeafArea({required this.rect, required this.path});

  final FixedRect rect;
  final String path;
}

/// Result of [GreatWallCoreBindings.enumerateLeafAreas]: either the (capped)
/// list of distinct leaf areas present, or [tooMany] meaning more than
/// [maxLeaves] are present and the UX should prompt the user to zoom in.
class CoreLeafAreasResult {
  const CoreLeafAreasResult.leaves(this.leaves)
      : tooMany = false,
        maxLeaves = 0;

  const CoreLeafAreasResult.tooMany(this.maxLeaves)
      : leaves = const <CoreLeafArea>[],
        tooMany = true;

  final List<CoreLeafArea> leaves;
  final bool tooMany;
  final int maxLeaves;
}

// ---------------------------------------------------------------------------
// C ABI typedefs (native + Dart signatures)
// ---------------------------------------------------------------------------

typedef _RenderViewportC = Void Function(
  Double, Double, Double, Int32, Int32, Uint32, Pointer<Uint8>);
typedef _RenderViewportDart = void Function(
  double, double, double, int, int, int, Pointer<Uint8>);

typedef _RenderViewportGenericC = Void Function(
  Double, Double, Double, Int32, Int32, Uint32,
  Uint64, Uint64, Uint64, Pointer<Uint8>);
typedef _RenderViewportGenericDart = void Function(
  double, double, double, int, int, int,
  int, int, int, Pointer<Uint8>);

typedef _EncodeC = Pointer<Void> Function(
  Pointer<Uint8>, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64,
  Uint64, Uint32, Uint32,
  Uint64,
  Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32);
typedef _EncodeDart = Pointer<Void> Function(
  Pointer<Uint8>, int,
  int, int, int, int,
  int, int, int,
  int, int, int,
  int,
  int, int, int,
  Pointer<Uint8>, int);

typedef _EncodeResultPointC = Void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeResultPointDart = void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>);

typedef _EncodeResultFinalRectC = Void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeResultFinalRectDart = void Function(
  Pointer<Void>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);

typedef _EncodeResultFreeC = Void Function(Pointer<Void>);
typedef _EncodeResultFreeDart = void Function(Pointer<Void>);

typedef _DecodeFullC = Void Function(
  Int64, Int64, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64,
  Uint64, Uint32, Uint32,
  Uint64,
  Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32,
  Pointer<Uint8>, Pointer<Int64>, Pointer<Uint8>,
  Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _DecodeFullDart = void Function(
  int, int, int,
  int, int, int, int,
  int, int, int,
  int, int, int,
  int,
  int, int, int,
  Pointer<Uint8>, int,
  Pointer<Uint8>, Pointer<Int64>, Pointer<Uint8>,
  Pointer<Uint8>, int, Pointer<Uint32>);

typedef _LeafAreasComputeC = Pointer<Void> Function(
  Double, Double, Double, Uint32, Uint32, Uint32, Uint32,
  Int64, Int64, Int64, Int64,
  Uint32, Uint32, Uint64, Uint64, Uint32, Uint32,
  Uint64, Uint32, Uint64, Uint64, Uint64,
  Pointer<Uint8>, Uint32);
typedef _LeafAreasComputeDart = Pointer<Void> Function(
  double, double, double, int, int, int, int,
  int, int, int, int,
  int, int, int, int, int, int,
  int, int, int, int, int,
  Pointer<Uint8>, int);

typedef _LeafAreasStatusC = Int32 Function(Pointer<Void>);
typedef _LeafAreasStatusDart = int Function(Pointer<Void>);

typedef _LeafAreasCountC = Uint32 Function(Pointer<Void>);
typedef _LeafAreasCountDart = int Function(Pointer<Void>);

typedef _LeafAreasRectC = Void Function(Pointer<Void>, Uint32, Pointer<Int64>);
typedef _LeafAreasRectDart = void Function(Pointer<Void>, int, Pointer<Int64>);

typedef _LeafAreasPathC = Uint32 Function(
  Pointer<Void>, Uint32, Pointer<Uint8>, Uint32);
typedef _LeafAreasPathDart = int Function(
  Pointer<Void>, int, Pointer<Uint8>, int);

typedef _LeafAreasFreeC = Void Function(Pointer<Void>);
typedef _LeafAreasFreeDart = void Function(Pointer<Void>);

typedef _Argon2SingleC = Void Function(
  Pointer<Uint8>, Uint32, Uint8, Pointer<Uint8>);
typedef _Argon2SingleDart = void Function(
  Pointer<Uint8>, int, int, Pointer<Uint8>);

typedef _Argon2idMasterC = Void Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _Argon2idMasterDart = void Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _SaltPepperCanonicalizeC = Uint32 Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _SaltPepperCanonicalizeDart = int Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _ChainInputC = Uint32 Function(
  Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32);
typedef _ChainInputDart = int Function(
  Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _EncodeParamsC = Void Function(Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>);
typedef _EncodeParamsDart = void Function(Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint32>, Pointer<Uint32>,
    Pointer<Uint64>);

typedef _EncodeAreaC = Void Function(
  Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);
typedef _EncodeAreaDart = void Function(
  Pointer<Int64>, Pointer<Int64>, Pointer<Int64>, Pointer<Int64>);

typedef _BitsPerPointC = Uint32 Function();
typedef _BitsPerPointDart = int Function();

typedef _GetPrecisionC = Void Function(Pointer<Uint32>, Pointer<Uint32>);
typedef _GetPrecisionDart = void Function(Pointer<Uint32>, Pointer<Uint32>);

typedef _EngineVersionC = Uint32 Function(Pointer<Uint8>, Uint32);
typedef _EngineVersionDart = int Function(Pointer<Uint8>, int);
