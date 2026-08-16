import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart' show Argon2Profile;
import 'package:great_wallet_app/src/setup/orbit_vault.dart';

/// Pure-Dart serialization tests for [OrbitVault] — no FFI/engine needed.
void main() {
  OrbitVaultPoint point(int slot, int seed) =>
      OrbitVaultPoint(slot: slot, reRaw: seed, imRaw: seed + 1);

  OrbitVault sample() => OrbitVault(
        sigma: 'DEADBEEF',
        iterations: 5,
        profile: Argon2Profile.basic,
        stages: <OrbitVaultStage>[
          // Stage 0: o_0 is re-derived from sigma, so no stored orbit point.
          OrbitVaultStage(
            required: 2,
            orbit: null,
            points: <OrbitVaultPoint>[point(1, 10), point(2, 20)],
          ),
          // A deep stage: carries its memory-hard o_i so restore skips Argon2.
          OrbitVaultStage(
            required: 3,
            orbit: <int>[for (int i = 0; i < 32; i++) i],
            points: <OrbitVaultPoint>[point(1, 30), point(3, 40), point(5, 50)],
          ),
        ],
      );

  group('settled orbit vault (v1)', () {
    test('round-trips through JSON and stays version 1 / kind orbit', () {
      final OrbitVault v = sample();
      final Map<String, dynamic> json = v.toJson();
      expect(json['v'], OrbitVault.formatVersion);
      expect(json['kind'], OrbitVault.kind);

      final OrbitVault back = OrbitVault.fromJson(json);
      expect(back.sigma, 'DEADBEEF');
      expect(back.iterations, 5);
      expect(back.profile, Argon2Profile.basic);
      expect(back.stages.length, 2);
      expect(back.stages[0].orbit, isNull);
      expect(back.stages[0].points.length, 2);
      expect(back.stages[1].required, 3);
      expect(back.stages[1].orbit, hasLength(32));
      expect(back.stages[1].points[1].slot, 3);
      expect(back.stages[1].points[2].imRaw, 51);
    });

    test('omits the orbit key from JSON when null (stage 0)', () {
      final Map<String, dynamic> s0 = sample().stages[0].toJson();
      expect(s0.containsKey('o'), isFalse);
    });

    test('rejects an empty stage list', () {
      expect(
        () => OrbitVault.fromJson(<String, dynamic>{
          'v': 1,
          'kind': 'orbit',
          'sigma': 'AA',
          'iterations': 1,
          'profile': Argon2Profile.basic.value,
          'stages': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('discrimination', () {
    test('rejects a payload missing the orbit kind (e.g. a chain vault)', () {
      // A legacy chain SetupVault payload shape — no `kind`, has `text`.
      expect(
        () => OrbitVault.fromJson(<String, dynamic>{
          'v': 1,
          'text': 'SALT-1',
          'iterations': 7,
          'profile': Argon2Profile.basic.value,
          'stages': <Object?>[
            <String, dynamic>{'o': 1, 'p': 2, 'q': 3, 're': 4, 'im': 5},
          ],
        }),
        throwsFormatException,
      );
    });

    test('rejects an unknown version', () {
      expect(
        () => OrbitVault.fromJson(<String, dynamic>{
          'v': 99,
          'kind': 'orbit',
          'sigma': 'AA',
          'iterations': 1,
          'profile': Argon2Profile.basic.value,
          'stages': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  test('wipe zeroes the orbit key and placed-point coordinates', () {
    final OrbitVault v = sample();
    v.wipe();
    expect(v.stages[1].orbit!.every((int b) => b == 0), isTrue);
    for (final OrbitVaultStage s in v.stages) {
      for (final OrbitVaultPoint p in s.points) {
        expect(p.reRaw, 0);
        expect(p.imRaw, 0);
      }
    }
  });
}
