import 'dart:io';

/// Harvests the orbit salt σ from the **Namtso** CLI (the flat submodule
/// `namtso-the-sacred-salt`), which derives a 1024-bit σ from the Bitcoin
/// timechain's block headers at a target date (SHAKE256 over a header window).
///
/// This is the sole seam between the app and Namtso on desktop: the app shells
/// out to the built `namtso` binary — `namtso harvest --date YYYY-MM-DD
/// --explorer ""` — which prints the σ hex on its first stdout line, then the
/// receipt JSON. great-wall-core never depends on Namtso; it only consumes the
/// pre-harvested σ (ARCHITECTURE.md §"Submodule Rules").
///
/// Desktop-only: it spawns a process and reaches the network. On mobile/web (no
/// `Process`, no bundled binary) callers fall back to manual σ entry.
class NamtsoHarvester {
  const NamtsoHarvester();

  /// Whether harvesting is even possible on this platform (needs `Process`).
  static bool get isSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Harvest σ for [date] and return it as a lowercase hex string (256 hex
  /// chars = 128 bytes). [network] and [window] map to the CLI flags; [explorer]
  /// is the comma-separated explorer list (empty string ⇒ Namtso's default
  /// public explorers). Runs Namtso's network path — it can take a few seconds
  /// and needs connectivity.
  ///
  /// Throws [NamtsoUnavailable] if the binary can't be found, or [NamtsoError]
  /// with the CLI's stderr on a non-zero exit / unparseable output.
  Future<String> harvest({
    required DateTime date,
    String network = 'mainnet',
    int window = 32,
    String explorer = '',
  }) async {
    if (!isSupported) {
      throw const NamtsoUnavailable(
        'Namtso harvest needs a desktop build (Process support). '
        'Enter σ manually on this platform.',
      );
    }
    final String bin = _locateBinary();
    final List<String> args = <String>[
      'harvest',
      '--date',
      _isoDate(date),
      '--network',
      network,
      '--window',
      '$window',
      '--explorer',
      explorer,
    ];
    final ProcessResult res;
    try {
      res = await Process.run(bin, args);
    } on ProcessException catch (e) {
      throw NamtsoUnavailable('could not run namtso ($bin): ${e.message}');
    }
    if (res.exitCode != 0) {
      final String err = (res.stderr as String).trim();
      throw NamtsoError('namtso harvest failed (exit ${res.exitCode})'
          '${err.isEmpty ? '' : ':\n$err'}');
    }
    // The σ hex is the first stdout line; the receipt JSON follows.
    final String out = (res.stdout as String).trim();
    final String first =
        out.split('\n').firstWhere((String l) => l.trim().isNotEmpty,
            orElse: () => '');
    final String sigma = first.trim().toLowerCase();
    if (!_looksLikeSigmaHex(sigma)) {
      throw NamtsoError(
          'namtso output did not start with a σ hex line (got "${_ellipsis(first)}").');
    }
    return sigma;
  }

  /// Probe order for the `namtso` binary: an explicit env override, the flat
  /// submodule's cargo output (dev builds), then whatever is on `PATH`.
  String _locateBinary() {
    final String exe = Platform.isWindows ? 'namtso.exe' : 'namtso';
    final String? override = Platform.environment['NAMTSO_BIN'];
    final String sep = Platform.pathSeparator;
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      if (override != null && override.isNotEmpty) override,
      // app/ is a sibling of the namtso submodule inside great-wallet.
      <String>['..', 'namtso-the-sacred-salt', 'target', 'release', exe].join(sep),
      // Packaged builds bundle the binary next to the executable.
      <String>[exeDir, exe].join(sep),
    ];
    for (final String path in candidates) {
      if (File(path).existsSync()) return path;
    }
    // Last resort: let the OS resolve it on PATH.
    return exe;
  }

  static String _isoDate(DateTime d) {
    final String y = d.year.toString().padLeft(4, '0');
    final String m = d.month.toString().padLeft(2, '0');
    final String day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static bool _looksLikeSigmaHex(String s) =>
      s.length >= 2 && s.length.isEven && RegExp(r'^[0-9a-f]+$').hasMatch(s);

  static String _ellipsis(String s) =>
      s.length <= 24 ? s : '${s.substring(0, 24)}…';
}

/// The Namtso binary could not be located or executed (build it with
/// `app/native/build_namtso.sh`, or this platform can't shell out).
class NamtsoUnavailable implements Exception {
  const NamtsoUnavailable(this.message);
  final String message;
  @override
  String toString() => 'NamtsoUnavailable: $message';
}

/// The Namtso CLI ran but reported an error (bad date, no connectivity, …).
class NamtsoError implements Exception {
  const NamtsoError(this.message);
  final String message;
  @override
  String toString() => 'NamtsoError: $message';
}
