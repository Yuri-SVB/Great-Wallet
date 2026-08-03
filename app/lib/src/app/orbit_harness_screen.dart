import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';

import '../core/great_wall_core.dart';
import '../core/orbit_protocol.dart';
import '../ffi/core_bindings.dart';

/// A **developer harness** for the 0.4.0 orbit protocol — a way to *see the
/// orbit run inside the app* (real σ → o₀, per-stage `t_i` boards → Shamir →
/// `K_i`, memory-hard advance `o_{i+1} = H*(K_i)`, round-trip) before the
/// production multi-board Setup UX exists.
///
/// It drives [OrbitProtocol] end-to-end with **auto-generated** entropy — it
/// does NOT render interactive fractal boards (that placement UX is the next
/// step). So it verifies the engine + orchestration + isolates + Argon2d run
/// correctly on-device; it does not exercise the human point-placement that
/// gives the protocol its coercion resistance.
///
/// SECURITY: this is a throwaway dev surface. Inputs are random, not a real
/// vault; the K_i shown are for random material. Do not paste a real σ or real
/// entropy here. Nothing is persisted or logged — values live only in widget
/// state for the session.
class OrbitHarnessScreen extends StatefulWidget {
  const OrbitHarnessScreen({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<OrbitHarnessScreen> createState() => _OrbitHarnessScreenState();
}

class _OrbitHarnessScreenState extends State<OrbitHarnessScreen> {
  static const int _sigmaBytes = 128; // Namtso's 1024-bit width.

  final TextEditingController _sigmaCtrl = TextEditingController();
  int _level = 2;
  bool _cheapAdvance = true; // default off the memory-hard path for snappy dev.
  bool _running = false;
  String _status = '';
  String? _error;
  _OrbitRunResult? _result;

  @override
  void initState() {
    super.initState();
    _sigmaCtrl.text = _randomHex(_sigmaBytes);
  }

  @override
  void dispose() {
    _sigmaCtrl.dispose();
    super.dispose();
  }

  GreatWallCore get _core => widget.core;

  List<int> get _thresholds => _core.setupTierThresholds(_level);
  bool get _substandard => _core.setupTierSubstandard(_level);

  Future<void> _run() async {
    final Uint8List? sigma = _parseHex(_sigmaCtrl.text.trim());
    if (sigma == null || sigma.isEmpty) {
      setState(() {
        _error = 'σ must be non-empty hex (even number of hex digits).';
        _result = null;
      });
      return;
    }
    final List<int> thresholds = _thresholds;
    if (thresholds.isEmpty) {
      setState(() => _error = 'invalid setup level $_level');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _status = 'deriving o₀ = H(σ) …';
    });

    try {
      final OrbitProtocol orbit = OrbitProtocol(_core);

      // Auto-generate one random 32-bit chunk per board of every stage.
      final math.Random rng = math.Random();
      final List<List<List<int>>> stageChunks = <List<List<int>>>[
        for (final int t in thresholds)
          <List<int>>[
            for (int b = 0; b < t; b++)
              <int>[for (int i = 0; i < 32; i++) rng.nextInt(2)],
          ],
      ];

      // Progress is reported around the advance (the slow, memory-hard step);
      // the injected advanceFn wraps the real engine advance (or a cheap
      // deterministic stand-in when the dev toggle is on).
      int advancedAfter = 0;
      final int nStages = thresholds.length;
      Future<Uint8List> advance(Uint8List o, Uint8List shBytes) async {
        final bool last = advancedAfter == nStages - 1;
        if (!last && mounted) {
          setState(() => _status = _cheapAdvance
              ? 'advancing (cheap) after stage $advancedAfter …'
              : 'advancing (Argon2d, ~40s) after stage $advancedAfter …');
        }
        final Uint8List next;
        if (_cheapAdvance) {
          next = _cheapAdvanceDigest(o, shBytes);
        } else {
          final ({Uint8List k, Uint8List next}) r = await _core.advanceOrbit(
              o, shBytes,
              steps: 1, profile: Argon2Profile.basic);
          next = r.next;
        }
        advancedAfter++;
        return next;
      }

      setState(() => _status = 'encoding ${_boardTotal(thresholds)} boards '
          'across $nStages stages …');
      final ({List<OrbitStage> stages, Uint8List k}) enc =
          await orbit.encodeOrbit(sigma, _level, stageChunks,
              advanceFn: advance);

      // Decode the encoded points back and confirm the entropy + K round-trip.
      if (mounted) setState(() => _status = 'decoding & verifying round-trip …');
      advancedAfter = 0; // reset the progress counter for the decode pass
      final List<List<({int reRaw, int imRaw})>> stagePoints =
          <List<({int reRaw, int imRaw})>>[
        for (final OrbitStage st in enc.stages) st.points,
      ];
      final ({List<List<List<int>>> stageChunks, Uint8List k}) dec =
          await orbit.decodeOrbit(sigma, _level, stagePoints,
              advanceFn: advance);

      final bool entropyOk = _deepEq(dec.stageChunks, stageChunks);
      final bool kOk = _bytesEq(dec.k, enc.k);

      if (!mounted) return;
      setState(() {
        _result = _OrbitRunResult(
          thresholds: thresholds,
          substandard: _substandard,
          cheapAdvance: _cheapAdvance,
          perStageK: <String>[
            for (final OrbitStage st in enc.stages)
              _shortHex(st.k, st.index, st.threshold),
          ],
          terminalK: _hex(enc.k),
          entropyRoundTrips: entropyOk,
          kRoundTrips: kOk,
        );
        _status = '';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> thresholds = _thresholds;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _devBanner(theme),
          const SizedBox(height: 20),

          // Setup tier
          Text('Setup tier', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              DropdownButton<int>(
                value: _level,
                onChanged: _running
                    ? null
                    : (int? v) => setState(() => _level = v ?? _level),
                items: <DropdownMenuItem<int>>[
                  for (int lvl = 1; lvl <= 5; lvl++)
                    DropdownMenuItem<int>(
                      value: lvl,
                      child: Text('Setup $lvl  →  '
                          '${_core.setupTierThresholds(lvl)}'),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              if (thresholds.isNotEmpty)
                Text('${_boardTotal(thresholds)} boards, '
                    '${thresholds.length} stages',
                    style: theme.textTheme.bodySmall),
            ],
          ),
          if (_substandard) ...<Widget>[
            const SizedBox(height: 8),
            _substandardBanner(theme),
          ],
          const SizedBox(height: 20),

          // Sigma
          Text('σ (Namtso salt) — hex', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _sigmaCtrl,
            enabled: !_running,
            maxLines: 2,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Randomize σ (dev)',
                icon: const Icon(Icons.casino),
                onPressed:
                    _running ? null : () => _sigmaCtrl.text = _randomHex(_sigmaBytes),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Options + run
          Row(
            children: <Widget>[
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cheap advance (skip Argon2d)'),
                  subtitle: Text(
                    _cheapAdvance
                        ? 'Instant — structural test only (not the real H*).'
                        : 'Real memory-hard advance: ~40 s per stage, ≥1 GiB.',
                    style: theme.textTheme.bodySmall,
                  ),
                  value: _cheapAdvance,
                  onChanged:
                      _running ? null : (bool v) => setState(() => _cheapAdvance = v),
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run orbit'),
              ),
            ],
          ),
          const SizedBox(height: 20),

          if (_running) _statusRow(theme),
          if (_error != null) _errorBox(theme, _error!),
          if (_result != null) _resultCard(theme, _result!),
        ],
      ),
    );
  }

  // --- pieces ---------------------------------------------------------------

  Widget _devBanner(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outline),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.science_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'DEV HARNESS — drives the orbit end-to-end with random inputs '
                'to verify the engine runs on-device. It does NOT render '
                'interactive boards (the placement UX is next). Do not enter a '
                'real σ or real entropy here.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );

  Widget _substandardBanner(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'SUBSTANDARD: Setup 1 uses a 64-bit deep stage (r₁ = 2). It is '
                'below the 96-bit standard — offered only as an entry tier. '
                'Prefer Setup ≥ 2 for a real vault.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      );

  Widget _statusRow(ThemeData theme) => Row(
        children: <Widget>[
          const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(_status, style: theme.textTheme.bodyMedium)),
        ],
      );

  Widget _errorBox(ThemeData theme, String msg) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('Error: $msg',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onErrorContainer)),
      );

  Widget _resultCard(ThemeData theme, _OrbitRunResult r) {
    final bool ok = r.entropyRoundTrips && r.kRoundTrips;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(ok ? Icons.check_circle : Icons.error,
                    color: ok ? Colors.green : theme.colorScheme.error),
                const SizedBox(width: 8),
                Text(
                  ok ? 'Orbit round-trip OK' : 'Round-trip FAILED',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv(theme, 'Tier', 'Setup ${_level}  ${r.thresholds}'
                '${r.substandard ? '  (substandard)' : ''}'),
            _kv(theme, 'Advance', r.cheapAdvance ? 'cheap (dev)' : 'Argon2d (real H*)'),
            _kv(theme, 'Entropy round-trips', r.entropyRoundTrips ? 'yes' : 'NO'),
            _kv(theme, 'K matches enc/dec', r.kRoundTrips ? 'yes' : 'NO'),
            const SizedBox(height: 12),
            Text('Per-stage K_i (first 16 hex):',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final String line in r.perStageK)
              Text(line, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            SelectableText('terminal K = ${r.terminalK.substring(0, 32)}…',
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 170, child: Text(k, style: theme.textTheme.bodyMedium)),
            Expanded(
                child: Text(v,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  // --- helpers --------------------------------------------------------------

  static int _boardTotal(List<int> thresholds) =>
      thresholds.fold(0, (int a, int b) => a + b);

  String _shortHex(Uint8List k, int index, int threshold) {
    final String h = _hex(k);
    final String tag = index == 0 ? 'stage 0' : 'stage $index';
    return '$tag (t=$threshold): ${h.substring(0, 16)}…';
  }

  /// A cheap, deterministic stand-in for the memory-hard advance
  /// `o_{i+1} = H*(K_i)` — SHA-256(o ‖ Sh ‖ "ORBIT-ADVANCE"). Byte-identical to
  /// the reference's `cheap_advance` (test_orbit_protocol.py). Encode and decode
  /// share it within a run, so the bijection holds; it is NOT the real H*.
  static Uint8List _cheapAdvanceDigest(Uint8List o, Uint8List shBytes) {
    final Uint8List tag = Uint8List.fromList('ORBIT-ADVANCE'.codeUnits);
    final Uint8List m = Uint8List(o.length + shBytes.length + tag.length)
      ..setAll(0, o)
      ..setAll(o.length, shBytes)
      ..setAll(o.length + shBytes.length, tag);
    return Uint8List.fromList(crypto.sha256.convert(m).bytes);
  }

  static String _randomHex(int nBytes) {
    final math.Random rng = math.Random();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < nBytes; i++) {
      sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _hex(Uint8List bytes) {
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List? _parseHex(String s) {
    final String h = s.replaceAll(RegExp(r'\s'), '');
    if (h.isEmpty || h.length.isOdd) return null;
    final Uint8List out = Uint8List(h.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      final int? b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  static bool _bytesEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _deepEq(List<List<List<int>>> a, List<List<List<int>>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (int j = 0; j < a[i].length; j++) {
        if (a[i][j].length != b[i][j].length) return false;
        for (int k = 0; k < a[i][j].length; k++) {
          if (a[i][j][k] != b[i][j][k]) return false;
        }
      }
    }
    return true;
  }
}

/// The outcome of one harness run, held in widget state only.
class _OrbitRunResult {
  const _OrbitRunResult({
    required this.thresholds,
    required this.substandard,
    required this.cheapAdvance,
    required this.perStageK,
    required this.terminalK,
    required this.entropyRoundTrips,
    required this.kRoundTrips,
  });

  final List<int> thresholds;
  final bool substandard;
  final bool cheapAdvance;
  final List<String> perStageK;
  final String terminalK;
  final bool entropyRoundTrips;
  final bool kRoundTrips;
}
