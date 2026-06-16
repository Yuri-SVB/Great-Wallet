import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/encoding_constants.dart';
import '../core/great_wall_core.dart';
import '../ffi/core_bindings.dart';
import 'setup_controller.dart';

/// Setup mode screen: encode a fresh seed onto the two-stage fractal and let
/// the user memorise the points.
///
/// This is the concrete `great-wall-core + great-wall-ux` integration the
/// architecture assigns to Setup (ARCHITECTURE.md §"7. great-wallet", mode 1):
/// great-wall-ux's [FractalCanvas] / [HueWheel] / brightness drive the visuals,
/// while a [SetupController] runs the engine's encode/Argon2 pipeline and feeds
/// the canvas its [EscapeCountSource] and overlays.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.core});

  final GreatWallCore core;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final SetupController _setup = SetupController(widget.core);

  final PanZoomController _viewport =
      PanZoomController(initial: _initialViewport);
  final BrightnessController _brightness = BrightnessController();

  HueOffset _hue = HueOffset.red;
  SizePreset _preset = SizePreset.defaultPreset;
  Argon2Profile _profile = Argon2Profile.basic;
  int _iterations = 1;

  /// Select mode: when on, tapping the canvas decodes the point under the
  /// cursor instead of panning. Toggled by the panel button or the `S` key.
  bool _selectMode = false;

  @override
  void initState() {
    super.initState();
    _setup.addListener(_onSetupChanged);
  }

  void _onSetupChanged() {
    if (!mounted) return;
    // Reset brightness to its session default when a new render stage appears,
    // honouring the "beo reset each session, never persisted" invariant.
    setState(() {});
  }

  @override
  void dispose() {
    _setup.removeListener(_onSetupChanged);
    _setup.dispose();
    _viewport.dispose();
    _brightness.dispose();
    super.dispose();
  }

  bool get _busy =>
      _setup.phase == SetupPhase.encodingStage1 ||
      _setup.phase == SetupPhase.derivingParams ||
      _setup.phase == SetupPhase.encodingStage2;

  @override
  Widget build(BuildContext context) {
    final bool hasResult = _setup.phase == SetupPhase.memorise;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _canvas()),
                if (_busy) Positioned.fill(child: _progressOverlay()),
                if (_selectMode)
                  const Positioned(
                    top: 12,
                    left: 12,
                    child: _Badge('Select mode — click a point (S to exit)'),
                  ),
              ],
            ),
          ),
          SizedBox(width: 260, child: _controlPanel(hasResult)),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyS) {
      setState(() => _selectMode = !_selectMode);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _canvas() {
    final Stage stage = _setup.displayStage;
    return FractalCanvas(
      source: widget.core.source,
      controller: _viewport,
      palette: Palette.classicWithHue(_hue),
      brightness: _brightness,
      stage: stage,
      stageParameters: stage == Stage.stage2 ? _setup.stage2Params : null,
      maxIterations: EncodingConstants.guiParams.maxIter,
      // Generated points (white, after Generate) plus selected points (green,
      // in select mode). Empty until there is something to show.
      overlays: _setup.overlaysForDisplayStage(),
      semanticLabel: 'Fractal canvas',
      // Selection is enabled only once points exist and the user turns on
      // select mode (button or `S`). Otherwise taps do nothing and the canvas
      // is pan/zoom only.
      onSelect: _selectMode
          ? (FractalSelection sel) {
              _onCanvasSelect(sel);
            }
          : null,
    );
  }

  Future<void> _onCanvasSelect(FractalSelection sel) async {
    final SelectionOutcome outcome = await _setup.selectPoint(
      sel,
      preset: _preset,
      argon2Iterations: _iterations,
      profile: _profile,
    );
    if (!mounted) return;
    final String? msg;
    switch (outcome) {
      case SelectionOutcome.invalid:
        msg = 'No encodable leaf there — zoom in and click closer.';
      case SelectionOutcome.duplicate:
        msg = 'That point is already selected.';
      case SelectionOutcome.added:
        msg = 'Selected ${_setup.selectedCount}/${_setup.requiredPerStage}.';
      case SelectionOutcome.advancedToStage2:
        msg = 'Stage 1 recalled → stage 2.';
      case SelectionOutcome.complete:
        msg = 'Recall complete — seed reconstructed.';
      case SelectionOutcome.busy:
        msg = null;
    }
    if (msg == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 900), content: Text(msg)),
    );
  }

  Widget _progressOverlay() {
    final String label;
    switch (_setup.phase) {
      case SetupPhase.encodingStage1:
        label = 'Encoding stage 1…';
      case SetupPhase.derivingParams:
        label = 'Deriving stage-2 parameters (Argon2) '
            '${_setup.argon2Done}/${_setup.argon2Total}…';
      case SetupPhase.encodingStage2:
        label = 'Encoding stage 2…';
      default:
        label = 'Working…';
    }
    final bool deriving = _setup.phase == SetupPhase.derivingParams;
    final double? progress = deriving && _setup.argon2Total > 0
        ? _setup.argon2Done / _setup.argon2Total
        : null; // indeterminate for the quick encode phases
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 260,
              child: LinearProgressIndicator(value: progress),
            ),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.white)),
            if (deriving) ...<Widget>[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _setup.requestStop,
                child: const Text('Stop'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _controlPanel(bool hasResult) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: <Widget>[
          Text('Setup', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Encode a fresh seed onto a fractal you will learn to remember. '
            'Nothing is written down.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),

          if (_setup.phase == SetupPhase.recallComplete)
            ..._recallCompleteControls()
          else if (!hasResult)
            ..._configControls()
          else
            ..._memoriseControls(),

          const Divider(height: 32),
          // Always available: selection works on whatever fractal is shown
          // (stage 1 from app start, stage 2 after derivation), and Reset
          // returns to the configuration screen without restarting the app.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Select mode'),
            subtitle: const Text('Click your points to recall (or press S)'),
            value: _selectMode,
            onChanged: (bool v) => setState(() => _selectMode = v),
          ),
          if (_selectMode && _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            Text(
              '${_setup.displayStage == Stage.stage2 ? "Stage 2" : "Stage 1"}: '
              'selected ${_setup.selectedCount}/${_preset.pointsPerStage}',
            ),
            TextButton(
              onPressed:
                  _setup.selectedCount == 0 ? null : _setup.clearSelection,
              child: const Text('Clear selection'),
            ),
          ],
          OutlinedButton.icon(
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
          ),

          const Divider(height: 32),
          const Text('Palette'),
          const SizedBox(height: 8),
          Center(
            child: HueWheel(
              value: _hue,
              onChanged: (HueOffset h) => setState(() => _hue = h),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Hold L and scroll over the canvas to adjust brightness; '
            'scroll to zoom, drag to pan.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            'engine ${widget.core.engineVersion}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  List<Widget> _configControls() {
    return <Widget>[
      const Text('Size'),
      DropdownButton<SizePreset>(
        isExpanded: true,
        value: _preset,
        onChanged: _busy
            ? null
            : (SizePreset? v) => setState(() => _preset = v ?? _preset),
        items: <DropdownMenuItem<SizePreset>>[
          for (final SizePreset p in SizePreset.values)
            DropdownMenuItem<SizePreset>(
              value: p,
              child: Text('${p.name} — ${p.bip39Words} words '
                  '(${p.entropyBits}-bit)'),
            ),
        ],
      ),
      const SizedBox(height: 16),
      const Text('Argon2 profile'),
      DropdownButton<Argon2Profile>(
        isExpanded: true,
        value: _profile,
        onChanged: _busy
            ? null
            : (Argon2Profile? v) => setState(() => _profile = v ?? _profile),
        items: const <DropdownMenuItem<Argon2Profile>>[
          DropdownMenuItem<Argon2Profile>(
            value: Argon2Profile.basic,
            child: Text('Basic (1 GiB)'),
          ),
          DropdownMenuItem<Argon2Profile>(
            value: Argon2Profile.advanced,
            child: Text('Advanced (32 GiB)'),
          ),
          DropdownMenuItem<Argon2Profile>(
            value: Argon2Profile.greatWall,
            child: Text('Great Wall (128 GiB)'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Argon2 iterations: $_iterations'),
      Slider(
        value: _iterations.toDouble(),
        min: 0,
        max: 20,
        divisions: 20,
        label: '$_iterations',
        onChanged: _busy
            ? null
            : (double v) => setState(() => _iterations = v.round()),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _start,
        child: const Text('Generate'),
      ),
      if (_setup.phase == SetupPhase.error && _setup.errorMessage != null) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          _setup.errorMessage!,
          style: const TextStyle(color: Colors.redAccent),
        ),
      ],
    ];
  }

  List<Widget> _memoriseControls() {
    return <Widget>[
      const Text('Memorise your points'),
      const SizedBox(height: 8),
      SegmentedButton<Stage>(
        segments: const <ButtonSegment<Stage>>[
          ButtonSegment<Stage>(value: Stage.stage1, label: Text('Stage 1')),
          ButtonSegment<Stage>(value: Stage.stage2, label: Text('Stage 2')),
        ],
        selected: <Stage>{_setup.displayStage},
        onSelectionChanged: (Set<Stage> s) => _setup.showStage(s.first),
      ),
      const SizedBox(height: 16),
      Text(
        'Study the marked locations on each stage until you can find them '
        'from memory. When you are confident, finish — the seed is then held '
        'only in your recall.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _setup.finish,
        child: const Text('I have memorised them'),
      ),
    ];
  }

  List<Widget> _recallCompleteControls() {
    return <Widget>[
      Row(
        children: <Widget>[
          const Icon(Icons.verified, color: Color(0xFF00E676)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Recall complete',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'Both stages were selected back and the seed was reconstructed from '
        'your points. The seed itself is never shown.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      FilledButton(onPressed: _reset, child: const Text('Done')),
    ];
  }

  Future<void> _start() async {
    _brightness.reset();
    setState(() => _selectMode = false);
    await _setup.begin(
      preset: _preset,
      argon2Iterations: _iterations,
      profile: _profile,
    );
  }

  void _reset() {
    _setup.reset();
    _brightness.reset();
    _viewport.viewport = _initialViewport;
    setState(() => _selectMode = false);
  }
}

/// Canonical default viewport (constants.py: DEFAULT_CENTER_*, VIEWPORT_BASE_SPAN
/// = 4.0 -> halfExtent 2.0).
const FractalViewport _initialViewport = FractalViewport(
  centreRe: -0.5,
  centreIm: -0.5,
  halfExtent: 2.0,
  widthPx: 1,
  heightPx: 1,
  devicePixelRatio: 1.0,
);

/// Small translucent label shown over the canvas (e.g. the select-mode hint).
class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
