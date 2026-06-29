import 'package:flutter_test/flutter_test.dart';
import 'package:great_wallet_app/src/ffi/core_bindings.dart' show Argon2Profile;
import 'package:great_wallet_app/src/setup/setup_vault.dart';

/// Pure-Dart serialization tests for [SetupVault] — no FFI/engine needed.
void main() {
  VaultStage stage(int seed) => VaultStage(
        o: seed,
        p: seed + 1,
        q: seed + 2,
        reRaw: seed + 3,
        imRaw: seed + 4,
      );

  group('settled vault (v1)', () {
    test('round-trips through JSON and stays version 1', () {
      final SetupVault v = SetupVault(
        text: 'SALT-1',
        iterations: 7,
        profile: Argon2Profile.basic,
        stages: <VaultStage>[stage(10), stage(20)],
      );
      final Map<String, dynamic> json = v.toJson();
      expect(json['v'], SetupVault.formatVersion);
      expect(json.containsKey('resume'), isFalse);

      final SetupVault back = SetupVault.fromJson(json);
      expect(back.resume, isNull);
      expect(back.text, 'SALT-1');
      expect(back.iterations, 7);
      expect(back.stages.length, 2);
      expect(back.stages[1].o, 20);
      expect(back.stages[1].imRaw, 24);
    });

    test('rejects an empty stage list', () {
      expect(
        () => SetupVault.fromJson(<String, dynamic>{
          'v': 1,
          'text': 'x',
          'iterations': 1,
          'profile': Argon2Profile.basic.value,
          'stages': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('resumable vault (v2)', () {
    SetupVault resumable({int prefix = 2, int haltStage = 3, int pts = 5}) =>
        SetupVault(
          text: 'SALT-2',
          iterations: 9,
          profile: Argon2Profile.basic,
          stages: <VaultStage>[for (int i = 0; i < prefix; i++) stage(i * 10)],
          resume: VaultResume(
            stage: haltStage,
            pass: 4,
            total: 9,
            pointStages: pts,
            digest: <int>[1, 2, 3, 4],
            entropy: <int>[for (int i = 0; i < pts * 32; i++) i % 2],
          ),
        );

    test('round-trips with resume-state and is version 2', () {
      final SetupVault v = resumable();
      final Map<String, dynamic> json = v.toJson();
      expect(json['v'], SetupVault.resumableVersion);
      expect(json.containsKey('resume'), isTrue);

      final SetupVault back = SetupVault.fromJson(json);
      expect(back.resume, isNotNull);
      final VaultResume r = back.resume!;
      expect(r.stage, 3);
      expect(r.pass, 4);
      expect(r.total, 9);
      expect(r.pointStages, 5);
      expect(r.digest, <int>[1, 2, 3, 4]);
      expect(r.entropy.length, 5 * 32);
      expect(back.stages.length, 2);
    });

    test('allows an empty prefix (halt on Stage 1)', () {
      final SetupVault v = resumable(prefix: 0, haltStage: 1);
      final SetupVault back = SetupVault.fromJson(v.toJson());
      expect(back.stages, isEmpty);
      expect(back.resume!.stage, 1);
    });

    test('v2 without a resume object is rejected', () {
      expect(
        () => SetupVault.fromJson(<String, dynamic>{
          'v': SetupVault.resumableVersion,
          'text': 'x',
          'iterations': 1,
          'profile': Argon2Profile.basic.value,
          'stages': <Object?>[],
        }),
        throwsFormatException,
      );
    });

    test('wipe zeroes the resume secrets', () {
      final SetupVault v = resumable();
      v.wipe();
      expect(v.resume!.digest.every((int b) => b == 0), isTrue);
      expect(v.resume!.entropy.every((int b) => b == 0), isTrue);
    });
  });

  test('an unknown version is rejected', () {
    expect(
      () => SetupVault.fromJson(<String, dynamic>{
        'v': 99,
        'text': 'x',
        'iterations': 1,
        'profile': Argon2Profile.basic.value,
        'stages': <Object?>[],
      }),
      throwsFormatException,
    );
  });
}
