import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/orbit_protocol.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';

/// Orchestration test for the 0.4.0 orbit protocol through the Dart service
/// (OrbitProtocol) — the peer of great-wall-core's test_orbit_protocol.py and
/// test_orbit_vectors.py.
///
/// Two layers:
///  1. Round-trip: encode_orbit -> points -> decode_orbit recovers the entropy
///     and the terminal K, across setup tiers, using a CHEAP deterministic
///     advance (encode and decode share it, so the bijection holds without the
///     memory-hard Argon2 advance — the real advance is covered at the Rust/FFI
///     level). Byte-identical config to test_orbit_protocol.py's FAST_PARAMS.
///  2. Frozen-vector cross-check: reproduces the cheap per-stage derivations
///     (theta params, decoded chunks, Sh, K_i) from the FROZEN o_i in
///     great-wall-core's test_vectors/orbit-v0.4.0/*.json — the same thing
///     test_orbit_vectors.py checks, now from Dart. Skipped unless the
///     great-wall-core submodule is checked out beside app/ AND its engine
///     version matches the linked engine (a version drift is reported, never a
///     false pass).
///
/// REQUIRES the engine to be built and the great-wall-core submodule pinned at
/// the orbit commit (see orbit_ffi_test.dart). If the engine can't be opened,
/// every test skips with the reason rather than failing.
void main() {
  GreatWallCore? core;
  String? openError;

  // Byte-identical to test_orbit_protocol.py (FAST_PARAMS / TEST_AREA): light
  // discovery config so the round-trip is fast. Encode and decode use the same,
  // so the bijection is unaffected; production defaults to the engine's params.
  const CoreDiscoveryParams fastParams = CoreDiscoveryParams(
    maxIter: 200,
    targetGood: 30,
    maxFloodPoints: 10000,
    minGridCells: 1024,
    pMaxShift: 1,
    exclusionThresholdNum: 204,
    rngSeed: 0x42,
  );
  final FixedRect testArea = FixedRect.fromDoubles(-2.0, 1.0, -1.5, 1.0);

  setUpAll(() {
    try {
      core = GreatWallCore.open();
    } on CoreLibraryNotFound catch (e) {
      openError = e.toString();
    } on ArgumentError catch (e) {
      openError = 'engine library unusable: $e';
    } on StateError catch (e) {
      // e.g. a fixed-point/bits-per-point ABI drift the facade guards against.
      openError = 'engine ABI mismatch: $e';
    }
  });

  // The cheap deterministic advance — byte-identical to cheap_advance in
  // test_orbit_protocol.py: SHA-256(o ‖ Sh ‖ "ORBIT-ADVANCE").
  Future<Uint8List> cheapAdvance(Uint8List o, Uint8List shBytes) async {
    final Uint8List m = _concat(_concat(o, shBytes), _ascii('ORBIT-ADVANCE'));
    return _sha256(m);
  }

  group('orbit encode/decode round-trip across setup tiers', () {
    for (final int level in <int>[1, 2, 3]) {
      test('level $level round-trips entropy and K', () async {
        final GreatWallCore? c = core;
        if (c == null) {
          markTestSkipped('engine unavailable — $openError');
          return;
        }
        final OrbitProtocol orbit =
            OrbitProtocol(c, params: fastParams, area: testArea);
        final List<int> thresholds = c.setupTierThresholds(level);
        expect(thresholds, isNotEmpty, reason: 'level $level must be valid');

        // Deterministic per-level chunks (seed varies by level) + a 128-byte σ.
        final _Rng rng = _Rng(0x0B17 + level);
        final List<List<List<int>>> stageChunks = <List<List<int>>>[
          for (final int t in thresholds)
            <List<int>>[for (int b = 0; b < t; b++) _randChunk(rng)],
        ];
        final Uint8List sigma =
            Uint8List.fromList(List<int>.generate(128, (_) => rng.nextByte()));

        final ({List<OrbitStage> stages, Uint8List k}) enc =
            await orbit.encodeOrbit(sigma, level, stageChunks,
                advanceFn: cheapAdvance);
        final List<List<({int reRaw, int imRaw})>> stagePoints =
            <List<({int reRaw, int imRaw})>>[
          for (final OrbitStage st in enc.stages) st.points,
        ];

        final ({List<List<List<int>>> stageChunks, Uint8List k}) dec =
            await orbit.decodeOrbit(sigma, level, stagePoints,
                advanceFn: cheapAdvance);

        expect(dec.stageChunks, stageChunks,
            reason: 'level $level $thresholds: entropy round-trips');
        expect(dec.k, enc.k,
            reason: 'level $level: K matches on encode & decode');
        expect(enc.stages.last.sh.length, thresholds.last,
            reason: 'level $level: terminal Sh has t_N=${thresholds.last} '
                'coeffs (${thresholds.last * 32} bits)');
        // Deep stages must carry r_i > 2 (the standard rule); Setup 1 is the
        // sole substandard exception (its single deep stage is t=2).
        final bool substandard = c.setupTierSubstandard(level);
        for (int i = 1; i < thresholds.length; i++) {
          if (!substandard) {
            expect(thresholds[i] > 2, isTrue,
                reason: 'level $level deep stage $i: r_i > 2');
          }
        }
      });
    }
  });

  group('K_i determinism & sensitivity', () {
    test('K is deterministic in (sigma, points) and re-roots on sigma', () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final OrbitProtocol orbit =
          OrbitProtocol(c, params: fastParams, area: testArea);
      final _Rng rng = _Rng(777);
      final List<int> thr = c.setupTierThresholds(2);
      final List<List<List<int>>> sc = <List<List<int>>>[
        for (final int t in thr)
          <List<int>>[for (int b = 0; b < t; b++) _randChunk(rng)],
      ];
      final Uint8List sig =
          Uint8List.fromList(List<int>.generate(128, (_) => rng.nextByte()));

      final ({List<OrbitStage> stages, Uint8List k}) r1 =
          await orbit.encodeOrbit(sig, 2, sc, advanceFn: cheapAdvance);
      final ({List<OrbitStage> stages, Uint8List k}) r2 =
          await orbit.encodeOrbit(sig, 2, sc, advanceFn: cheapAdvance);
      expect(r2.k, r1.k,
          reason: 'K is deterministic for identical (sigma, points)');

      final Uint8List sig2 = Uint8List.fromList(sig)..[0] ^= 0x01;
      final ({List<OrbitStage> stages, Uint8List k}) r3 =
          await orbit.encodeOrbit(sig2, 2, sc, advanceFn: cheapAdvance);
      expect(r3.k, isNot(r1.k),
          reason: 'distinct sigma -> distinct K (orbit re-rooted)');
    });
  });

  group('frozen orbit smoke vectors (cross-check great-wall-core)', () {
    test('reproduce cheap per-stage derivations from frozen o_i', () {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final Directory vecDir = _locateVectorDir();
      if (!vecDir.existsSync()) {
        markTestSkipped(
            'orbit vectors not found (submodule not checked out): ${vecDir.path}');
        return;
      }
      final List<File> vectors = vecDir
          .listSync()
          .whereType<File>()
          .where((File f) =>
              f.path.contains('orbit_setup') && f.path.endsWith('.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
      if (vectors.isEmpty) {
        markTestSkipped('no orbit_setup*.json vectors in ${vecDir.path}');
        return;
      }

      final OrbitProtocol orbit = OrbitProtocol(c);
      int checked = 0;
      for (final File vf in vectors) {
        final Map<String, dynamic> vec =
            jsonDecode(vf.readAsStringSync()) as Map<String, dynamic>;

        // STALE guard (mirrors test_orbit_vectors.py): a vector whose engine
        // version differs from the linked engine is skipped, never a false pass.
        if (vec['engine_version'] != c.engineVersion) {
          markTestSkipped('STALE ${_basename(vf.path)} '
              '(engine ${vec['engine_version']} != ${c.engineVersion})');
          continue;
        }

        final CoreDiscoveryParams params = _paramsFromVec(
            (vec['vec_params'] as Map<String, dynamic>));
        final List<dynamic> areaList = vec['vec_area'] as List<dynamic>;
        final FixedRect area = FixedRect.fromDoubles(
          (areaList[0] as num).toDouble(),
          (areaList[1] as num).toDouble(),
          (areaList[2] as num).toDouble(),
          (areaList[3] as num).toDouble(),
        );

        final List<dynamic> stages = List<dynamic>.from(vec['stages'] as List)
          ..sort((dynamic a, dynamic b) =>
              (a['index'] as int).compareTo(b['index'] as int));

        String? lastK;
        for (final dynamic stDyn in stages) {
          final Map<String, dynamic> st = stDyn as Map<String, dynamic>;
          final Uint8List oI = _hexToBytes(st['o_hex'] as String);
          final int t = st['threshold'] as int;
          final List<int> xs = <int>[];
          final List<int> ys = <int>[];
          for (int j = 0; j < t; j++) {
            // theta_i_j -> (o, p, q) must reproduce the stored fractal params.
            final ({int o, int p, int q}) prm = orbit.orbitParams(oI, j);
            final Map<String, dynamic> fr =
                (st['fractals'] as List)[j] as Map<String, dynamic>;
            expect(_hexU64(prm.o), fr['o'],
                reason: '${_basename(vf.path)} stage ${st['index']} '
                    'fractal $j: theta o differs');
            expect(_hexU64(prm.p), fr['p']);
            expect(_hexU64(prm.q), fr['q']);

            // The stored point decodes to the stored 32-bit value.
            final Map<String, dynamic> pt =
                (st['points'] as List)[j] as Map<String, dynamic>;
            final CoreDecodeResult res = c.bindings.decodeFull(
              pointReRaw: _fromHexI64(pt['re_raw'] as String),
              pointImRaw: _fromHexI64(pt['im_raw'] as String),
              numBits: 32,
              area: area,
              params: params,
              o: prm.o,
              p: prm.p,
              q: prm.q,
            );
            final int y = OrbitProtocol.bitsToU32(res.bits);
            expect(_hexU32(y), (st['chunks_u32'] as List)[j],
                reason: '${_basename(vf.path)} stage ${st['index']} '
                    'fractal $j: decoded value differs');
            xs.add(j + 1);
            ys.add(y);
          }
          // Sh_i and K_i reproduce.
          final List<int> sh = c.shamirInterp(xs, ys);
          expect(sh.map(_hexU32).toList(), st['sh'],
              reason: '${_basename(vf.path)} stage ${st['index']}: Sh differs');
          final Uint8List k =
              c.masterSecret(oI, GreatWallCoreBindings.shToBytes(sh));
          expect(_hex(k), st['k_hex'],
              reason:
                  '${_basename(vf.path)} stage ${st['index']}: K_i differs');
          lastK = st['k_hex'] as String;
        }
        expect(lastK, vec['terminal_k_hex'],
            reason: '${_basename(vf.path)}: terminal K != last stage K');
        checked++;
      }
      // If every vector was STALE-skipped, the test above already skipped; a
      // reached-here with checked==0 means all were skipped mid-loop.
      if (checked == 0) {
        markTestSkipped('all orbit vectors were STALE for this engine');
      }
    });
  });
}

// --- vector location ---------------------------------------------------------

/// Locate great-wall-core's orbit vector dir relative to the test CWD. `flutter
/// test` runs with CWD = the package root (app/), a sibling of the great-wall-
/// core submodule inside great-wallet.
Directory _locateVectorDir() {
  const String rel =
      '../great-wall-core/burning_ship/test_vectors/orbit-v0.4.0';
  return Directory(rel);
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

// --- parsing / formatting helpers -------------------------------------------

CoreDiscoveryParams _paramsFromVec(Map<String, dynamic> p) => CoreDiscoveryParams(
      maxIter: p['max_iter'] as int,
      targetGood: p['target_good'] as int,
      maxFloodPoints: p['max_flood_points'] as int,
      minGridCells: p['min_grid_cells'] as int,
      pMaxShift: p['p_max_shift'] as int,
      exclusionThresholdNum: p['exclusion_threshold_num'] as int,
      rngSeed: p['rng_seed'] as int,
    );

Uint8List _sha256(Uint8List data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

Uint8List _concat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setAll(0, a)
  ..setAll(a.length, b);

Uint8List _hexToBytes(String h) {
  final Uint8List out = Uint8List(h.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(Uint8List bytes) {
  final StringBuffer sb = StringBuffer();
  for (final int b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _hexU32(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');

/// Format a Dart int's low 64 bits as 16 unsigned hex chars, matching Python's
/// `format(v & 0xFFFFFFFFFFFFFFFF, "016x")`. Uses two 32-bit halves so a
/// high-bit-set (negative) int still renders unsigned.
String _hexU64(int v) {
  final int hi = (v >> 32) & 0xFFFFFFFF;
  final int lo = v & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

/// Parse 16 unsigned hex chars back to a signed i64 (two 32-bit halves so the
/// value never overflows int.parse's signed range).
int _fromHexI64(String h) {
  final int hi = int.parse(h.substring(0, 8), radix: 16);
  final int lo = int.parse(h.substring(8, 16), radix: 16);
  return (hi << 32) | lo;
}

// --- deterministic test RNG --------------------------------------------------

/// Tiny deterministic LCG (Numerical Recipes constants) so chunks/σ are
/// reproducible without `Random`'s implementation-defined stream.
class _Rng {
  _Rng(this._state);
  int _state;

  int _next() {
    _state = (0x19660D * _state + 0x3C6EF35F) & 0xFFFFFFFF;
    return _state;
  }

  int nextByte() => _next() & 0xFF;
  int nextBit() => _next() & 1;
}

/// A 32-bit (BITS_PER_POINT) 0/1 bit list — one fractal point's worth.
List<int> _randChunk(_Rng rng) => <int>[for (int i = 0; i < 32; i++) rng.nextBit()];
