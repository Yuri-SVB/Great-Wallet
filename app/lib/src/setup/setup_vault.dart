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
    this.resume,
  });

  /// On-disk format version of a **settled** provisional key, so a future change
  /// can be detected and rejected rather than silently misread.
  static const int formatVersion = 1;

  /// Format version of a **resumable** vault — one that also carries the
  /// [resume] state of a halted, mid-derivation setup. Distinct from
  /// [formatVersion] so a settled v1 file stays byte-for-byte unchanged and both
  /// are still accepted on load.
  static const int resumableVersion = 2;

  /// The canonicalised Stage-0 salt/pepper (may itself be a secret pepper).
  final String text;

  /// `N` — Argon2 iterations per stage.
  final int iterations;

  /// `m` — the Argon2 memory profile.
  final Argon2Profile profile;

  /// One entry per **already-derived** point stage, in chain order. For a
  /// settled vault that is every stage (1..S); for a resumable one it is only
  /// the prefix before the halted stage (which may be empty if the halt landed
  /// on Stage 1).
  final List<VaultStage> stages;

  /// Present only on a **resumable** vault: everything needed to continue the
  /// memory-hard derivation in a later session (the entropy root, the halted
  /// stage's checkpoint, and the stage geometry). Null for a settled key.
  final VaultResume? resume;

  int get _version => resume == null ? formatVersion : resumableVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': _version,
        'text': text,
        'iterations': iterations,
        'profile': profile.value,
        'stages': <Map<String, dynamic>>[for (final VaultStage s in stages) s.toJson()],
        if (resume != null) 'resume': resume!.toJson(),
      };

  /// Rebuild a vault from decoded JSON. Throws a generic [FormatException] on any
  /// missing/ill-typed field or unknown version — the message never echoes
  /// values (a wrong-password decrypt that yields garbage must fail opaquely).
  factory SetupVault.fromJson(Map<String, dynamic> json) {
    final int v = _int(json, 'v');
    if (v != formatVersion && v != resumableVersion) {
      throw const FormatException('unsupported vault version');
    }
    final bool resumable = v == resumableVersion;
    final Object? text = json['text'];
    if (text is! String) throw const FormatException('bad vault');
    final int profileCode = _int(json, 'profile');
    final Argon2Profile profile = Argon2Profile.values.firstWhere(
      (Argon2Profile p) => p.value == profileCode,
      orElse: () => throw const FormatException('bad vault'),
    );
    final Object? rawStages = json['stages'];
    // A settled vault must carry every stage; a resumable one may have an empty
    // prefix (halted on Stage 1), so only the type is enforced there.
    if (rawStages is! List || (!resumable && rawStages.isEmpty)) {
      throw const FormatException('bad vault');
    }
    VaultResume? resume;
    if (resumable) {
      final Object? rawResume = json['resume'];
      if (rawResume is! Map<String, dynamic>) {
        throw const FormatException('bad vault');
      }
      resume = VaultResume.fromJson(rawResume);
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
      resume: resume,
    );
  }

  /// Zero every stage's secret integers (and the [resume] secrets, if any). The
  /// [text] is an immutable String and cannot be overwritten (the controller's
  /// own salt/pepper has the same limitation); drop all references to let it be
  /// collected.
  void wipe() {
    for (final VaultStage s in stages) {
      s.wipe();
    }
    resume?.wipe();
  }

  @override
  String toString() => 'SetupVault(<redacted>, ${stages.length} stages'
      '${resume == null ? '' : ', resumable'})';
}

/// The resume-state of a halted, mid-derivation setup — what a [SetupVault] must
/// carry so the memory-hard Argon2 chain can be continued in a later session.
///
/// SECURITY — this is the **strongest** secret the app persists: [entropy] is
/// the entire seed root, so the encrypted file plus its key reconstruct the
/// whole wallet, not merely the consolidation-window provisional key. It exists
/// only inside an encrypted [SetupVault] (never plaintext) and [wipe] zeroes the
/// secret buffers. Treat a resumable vault with the same care as the seed.
class VaultResume {
  VaultResume({
    required this.stage,
    required this.pass,
    required this.total,
    required this.pointStages,
    required this.digest,
    required this.entropy,
  });

  /// The halted point stage (1..[pointStages]) — the one to resume.
  final int stage;

  /// Argon2 passes completed on the halted stage (the chain continues here).
  final int pass;

  /// `N` — total Argon2 passes per stage (sanity-checked against [pass]).
  final int total;

  /// `S` — total point stages, so a load knows how many remain after [stage].
  final int pointStages;

  /// The halted stage's preserved intermediary digest (its result after [pass]
  /// passes). Coercion-relevant.
  List<int> digest;

  /// The entropy root (m × 32 bits, one bit per int) the rest of the chain
  /// derives from. Coercion-relevant — the full seed; see the class note.
  List<int> entropy;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stage': stage,
        'pass': pass,
        'total': total,
        'pts': pointStages,
        'digest': digest,
        'entropy': entropy,
      };

  factory VaultResume.fromJson(Map<String, dynamic> json) => VaultResume(
        stage: _int(json, 'stage'),
        pass: _int(json, 'pass'),
        total: _int(json, 'total'),
        pointStages: _int(json, 'pts'),
        digest: _intList(json, 'digest'),
        entropy: _intList(json, 'entropy'),
      );

  void wipe() {
    for (int i = 0; i < digest.length; i++) {
      digest[i] = 0;
    }
    for (int i = 0; i < entropy.length; i++) {
      entropy[i] = 0;
    }
  }

  @override
  String toString() => 'VaultResume(<redacted>)';
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

/// Read a `List<int>` field (a decoded JSON array of ints), throwing a generic
/// [FormatException] (no value echoed) if it is missing or ill-typed.
List<int> _intList(Map<String, dynamic> json, String key) {
  final Object? v = json[key];
  if (v is! List) throw const FormatException('bad vault');
  return <int>[
    for (final Object? e in v) e is int ? e : throw const FormatException('bad vault'),
  ];
}
