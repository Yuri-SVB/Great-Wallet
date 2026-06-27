import '../ffi/core_bindings.dart' show Argon2Profile;

/// The serializable **provisional key** — everything needed to reconstruct a
/// settled setup *without* re-running Argon2: the Stage-0 text, the derivation
/// parameters (`N`, `m`), and, per point stage, its `(o, p, q)` reservoirs plus
/// one coordinate inside the encoded point's leaf. On load, the engine's cheap
/// decode turns each `(o, p, q, re, im)` back into the stage's fractal and point
/// (great-wall-core/DESIGN §decode); the expensive memory-hard derivation is
/// skipped entirely.
///
/// SECURITY — this object **is the secret**. `(o, p, q)` and the point
/// coordinates are coercion-relevant (TECH_STACK.md "no logs of fractal
/// coordinates / (o,p,q)"). It is the transient provisional key from
/// `next-steps/provisional-key-bootstrapping.md`: held externally only across
/// the memory-consolidation window and destroyed at graduation. It must **only
/// ever be persisted encrypted** (password encryption — the next step); never
/// write a [SetupVault] to disk, a log, a clipboard, or any sink in plaintext.
/// [toString] is redacted and [wipe] zeroes the secret integers when done.
class SetupVault {
  SetupVault({
    required this.text,
    required this.iterations,
    required this.profile,
    required this.stages,
  });

  /// On-disk format version, so a future change can be detected and rejected
  /// rather than silently misread.
  static const int formatVersion = 1;

  /// The canonicalised Stage-0 salt/pepper (may itself be a secret pepper).
  final String text;

  /// `N` — Argon2 iterations per stage.
  final int iterations;

  /// `m` — the Argon2 memory profile.
  final Argon2Profile profile;

  /// One entry per point stage (stage 1..S), in chain order.
  final List<VaultStage> stages;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': formatVersion,
        'text': text,
        'iterations': iterations,
        'profile': profile.value,
        'stages': <Map<String, dynamic>>[for (final VaultStage s in stages) s.toJson()],
      };

  /// Rebuild a vault from decoded JSON. Throws a generic [FormatException] on any
  /// missing/ill-typed field or unknown version — the message never echoes
  /// values (a wrong-password decrypt that yields garbage must fail opaquely).
  factory SetupVault.fromJson(Map<String, dynamic> json) {
    final int v = _int(json, 'v');
    if (v != formatVersion) {
      throw const FormatException('unsupported vault version');
    }
    final Object? text = json['text'];
    if (text is! String) throw const FormatException('bad vault');
    final int profileCode = _int(json, 'profile');
    final Argon2Profile profile = Argon2Profile.values.firstWhere(
      (Argon2Profile p) => p.value == profileCode,
      orElse: () => throw const FormatException('bad vault'),
    );
    final Object? rawStages = json['stages'];
    if (rawStages is! List || rawStages.isEmpty) {
      throw const FormatException('bad vault');
    }
    return SetupVault(
      text: text,
      iterations: _int(json, 'iterations'),
      profile: profile,
      stages: <VaultStage>[
        for (final Object? s in rawStages)
          VaultStage.fromJson(s is Map<String, dynamic>
              ? s
              : throw const FormatException('bad vault')),
      ],
    );
  }

  /// Zero every stage's secret integers. The [text] is an immutable String and
  /// cannot be overwritten (the controller's own salt/pepper has the same
  /// limitation); drop all references to let it be collected.
  void wipe() {
    for (final VaultStage s in stages) {
      s.wipe();
    }
  }

  @override
  String toString() => 'SetupVault(<redacted>, ${stages.length} stages)';
}

/// One point stage's reconstruction data: the `(o, p, q)` reservoirs and a raw
/// coordinate `(reRaw, imRaw)` inside its encoded point's leaf. All five are
/// coercion-relevant — see [SetupVault].
class VaultStage {
  VaultStage({
    required this.o,
    required this.p,
    required this.q,
    required this.reRaw,
    required this.imRaw,
  });

  int o;
  int p;
  int q;
  int reRaw;
  int imRaw;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'o': o,
        'p': p,
        'q': q,
        're': reRaw,
        'im': imRaw,
      };

  factory VaultStage.fromJson(Map<String, dynamic> json) => VaultStage(
        o: _int(json, 'o'),
        p: _int(json, 'p'),
        q: _int(json, 'q'),
        reRaw: _int(json, 're'),
        imRaw: _int(json, 'im'),
      );

  void wipe() {
    o = 0;
    p = 0;
    q = 0;
    reRaw = 0;
    imRaw = 0;
  }

  @override
  String toString() => 'VaultStage(<redacted>)';
}

/// Read an int field, throwing a generic [FormatException] (no value echoed) if
/// it is missing or the wrong type.
int _int(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  if (v is int) return v;
  throw const FormatException('bad vault');
}
