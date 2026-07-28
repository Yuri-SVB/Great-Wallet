import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/core/great_wall_core.dart';
import 'package:great_wallet_app/src/core/orbit_protocol.dart';
import 'package:great_wallet_app/src/ffi/library_loader.dart';
import 'package:great_wallet_app/src/setup/orbit_setup_controller.dart';

/// Tests for the interactive orbit Setup controller (the fallback flow's core).
///
/// The key property: driving [OrbitSetupController] board-by-board with a set of
/// chunks reaches [OrbitSetupPhase.complete] with a terminal `K` **identical**
/// to the batch [OrbitProtocol.encodeOrbit] over the same chunks (same cheap
/// advance) — so the interactive walk and the reference orchestration agree.
///
/// Uses a cheap deterministic advance (no Argon2) so the whole walk is fast;
/// K parity holds regardless of which advance is used (encode and the controller
/// share it). Skips cleanly if the engine can't be opened.
void main() {
  GreatWallCore? core;
  String? openError;

  setUpAll(() {
    try {
      core = GreatWallCore.open();
    } on CoreLibraryNotFound catch (e) {
      openError = e.toString();
    } on ArgumentError catch (e) {
      openError = 'engine library unusable: $e';
    } on StateError catch (e) {
      openError = 'engine ABI mismatch: $e';
    }
  });

  Future<Uint8List> cheapAdvance(Uint8List o, Uint8List shBytes) async {
    final Uint8List tag = Uint8List.fromList('ORBIT-ADVANCE'.codeUnits);
    final Uint8List m = Uint8List(o.length + shBytes.length + tag.length)
      ..setAll(0, o)
      ..setAll(o.length, shBytes)
      ..setAll(o.length + shBytes.length, tag);
    return Uint8List.fromList(crypto.sha256.convert(m).bytes);
  }

  for (final int level in <int>[1, 2]) {
    test('level $level: interactive walk completes and K matches OrbitProtocol',
        () async {
      final GreatWallCore? c = core;
      if (c == null) {
        markTestSkipped('engine unavailable — $openError');
        return;
      }
      final List<int> thresholds = c.setupTierThresholds(level);
      expect(thresholds, isNotEmpty);

      // Deterministic chunks: [stage][board][32 bits].
      final _Rng rng = _Rng(0x0B17 + level);
      final List<List<List<int>>> chunks = <List<List<int>>>[
        for (final int t in thresholds)
          <List<int>>[
            for (int b = 0; b < t; b++)
              <int>[for (int i = 0; i < 32; i++) rng.nextBit()],
          ],
      ];
      final Uint8List sigma =
          Uint8List.fromList(List<int>.generate(128, (_) => rng.nextByte()));

      final OrbitSetupController ctrl = OrbitSetupController(c);
      addTearDown(ctrl.dispose);

      ctrl.begin(level: level, sigma: sigma, advanceFn: cheapAdvance);
      expect(ctrl.phase, OrbitSetupPhase.placing);
      expect(ctrl.substandard, level == 1,
          reason: 'Setup 1 is the substandard tier');

      OrbitPlaceOutcome? lastOutcome;
      for (int s = 0; s < thresholds.length; s++) {
        expect(ctrl.stageIndex, s, reason: 'walk should be on stage $s');
        final int t = thresholds[s];
        for (int b = 0; b < t; b++) {
          expect(ctrl.boardIndex, b);
          // The board exposes the reservoirs θ_i_j split — non-null while placing.
          expect(ctrl.currentBoardParams, isNotNull);
          lastOutcome = await ctrl.placeChunk(chunks[s][b]);
        }
        if (s < thresholds.length - 1) {
          expect(lastOutcome, OrbitPlaceOutcome.stageAdvanced,
              reason: 'finishing stage $s advances the orbit');
        }
      }

      expect(lastOutcome, OrbitPlaceOutcome.complete);
      expect(ctrl.phase, OrbitSetupPhase.complete);
      expect(ctrl.isComplete, isTrue);
      expect(ctrl.stages.length, thresholds.length);
      expect(ctrl.terminalK, isNotNull);

      // Cross-check the terminal K against the batch orchestration.
      final OrbitProtocol orbit = OrbitProtocol(c);
      final ({List<OrbitStage> stages, Uint8List k}) ref =
          await orbit.encodeOrbit(sigma, level, chunks, advanceFn: cheapAdvance);
      expect(_hex(ctrl.terminalK!), _hex(ref.k),
          reason: 'interactive K_N must equal OrbitProtocol K_N');

      // Per-stage K_i agree too.
      for (int s = 0; s < thresholds.length; s++) {
        expect(_hex(ctrl.stages[s].k), _hex(ref.stages[s].k),
            reason: 'stage $s K_i must match');
        expect(ctrl.stages[s].threshold, thresholds[s]);
      }
    });
  }

  test('invalid setup level fails loudly (error phase)', () {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
    final OrbitSetupController ctrl = OrbitSetupController(c);
    addTearDown(ctrl.dispose);
    ctrl.begin(level: 0, sigma: Uint8List(128));
    expect(ctrl.phase, OrbitSetupPhase.error);
    expect(ctrl.error, isNotNull);
  });

  test('placing before begin is a no-op (busy)', () async {
    final GreatWallCore? c = core;
    if (c == null) {
      markTestSkipped('engine unavailable — $openError');
      return;
    }
    final OrbitSetupController ctrl = OrbitSetupController(c);
    addTearDown(ctrl.dispose);
    final OrbitPlaceOutcome o =
        await ctrl.placeChunk(<int>[for (int i = 0; i < 32; i++) 0]);
    expect(o, OrbitPlaceOutcome.busy);
  });
}

String _hex(Uint8List bytes) {
  final StringBuffer sb = StringBuffer();
  for (final int b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Deterministic LCG (Numerical Recipes constants).
class _Rng {
  _Rng(this._state);
  int _state;

  int _next() {
    _state = (0x19660D * _state + 0x3C6EF35F) & 0xFFFFFFFF;
    return _state;
  }

  int nextBit() => _next() & 1;
  int nextByte() => _next() & 0xFF;
}
