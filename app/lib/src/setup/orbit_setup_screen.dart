import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/encoding_constants.dart';
import '../core/great_wall_core.dart';
import '../core/namtso_harvester.dart';
import '../core/orbit_protocol.dart';
import '../core/stage_params.dart';
import 'orbit_setup_controller.dart';

/// The **orbit (0.4.0) Setup flow** — the coercion-resistant setup that places
/// `t_i` (= `r_i`) fractal points per deep stage, combines them by Shamir into
/// `K_i`, and advances the orbit memory-hard between stages.
///
/// This is a SEPARATE flow, offered alongside the legacy 0.3.0 chain Setup
/// (which stays as a fallback). It walks one board at a time: pick a tier + σ,
/// then for each stage place (or generate) a point on each of its `t_i` boards;
/// finishing a stage runs the advance and moves on. On completion it shows the
/// terminal `K_N` and per-stage `K_i`.
///
/// SECURITY: reservoirs, placed points, and K_i live in [OrbitSetupController]'s
/// state; nothing here logs coordinates or key material (SCOPE.md).
class OrbitSetupScreen extends StatefulWidget {
  const OrbitSetupScreen({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<OrbitSetupScreen> createState() => _OrbitSetupScreenState();
}

class _OrbitSetupScreenState extends State<OrbitSetupScreen> {
  static const int _sigmaBytes = 128; // Namtso's 1024-bit width.

  /// Canonical default viewport (mirrors setup_screen's `_initialViewport`).
  static const FractalViewport _initialViewport = FractalViewport(
    centreRe: -0.5,
    centreIm: -0.5,
    halfExtent: 2.0,
    widthPx: 1,
    heightPx: 1,
    devicePixelRatio: 1.0,
  );

  late final OrbitSetupController _setup =
      OrbitSetupController(widget.core)..addListener(_onChange);
  final PanZoomController _viewport =
      PanZoomController(initial: _initialViewport);
  final BrightnessController _brightness = BrightnessController();
  final SoundBoard _sounds = SoundBoard();
  final TextEditingController _sigmaCtrl = TextEditingController();

  int _level = 2;
  bool _cheapAdvance = false;
  String? _configError;

  // σ harvest (Namtso) state.
  bool _harvesting = false;
  String? _harvestNote;
  DateTime? _harvestedDate;
  HarvestSession? _harvestSession;

  // Board navigation: deep render raises the escape-count cap so leaves buried
  // in high-iteration voids become visible to tap (mirrors the legacy Alt+L).
  bool _deepRender = false;

  int get _renderMaxIter => _deepRender
      ? widget.core.encodeParams.maxIter
      : EncodingConstants.renderMaxIterFast;

  // Track the board being shown so the viewport recenters on each new fractal.
  (int, int)? _shownBoard;

  /// The current board's display-proxy params (doubles) for the canvas. The
  /// authoritative u64 reservoirs ride [GreatWallCore.source]`.reservoirs`
  /// instead (see [_applyBoardReservoirs]); this only drives repaints.
  StageParameters? _boardParams;

  @override
  void initState() {
    super.initState();
    _sigmaCtrl.text = _randomHex(_sigmaBytes);
  }

  @override
  void dispose() {
    // Kill any in-flight Namtso process so it can't outlive the screen.
    _harvestSession?.cancel();
    // Release the shared render source so a mid-placement exit leaves no stale
    // orbit fractal for the legacy Setup mode (which sets its own reservoirs).
    widget.core.source.reservoirs = null;
    widget.core.leafSource.reservoirs = null;
    _setup.removeListener(_onChange);
    _setup.dispose();
    _viewport.dispose();
    _brightness.dispose();
    _sounds.dispose();
    _sigmaCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    // Recenter the canvas whenever the active board changes — each board is a
    // different fractal, so the previous pan/zoom is meaningless on it.
    if (_setup.phase == OrbitSetupPhase.placing) {
      final (int, int) key = (_setup.stageIndex, _setup.boardIndex);
      if (_shownBoard != key) {
        _shownBoard = key;
        _applyBoardReservoirs();
        _viewport.viewport = _initialViewport;
        _brightness.reset();
        // A new fractal renders fast by default; deep render is re-armed per board.
        _deepRender = false;
      }
    } else {
      _shownBoard = null;
      // Leaving placement: drop the render reservoirs so no stale fractal shows.
      widget.core.source.reservoirs = null;
      widget.core.leafSource.reservoirs = null;
      _boardParams = null;
    }
    if (mounted) setState(() {});
  }

  /// Point the render source at the current board's **authoritative** u64
  /// reservoirs and build the display-proxy [StageParameters] (doubles) the
  /// canvas uses only to trigger repaints — mirroring setup_controller's
  /// `_applyReservoirs`. The u64s never ride `StageParameters` (which is
  /// `double`-typed); the engine reads them from the source (stage_params.dart).
  void _applyBoardReservoirs() {
    final ({int o, int p, int q})? prm = _setup.currentBoardParams;
    if (prm == null) {
      widget.core.source.reservoirs = null;
      widget.core.leafSource.reservoirs = null;
      _boardParams = null;
      return;
    }
    final StageReservoirs res =
        StageReservoirs(o: prm.o, p: prm.p, q: prm.q);
    widget.core.source.reservoirs = res;
    widget.core.leafSource.reservoirs = res;
    final ({double o, double p, double q}) key = res.displayKey;
    _boardParams = StageParameters(o: key.o, p: key.p, q: key.q);
  }

  Future<Uint8List> _cheapAdvanceFn(Uint8List o, Uint8List shBytes) async {
    final Uint8List tag = Uint8List.fromList('ORBIT-ADVANCE'.codeUnits);
    final Uint8List m = Uint8List(o.length + shBytes.length + tag.length)
      ..setAll(0, o)
      ..setAll(o.length, shBytes)
      ..setAll(o.length + shBytes.length, tag);
    return Uint8List.fromList(crypto.sha256.convert(m).bytes);
  }

  void _recenter() {
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  void _toggleDeepRender() => setState(() => _deepRender = !_deepRender);

  /// Pick a date and harvest σ from the Namtso CLI (desktop). Fills the σ field
  /// on success; on failure keeps manual entry available and shows why.
  Future<void> _harvestFromDate() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _harvestedDate ?? today,
      firstDate: DateTime(2009, 1, 3), // Bitcoin genesis
      lastDate: today,
      helpText: 'Harvest σ from the timechain at a date',
    );
    if (picked == null) return;
    setState(() {
      _harvesting = true;
      _harvestNote = null;
      _configError = null;
    });
    final HarvestSession session = const NamtsoHarvester().start(date: picked);
    _harvestSession = session;
    try {
      final String sigma = await session.result;
      if (!mounted) return;
      setState(() {
        _sigmaCtrl.text = sigma;
        _harvestedDate = picked;
        _harvestNote = 'σ harvested for ${_isoDate(picked)} '
            '(${sigma.length ~/ 2} bytes).';
      });
    } on NamtsoCancelled {
      if (mounted) setState(() => _harvestNote = 'Harvest cancelled.');
    } on NamtsoUnavailable catch (e) {
      if (mounted) {
        setState(() => _configError = 'Namtso unavailable: ${e.message}\n'
            'Build it with app/native/build_namtso.sh, or enter σ manually.');
      }
    } on NamtsoError catch (e) {
      if (mounted) setState(() => _configError = e.message);
    } finally {
      _harvestSession = null;
      if (mounted) setState(() => _harvesting = false);
    }
  }

  void _cancelHarvest() => _harvestSession?.cancel();

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void _begin() {
    final Uint8List? sigma = _parseHex(_sigmaCtrl.text.trim());
    if (sigma == null || sigma.isEmpty) {
      setState(() => _configError =
          'σ must be non-empty hex (even number of hex digits).');
      return;
    }
    setState(() => _configError = null);
    _setup.begin(
      level: _level,
      sigma: sigma,
      advanceFn: _cheapAdvance ? _cheapAdvanceFn : null,
    );
  }

  Future<void> _onSelect(FractalSelection sel) async {
    final OrbitPlaceOutcome o = await _setup.placeAt(sel.re, sel.im);
    _reactToOutcome(o);
  }

  Future<void> _generate() async {
    final OrbitPlaceOutcome o = await _setup.placeGenerated();
    _reactToOutcome(o);
  }

  void _reactToOutcome(OrbitPlaceOutcome o) {
    switch (o) {
      case OrbitPlaceOutcome.invalid:
        _sounds.play(UiSound.deny);
        _toast('No encodable leaf there — tap on a visible island.');
      case OrbitPlaceOutcome.marked:
      case OrbitPlaceOutcome.stageAdvanced:
      case OrbitPlaceOutcome.complete:
        _sounds.play(UiSound.selectPoint);
      case OrbitPlaceOutcome.busy:
        break;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_setup.phase) {
      case OrbitSetupPhase.idle:
        return _configView(context);
      case OrbitSetupPhase.placing:
        return _boardView(context);
      case OrbitSetupPhase.advancing:
        return _advancingView(context);
      case OrbitSetupPhase.complete:
        return _completeView(context);
      case OrbitSetupPhase.error:
        return _errorView(context);
    }
  }

  // --- idle: tier + σ -------------------------------------------------------

  Widget _configView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> thr = widget.core.setupTierThresholds(_level);
    final bool substandard = widget.core.setupTierSubstandard(_level);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Orbit Setup (0.4.0)', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Places rᵢ fractal points per deep stage and combines them by '
            'Shamir into each stage secret Kᵢ, advancing the orbit memory-hard '
            'between stages. The legacy chain Setup remains available as a '
            'fallback.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),

          Text('Setup tier', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              DropdownButton<int>(
                value: _level,
                onChanged: (int? v) => setState(() => _level = v ?? _level),
                items: <DropdownMenuItem<int>>[
                  for (int lvl = 1; lvl <= 5; lvl++)
                    DropdownMenuItem<int>(
                      value: lvl,
                      child: Text('Setup $lvl  →  '
                          '${widget.core.setupTierThresholds(lvl)}'),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              if (thr.isNotEmpty)
                Text('${_boardTotal(thr)} boards across ${thr.length} stages',
                    style: theme.textTheme.bodySmall),
            ],
          ),
          if (substandard) ...<Widget>[
            const SizedBox(height: 8),
            _substandardBanner(theme),
          ],
          const SizedBox(height: 24),

          Text('σ (Namtso salt) — hex', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _sigmaCtrl,
            maxLines: 2,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Randomize σ',
                icon: const Icon(Icons.casino),
                onPressed: () => _sigmaCtrl.text = _randomHex(_sigmaBytes),
              ),
            ),
          ),
          if (NamtsoHarvester.isSupported) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _harvesting ? null : _harvestFromDate,
                  icon: const Icon(Icons.calendar_month),
                  label: const Text('Harvest from date (Namtso)'),
                ),
                const SizedBox(width: 12),
                if (_harvesting) ...<Widget>[
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text('Fetching headers…', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: _cancelHarvest,
                    child: const Text('Cancel'),
                  ),
                ],
                if (_harvestNote != null && !_harvesting)
                  Expanded(
                    child: Text(_harvestNote!,
                        style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
            Text(
              'Derives σ from Bitcoin block headers at the chosen date '
              '(needs the built namtso CLI and network). Or paste/randomize σ '
              'above.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cheap advance (skip Argon2d) — dev'),
            subtitle: Text(
              _cheapAdvance
                  ? 'Instant advance between stages (NOT the real H*).'
                  : 'Real memory-hard advance: ~40 s per stage, ≥1 GiB.',
              style: theme.textTheme.bodySmall,
            ),
            value: _cheapAdvance,
            onChanged: (bool v) => setState(() => _cheapAdvance = v),
          ),
          if (_configError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_configError!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: thr.isEmpty ? null : _begin,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Begin orbit setup'),
          ),
        ],
      ),
    );
  }

  // --- placing: one board at a time -----------------------------------------

  Widget _boardView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final StageParameters? bp = _boardParams;
    final bool deep = _setup.stageIndex > 0;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Stage ${_setup.stageIndex} — board '
                      '${_setup.boardIndex + 1} of ${_setup.boardCount}'
                      '${deep ? '  (deep, rᵢ=${_setup.boardCount})' : '  (stage 0)'}',
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      'Drag to pan, scroll to zoom; tap a leaf to place this '
                      'board’s point — or Generate a random one.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Recenter',
                onPressed: _recenter,
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton(
                tooltip: 'Deep render — reveal leaves in escape-count voids '
                    '(slower)',
                onPressed: _toggleDeepRender,
                icon: Icon(
                  _deepRender ? Icons.visibility : Icons.visibility_outlined,
                  color: _deepRender ? theme.colorScheme.primary : null,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _generate,
                icon: const Icon(Icons.shuffle),
                label: const Text('Generate'),
              ),
            ],
          ),
        ),
        if (_setup.substandard)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _substandardBanner(theme),
          ),
        Expanded(
          child: bp == null
              ? const Center(child: CircularProgressIndicator())
              : FractalCanvas(
                  source: widget.core.source,
                  controller: _viewport,
                  palette: Palette.classicWithHue(HueOffset.red),
                  brightness: _brightness,
                  sounds: _sounds,
                  stage: Stage.stage2,
                  stageParameters: bp,
                  maxIterations: _renderMaxIter,
                  overlays: CanvasOverlays(
                    crosshairs: false,
                    islands: const <CanvasIsland>[],
                    frames: const <SelectionFrame>[],
                    crosses: const <CrossMarker>[],
                  ),
                  semanticLabel: 'Orbit fractal board',
                  onSelect: (FractalSelection sel) {
                    _onSelect(sel);
                  },
                ),
        ),
      ],
    );
  }

  // --- advancing ------------------------------------------------------------

  Widget _advancingView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text('Advancing the orbit', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _cheapAdvance
                ? 'Deriving o_{i+1} (cheap dev advance)…'
                : 'Deriving o_{i+1} = H*(K_i) — memory-hard, ~40 s…',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  // --- complete -------------------------------------------------------------

  Widget _completeView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uint8List? k = _setup.terminalK;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Text('Orbit setup complete', style: theme.textTheme.headlineSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text('Setup $_level  ${_setup.thresholds}'
              '${_setup.substandard ? '  (substandard)' : ''}',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          Text('Per-stage K_i (first 16 hex):',
              style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final OrbitStage st in _setup.stages)
            Text(
              '${st.index == 0 ? 'stage 0' : 'stage ${st.index}'} '
              '(t=${st.threshold}): ${_hex(st.k).substring(0, 16)}…',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          if (k != null)
            SelectableText('terminal K = ${_hex(k).substring(0, 32)}…',
                style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _setup.resetToIdle,
            icon: const Icon(Icons.refresh),
            label: const Text('Start over'),
          ),
        ],
      ),
    );
  }

  // --- error ----------------------------------------------------------------

  Widget _errorView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error, color: theme.colorScheme.error, size: 40),
            const SizedBox(height: 12),
            Text('Orbit setup failed', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_setup.error ?? 'unknown error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _setup.resetToIdle,
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  // --- shared pieces --------------------------------------------------------

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
                'SUBSTANDARD: Setup 1 uses a 64-bit deep stage (r₁ = 2), below '
                'the 96-bit standard. It is offered only as an entry tier — '
                'prefer Setup ≥ 2 for a real vault.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      );

  // --- helpers --------------------------------------------------------------

  static int _boardTotal(List<int> thresholds) =>
      thresholds.fold(0, (int a, int b) => a + b);

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
}
