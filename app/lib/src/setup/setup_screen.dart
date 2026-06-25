import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart';

import '../core/encoding_constants.dart';
import '../core/great_wall_core.dart';
import '../ffi/core_bindings.dart';
import 'setup_controller.dart';

/// Setup mode screen: encode a fresh seed onto the chained fractals (one
/// 32-bit point per stage) and let the user memorise the points.
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

  /// UI sound cues. The canvas plays the tap "click"; the selection-outcome
  /// cues (select / confirm / deny) are dispatched from [_onCanvasSelect],
  /// where the decode result is known.
  final SoundBoard _sounds = SoundBoard();

  /// Focus node for the canvas/hotkey handler, so we can return keyboard focus
  /// to it after the user has been typing in a text field.
  final FocusNode _hotkeys = FocusNode(debugLabel: 'setup-hotkeys');

  /// Per-stage **master-secret export label** (e.g. `SIGNING-1`). Appended to
  /// the Argon2id transcript message at the exporting stage, versioning the
  /// derived secret — DESIGN.md §"Master-Secret Export". Same restricted
  /// `[A-Z0-9-]` widget as Stage 0; shown on every non-0 stage in all modes. A
  /// single field applies to whichever stage is on screen when Copy is pressed.
  final TextEditingController _exportLabel = TextEditingController();

  /// True when the last edit to [_exportLabel] had characters up-cased or
  /// dropped by the engine's canonicalisation (mirrors [_stage0Restricted]).
  bool _exportLabelRestricted = false;

  void _onExportLabelRestricted({required bool adjusted}) {
    if (_exportLabelRestricted == adjusted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _exportLabelRestricted != adjusted) {
        setState(() => _exportLabelRestricted = adjusted);
      }
    });
  }

  /// An existing BIP39 phrase to import instead of generating a fresh root.
  /// Secret material: obscured by default, cleared once it has been encoded.
  final TextEditingController _mnemonic = TextEditingController();
  bool _mnemonicHidden = true;

  /// Stage 0 — the salt/pepper text that seeds the fractal chain. One field,
  /// one scheme: use it as a non-secret label ('MAIN-STASH') or a secret pepper
  /// (a blindly pasted high-entropy string) — the app treats it identically.
  /// Obscured by default with a reveal toggle; constrained to a safe ASCII
  /// subset (see [_SaltPepperFormatter]).
  final TextEditingController _stage0 = TextEditingController();
  bool _stage0Hidden = true;

  /// True when the last edit to [_stage0] had characters up-cased or dropped by
  /// the engine's canonicalisation. Surfaced as an inline red-flag so the
  /// restriction is never applied silently (DESIGN.md "Strong text
  /// restrictions": the divergence must be signalled to the user).
  bool _stage0Restricted = false;

  /// Called by [_SaltPepperFormatter] (during the edit pipeline) with whether
  /// the engine had to adjust the typed text. Defers the [setState] to a
  /// post-frame callback so it never runs mid-build, and fires even when the
  /// resolved text is unchanged (e.g. a lone disallowed char in an empty field,
  /// which would not trigger `onChanged`).
  void _onStage0Restricted({required bool adjusted}) {
    if (_stage0Restricted == adjusted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _stage0Restricted != adjusted) {
        setState(() => _stage0Restricted = adjusted);
      }
    });
  }

  HueOffset _hue = HueOffset.red;
  Argon2Profile _profile = Argon2Profile.basic;
  /// N — the per-stage **Argon2 iteration count**, entered as a free number.
  /// Essentially unbounded (0..∞): a deliberately heavy setup may take hours,
  /// days, or weeks to derive, so N is a numeric field rather than a capped
  /// slider. [_iterations] holds the last in-range value; [_iterationsValid]
  /// gates the action buttons while the field is empty or malformed.
  int _iterations = 1;
  final TextEditingController _iterationsField =
      TextEditingController(text: '1');
  bool get _iterationsValid {
    final int? n = int.tryParse(_iterationsField.text.trim());
    return n != null && n >= 0;
  }

  /// Number of fractal **point stages** for a fresh/recall setup, chosen on a
  /// discrete slider with nine positions, 0..[SetupController.maxPointStages].
  /// 0 is a Stage-0-text-only setup (no fractal points); each higher position
  /// adds one 32-bit fractal stage (`32 × count` bits / `3 × count` BIP39
  /// words). Every position is a valid setup, so the count needs no validity
  /// gate. (N is reserved for the Argon2 iteration count, below.)
  int _pointStages = 4;

  /// Configuration source: generate a fresh random seed, import an existing
  /// (possibly sub-standard) BIP39 phrase, or recall an existing setup from its
  /// salt (cold-start recall — no encode, the points come back from clicks).
  _SourceMode _source = _SourceMode.fresh;

  /// Select mode: when on, tapping the canvas decodes the point under the
  /// cursor instead of panning. Toggled by the panel button or the `S` key.
  bool _selectMode = false;

  /// True while a master-secret export's Argon2id pass is in flight, so a second
  /// tap on "Copy master secret" is ignored until it finishes.
  bool _exporting = false;

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
    _sounds.dispose();
    _iterationsField.dispose();
    _exportLabel.dispose();
    _mnemonic.dispose();
    _stage0.dispose();
    _hotkeys.dispose();
    super.dispose();
  }

  bool get _busy =>
      _setup.phase == SetupPhase.encoding ||
      _setup.phase == SetupPhase.deriving;

  /// Whether a setup session is live (stages exist to navigate / focus): not the
  /// initial config screen, an error, or a finished/wiped session.
  bool get _hasSession =>
      _setup.phase == SetupPhase.encoding ||
      _setup.phase == SetupPhase.deriving ||
      _setup.phase == SetupPhase.memorise ||
      _setup.phase == SetupPhase.recallComplete;

  @override
  Widget build(BuildContext context) {
    final bool hasResult = _setup.phase == SetupPhase.memorise;
    return Focus(
      focusNode: _hotkeys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        children: <Widget>[
          // Upper edge: a fixed, full-width bar of stage tabs (0..8). Always
          // present; unreachable tabs are greyed but stay in place. Tap or press
          // 0–8 to jump.
          _stageTabs(),
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  // Clicking anywhere on the canvas returns keyboard focus to the
                  // hotkey handler, so the shortcuts work again after the user
                  // has been typing in a text field (salt, seed phrase). Listener
                  // is passive — it does not interfere with the canvas's own
                  // pan/zoom/select.
                  child: Listener(
                    onPointerDown: (_) => _hotkeys.requestFocus(),
                    child: Stack(
                      children: <Widget>[
                        // Stage 0 has no fractal/point — show the salt/pepper
                        // panel.
                        Positioned.fill(
                          child:
                              _setup.isTextStage ? _textStagePanel() : _canvas(),
                        ),
                        if (_busy) Positioned.fill(child: _progressOverlay()),
                        if (_selectMode && !_setup.isTextStage)
                          const Positioned(
                            top: 12,
                            left: 12,
                            child: _Badge(
                                'Recall — click your point'),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 260, child: _controlPanel(hasResult)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The upper-edge stage tabs: a **fixed** bar of nine numbered tabs (0..8,
  /// the protocol ceiling) that always span the full width. Stage 0 is the
  /// salt/pepper text; 1..N-1 are the chain-derived fractals. The stage under
  /// focus is highlighted; tabs that are not currently reachable — outside this
  /// setup's stage count, not yet derived, or before any session — stay visible
  /// but greyed out and inert. Tapping a reachable tab focuses it (the same as
  /// pressing its number key).
  Widget _stageTabs() {
    const int maxTab = SetupController.maxPointStages; // 0..8 → nine fixed tabs
    final int current = _setup.displayStageIndex;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i <= maxTab; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _StageTab(
                      index: i,
                      selected: _hasSession && i == current,
                      available: _hasSession && _setup.isStageAvailable(i),
                      // Tappable only for a stage that belongs to the active
                      // setup; everything else is inert but still shown.
                      onTap: (_hasSession && i < _setup.nStages)
                          ? () => _selectStage(i)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // While a text field (salt, seed phrase, …) holds focus, let it consume the
    // keystroke — never fire canvas shortcuts like S / R.
    if (_textInputHasFocus) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _resetView();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      _sounds.play(UiSound.select);
      _setup.cycleStage();
      return KeyEventResult.handled;
    }
    // K — derive and copy the exported master secret ("the key") for the stage
    // under focus.
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      if (!_busy) _copyMasterSecret();
      return KeyEventResult.handled;
    }
    // 0–8 — select that stage: focus it, or derive it if it is next.
    final int? digit = _digitKeys[event.logicalKey];
    if (digit != null) {
      _selectStage(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Select stage [index]: focus it if it is already available (Stage 0, or a
  /// fractal already derived), or — if it is the first not-yet-derived stage —
  /// trigger that stage's derivation. Anything else (out of range, or a gap
  /// beyond the next stage) sounds a deny cue and explains why.
  void _selectStage(int index) {
    if (_busy || !_hasSession) {
      _sounds.play(UiSound.deny);
      return;
    }
    if (index == _setup.displayStageIndex) return; // already here — no-op
    if (index < 0 || index >= _setup.nStages) {
      _sounds.play(UiSound.deny);
      _toast('This setup has ${_setup.nStages - 1} stage'
          '${_setup.nStages - 1 == 1 ? '' : 's'} (0–${_setup.nStages - 1}).');
      return;
    }
    // Already derived (or the Stage-0 text) — just focus it.
    if (_setup.isStageAvailable(index)) {
      _sounds.play(UiSound.select);
      _setup.showStage(index);
      return;
    }
    // Not derived yet because generation is still running in the background —
    // it will open on its own when ready.
    if (_setup.isGenerating) {
      _sounds.play(UiSound.deny);
      _toast('Stage $index is still deriving — it will open when ready.');
      return;
    }
    // Not derived. Only the very next stage can be derived, and only once the
    // previous stage carries a selected point.
    if (index != _setup.firstUnderivedStage) {
      _sounds.play(UiSound.deny);
      _toast('Recall the earlier stages first.');
      return;
    }
    if (!_setup.hasSelectedPoint(index - 1)) {
      _sounds.play(UiSound.deny);
      _toast('Select your point on Stage ${index - 1} first.');
      return;
    }
    _deriveNextStage();
  }

  /// Derive the next stage's fractal (the explicit chain-advance step). Shows the
  /// progress overlay while the Argon2 pass runs, then lands on the new fractal.
  Future<void> _deriveNextStage() async {
    final DeriveOutcome outcome = await _setup.deriveNextStage(
      argon2Iterations: _iterations,
      profile: _profile,
    );
    if (!mounted) return;
    switch (outcome) {
      case DeriveOutcome.derived:
        _sounds.play(UiSound.select);
        _toast('Stage ${_setup.displayStageIndex}/${_setup.nStages - 1} '
            'derived — recall your point.');
      case DeriveOutcome.noPriorPoint:
        _sounds.play(UiSound.deny);
        _toast('Select your point on the previous stage first.');
      case DeriveOutcome.none:
      case DeriveOutcome.busy:
        break;
    }
  }

  /// Whether the keyboard focus is currently inside an editable text field, so
  /// typed characters must not be interpreted as canvas shortcuts. Checks the
  /// active focus rather than specific fields, so any future input is covered.
  bool get _textInputHasFocus {
    final BuildContext? c = FocusManager.instance.primaryFocus?.context;
    if (c == null) return false;
    if (c.widget is EditableText) return true;
    return c.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Recenter the canvas: restore the default position and zoom and the default
  /// brightness offset, without touching the session or the encoded points.
  /// Bound to `R` — a quick "I'm lost, take me home" after panning/zooming far.
  void _resetView() {
    _sounds.play(UiSound.click);
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  /// Toggle select (recall) mode. Entering it snaps the canvas to the stage the
  /// recall walk is on, so clicks land on the right fractal in chain order.
  /// Snap the canvas to the recall stage and turn on point selection. Select
  /// mode is implicit in a cold-start recall (the points are hidden, so clicking
  /// is how the seed comes back); a generated/imported setup shows its points,
  /// so there is nothing to "practise" and the mode is never offered as a
  /// toggle.
  void _enterRecallSelect() {
    setState(() => _selectMode = true);
    _setup.showRecallStage();
  }

  Widget _canvas() {
    final Stage stage = _setup.displayStage;
    return FractalCanvas(
      source: widget.core.source,
      controller: _viewport,
      palette: Palette.classicWithHue(_hue),
      brightness: _brightness,
      sounds: _sounds,
      stage: stage,
      stageParameters:
          stage == Stage.stage2 ? _setup.displayStageParams : null,
      maxIterations: EncodingConstants.renderMaxIter,
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

  /// The left-pane panel shown for Stage 0 (the salt/pepper text): there is no
  /// fractal and no point to select here. Shows the text the chain was seeded
  /// with, behind a reveal toggle (it may be a secret pepper).
  Widget _textStagePanel() {
    final String text = _setup.saltPepper;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.password, size: 48),
              const SizedBox(height: 16),
              Text('Stage 0 — salt / pepper',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'This text seeds every fractal in your chain — there is no '
                'shared "canonical" fractal, and no point to select here. '
                'You chose whether it is a public label or a secret pepper.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (text.isEmpty)
                Text('(no salt / pepper set)',
                    style: Theme.of(context).textTheme.bodySmall)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SelectableText(
                      _stage0Hidden ? '•' * text.length : text,
                      style: const TextStyle(
                        fontFamily: GreatWallTypography.fontFamily,
                        fontFamilyFallback: <String>['monospace'],
                        fontSize: 18,
                        letterSpacing: 1.5,
                      ),
                    ),
                    IconButton(
                      tooltip: _stage0Hidden ? 'Reveal' : 'Hide',
                      icon: Icon(_stage0Hidden
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () =>
                          setState(() => _stage0Hidden = !_stage0Hidden),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onCanvasSelect(FractalSelection sel) async {
    SelectionOutcome outcome = _setup.selectPoint(sel);
    // A valid click that would clobber a re-selected stage's later fractals asks
    // for confirmation before discarding them.
    if (outcome == SelectionOutcome.needsConfirm) {
      final bool ok = await _confirmReselect();
      if (!mounted || !ok) return;
      outcome = _setup.selectPoint(sel, confirmedReselect: true);
      if (!mounted) return;
    }
    final String? msg;
    switch (outcome) {
      case SelectionOutcome.invalid:
        _sounds.play(UiSound.deny);
        msg = 'No encodable leaf there — zoom in and click closer.';
      case SelectionOutcome.marked:
        _sounds.play(UiSound.select);
        final int k = _setup.displayStageIndex;
        msg = k < _setup.nStages - 1
            ? 'Point marked on Stage $k/${_setup.nStages - 1} — '
                'select Stage ${k + 1} to derive it.'
            : 'Point marked on Stage $k/${_setup.nStages - 1}.';
      case SelectionOutcome.complete:
        _sounds.play(UiSound.confirm);
        msg = 'Recall complete — seed reconstructed.';
      case SelectionOutcome.needsConfirm:
      case SelectionOutcome.busy:
        msg = null;
    }
    if (msg == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 1100), content: Text(msg)),
    );
  }

  /// Confirm a point re-selection that will discard the later fractals already
  /// derived from this stage. Returns true if the user chooses to proceed.
  Future<bool> _confirmReselect() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Re-derive later stages?'),
        content: const Text(
          'This stage already has a selected point, and later stages were '
          'derived from it. Choosing a new point here discards those later '
          'stages — you will re-derive and re-select them.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard & re-select'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Widget _progressOverlay() {
    final String stageLabel =
        'Stage ${_setup.workingStageNumber}/${_setup.nStages - 1}';
    final String label;
    switch (_setup.phase) {
      case SetupPhase.deriving:
        label = 'Deriving $stageLabel fractal (Argon2) '
            '${_setup.argon2Done}/${_setup.argon2Total}…';
      case SetupPhase.encoding:
        label = 'Encoding $stageLabel point…';
      default:
        label = 'Working…';
    }
    final bool deriving = _setup.phase == SetupPhase.deriving;
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
          else if (_setup.isRecallSession && hasResult)
            ..._recallControls()
          else if (!hasResult)
            ..._configControls()
          else
            ..._memoriseControls(),

          // Stage navigation — available as soon as stages are loaded, in any
          // mode (generation, import, recall): toggle between loaded stages and
          // study each under the canvas (zoom / pan / brightness). Stages not
          // yet reached during a recall walk stay disabled until recalled.
          if ((hasResult || _setup.phase == SetupPhase.recallComplete) &&
              _setup.nStages > 1) ...<Widget>[
            const Divider(height: 32),
            _stageNav(),
          ],

          // Background generation progress: later stages are still deriving
          // while the user studies the ones already done.
          if (_setup.isGenerating || _setup.generationError != null) ...<Widget>[
            const Divider(height: 32),
            _generationNotice(),
          ],

          // The cold-start recall walk shows a per-stage hint while the user
          // clicks their points back. There is no select-mode toggle: a recall
          // session selects implicitly (the answer is hidden), and a
          // generated/imported setup displays its points, so there is nothing to
          // practise.
          if (_selectMode &&
              !_setup.isTextStage &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            Text(
              'Recalling Stage ${_setup.displayStageIndex}/'
              '${_setup.nStages - 1} — click your point to mark it, then select '
              'the next stage (tab or number key) to derive it.',
            ),
          ],

          // Master-secret export — offered at every non-0 stage in every mode
          // (generation, import, recall) the moment the stage is resolved, not
          // only at the end. Exports exactly the prefix fixed so far.
          if (_setup.canExportMasterAt(_setup.displayStageIndex) &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            ..._masterExportControls(),
          ],

          // Blind BIP39 export of the seed recalled so far — recall only (it
          // needs the decoded points). Available at every recall stage once a
          // point is back; before the final stage it is a partial,
          // shorter-than-standard seed.
          if (_setup.canExport &&
              _setup.phase != SetupPhase.recallComplete) ...<Widget>[
            const Divider(height: 32),
            Text(
              'Blind copy — partial seed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${_setup.recalledStageCount}/${_setup.nStages - 1} points '
              'recalled (${_setup.recalledBitCount} bits). Until the final '
              'stage this is a non-standard, shorter — therefore weaker — seed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _bip39CopyButton(),
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
              onChanged: (HueOffset h) {
                _sounds.play(UiSound.click);
                setState(() => _hue = h);
              },
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Hold L and scroll over the canvas to adjust brightness; '
            'scroll to zoom, drag to pan; press R to recenter, T to cycle '
            'stages, 0–8 to jump to a stage, K to copy the key.',
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
      const Text('Source'),
      const SizedBox(height: 4),
      SegmentedButton<_SourceMode>(
        segments: const <ButtonSegment<_SourceMode>>[
          ButtonSegment<_SourceMode>(
              value: _SourceMode.fresh, label: Text('New seed')),
          ButtonSegment<_SourceMode>(
              value: _SourceMode.import, label: Text('Import')),
          ButtonSegment<_SourceMode>(
              value: _SourceMode.recall, label: Text('Recall')),
        ],
        selected: <_SourceMode>{_source},
        onSelectionChanged: _busy
            ? null
            : (Set<_SourceMode> s) {
                _sounds.play(UiSound.click);
                setState(() => _source = s.first);
              },
      ),
      const SizedBox(height: 16),
      if (_source == _SourceMode.import)
        ..._mnemonicInput()
      else ...<Widget>[
        if (_source == _SourceMode.recall) ...<Widget>[
          Text(
            'Recall an existing setup: enter the same salt, number of stages and '
            'Argon2 settings you used, then click your memorised point on each '
            'stage. Nothing is encoded — the seed is rebuilt from your clicks.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
        ],
        ..._stagesInput(),
      ],
      const SizedBox(height: 16),
      ..._stage0Input(),
      const SizedBox(height: 16),
      _argon2ProfileSlider(),
      const SizedBox(height: 16),
      ..._iterationsInput(),
      const SizedBox(height: 16),
      if (_source == _SourceMode.recall)
        FilledButton(
          onPressed: (_busy || !_iterationsValid) ? null : _beginRecall,
          child: const Text('Begin recall'),
        )
      else
        FilledButton(
          onPressed: (_busy ||
                  !_iterationsValid ||
                  (_source == _SourceMode.import &&
                      _mnemonic.text.trim().isEmpty))
              ? null
              : _start,
          child: Text(
              _source == _SourceMode.import ? 'Encode phrase' : 'Generate'),
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

  /// Discrete slider for the number of fractal **point stages**, with nine
  /// positions `0..maxPointStages` (0..8). `divisions` snaps to whole stages so
  /// there is no ambiguous in-between value. 0 is a Stage-0-text-only setup; each
  /// higher position adds one 32-bit fractal stage (`32 × count` bits / `3 ×
  /// count` BIP39 words). Every position is valid, so — unlike the old free-text
  /// field — there is nothing to flag and the action button stays enabled across
  /// the range. (N denotes the Argon2 iteration count, set separately.)
  List<Widget> _stagesInput() {
    final int n = _pointStages;
    final int maxN = SetupController.maxPointStages;
    final String summary = n == 0
        ? 'Stage-0 text only — no fractal points.'
        : '$n fractal stage${n == 1 ? '' : 's'} — ${n * 32} bits, '
            '${n * 3} BIP39 words.';
    return <Widget>[
      Text('Number of stages: $n'),
      Slider(
        value: n.toDouble(),
        min: 0,
        max: maxN.toDouble(),
        divisions: maxN,
        label: '$n',
        onChanged: _busy
            ? null
            : (double v) {
                final int next = v.round();
                if (next == _pointStages) return;
                _sounds.play(UiSound.click);
                setState(() => _pointStages = next);
              },
      ),
      Text(summary, style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  /// Free numeric input for **N**, the per-stage Argon2 iteration count. The
  /// range is essentially 0..∞ — a deliberately heavy setup may take hours,
  /// days, or weeks to derive — so there is no upper cap, only a digit limit
  /// guarding the int parse. Larger N ⇒ proportionally longer derivation. (The
  /// time a given N takes drifts with hardware; N itself is exact and
  /// reproducible — see docs §"time is a perishable label on a durable
  /// parameter".)
  List<Widget> _iterationsInput() {
    final String raw = _iterationsField.text.trim();
    final bool invalid = raw.isNotEmpty && !_iterationsValid;
    return <Widget>[
      const Text('Argon2 iterations (N)'),
      const SizedBox(height: 4),
      TextField(
        controller: _iterationsField,
        enabled: !_busy,
        maxLines: 1,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(12),
        ],
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          hintText: 'e.g. 1',
          helperText: 'Per-stage Argon2 passes — no upper limit; a high N can '
              'take hours, days, even weeks to derive.',
          helperMaxLines: 2,
          errorText: invalid ? 'Enter a whole number (0 or more).' : null,
        ),
        onChanged: (_) {
          _sounds.play(UiSound.click);
          final int? v = int.tryParse(_iterationsField.text.trim());
          if (v != null && v >= 0) _iterations = v;
          setState(() {});
        },
      ),
    ];
  }

  /// The three Argon2 memory profiles in ascending cost, paired with their
  /// slider labels (`Argon2Profile` order == ascending GiB).
  static const List<Argon2Profile> _profiles = <Argon2Profile>[
    Argon2Profile.basic,
    Argon2Profile.advanced,
    Argon2Profile.greatWall,
  ];
  static const List<String> _profileLabels = <String>[
    'Basic — 1 GiB',
    'Advanced — 32 GiB',
    'Great Wall — 128 GiB',
  ];

  /// The Argon2 memory profile, chosen on a three-stop slider rather than a
  /// dropdown so the memory cost reads as one escalating axis next to the
  /// iteration-count (N) field.
  Widget _argon2ProfileSlider() {
    final int idx = _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Argon2 profile: ${_profileLabels[idx]}'),
        Slider(
          value: idx.toDouble(),
          min: 0,
          max: (_profiles.length - 1).toDouble(),
          divisions: _profiles.length - 1,
          label: _profileLabels[idx],
          onChanged: _busy
              ? null
              : (double v) {
                  final Argon2Profile next = _profiles[v.round()];
                  if (next == _profile) return;
                  _sounds.play(UiSound.click);
                  setState(() => _profile = next);
                },
        ),
      ],
    );
  }

  /// The obscured BIP39 import field plus a live word-count hint. The phrase is
  /// secret, so the field is blind (asterisks) by default with an eye toggle;
  /// it is never echoed back anywhere else.
  List<Widget> _mnemonicInput() {
    final int words = _mnemonic.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((String w) => w.isNotEmpty)
        .length;
    final bool standard = <int>{12, 15, 18, 21, 24}.contains(words);
    final String hint;
    if (words == 0) {
      hint = 'Type or paste your seed phrase.';
    } else if (words % 3 != 0 || words > 24) {
      hint = '$words words — must be a multiple of 3 (3–24).';
    } else {
      hint = '$words words → ${words ~/ 3} stages'
          '${standard ? "" : " (sub-standard length)"}.';
    }
    return <Widget>[
      const Text('Seed phrase (BIP39)'),
      const SizedBox(height: 4),
      TextField(
        controller: _mnemonic,
        obscureText: _mnemonicHidden,
        enabled: !_busy,
        maxLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          hintText: 'word1 word2 …',
          helperText: hint,
          helperMaxLines: 2,
          suffixIcon: IconButton(
            tooltip: _mnemonicHidden ? 'Show phrase' : 'Hide phrase',
            icon: Icon(
              _mnemonicHidden ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () =>
                setState(() => _mnemonicHidden = !_mnemonicHidden),
          ),
        ),
        onChanged: (_) {
          _sounds.play(UiSound.click);
          setState(() {});
        },
      ),
    ];
  }

  /// The Stage-0 salt/pepper field: obscured by default with a reveal toggle,
  /// constrained to a safe ASCII subset (uppercase letters, digits, hyphen).
  /// One field, one scheme — the user decides whether it is a public label or a
  /// secret pepper. The restriction (and why it exists) is explained inline.
  List<Widget> _stage0Input() {
    return <Widget>[
      const Text('Stage 0 — salt / pepper'),
      const SizedBox(height: 4),
      TextField(
        controller: _stage0,
        obscureText: _stage0Hidden,
        enabled: !_busy,
        maxLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: <TextInputFormatter>[
          _SaltPepperFormatter(widget.core, _onStage0Restricted),
        ],
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          hintText: 'e.g. MAIN-STASH',
          helperText: 'Seeds your fractals. A label (MAIN-STASH) or a pasted '
              'secret pepper — your call. Uppercase letters, digits and '
              'hyphens only (kept unambiguous so it is reproducible).',
          helperMaxLines: 3,
          suffixIcon: IconButton(
            tooltip: _stage0Hidden ? 'Show text' : 'Hide text',
            icon: Icon(
              _stage0Hidden ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () => setState(() => _stage0Hidden = !_stage0Hidden),
          ),
        ),
        style: const TextStyle(
          fontFamily: GreatWallTypography.fontFamily,
          fontFamilyFallback: <String>['monospace'],
        ),
        onChanged: (_) {
          _sounds.play(UiSound.click);
          setState(() {});
        },
      ),
      if (_stage0Restricted)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Adjusted to A–Z, 0–9 and "-" so it stays reproducible.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// Controls shown during a cold-start recall walk (select mode on). The
  /// select-mode switch, the per-stage recall hint, the blind-copy export and
  /// Reset all live in the always-shown section below.
  List<Widget> _recallControls() {
    return <Widget>[
      const Text('Recall your points'),
      const SizedBox(height: 8),
      Text(
        'Select mode is on. Click your memorised point to mark it, then select '
        'the next stage (its tab or number key) to derive that fractal (the '
        'same Argon2 cost as setup). Nothing is shown — the seed is rebuilt only '
        'from your clicks.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  List<Widget> _memoriseControls() {
    return <Widget>[
      const Text('Memorise your points'),
      const SizedBox(height: 16),
      // Stage 0 is the salt/pepper text (no point); stages 1..N-1 are the
      // chain-derived fractals, one point each. Step through with the stage
      // navigator below (or the arrows / T).
      Text(
        'Stage 0 is the salt/pepper you entered; each later stage is its own '
        'fractal carrying one point. Study the marked location on every fractal '
        'until you can find it from memory. When confident, finish — the seed '
        'is then held only in your recall.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () {
          _sounds.play(UiSound.confirm);
          _setup.finish();
        },
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
        'Every stage was selected back and the seed was reconstructed from '
        'your points. It is never shown on screen — the buttons below copy it '
        'straight to the clipboard so you can paste it blind into another '
        "wallet's import wizard and continue without ever reading it.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      _bip39CopyButton(),
      const SizedBox(height: 24),
      ..._masterExportControls(),
      const SizedBox(height: 24),
      FilledButton(onPressed: _reset, child: const Text('Done')),
    ];
  }

  /// Step between stages of the active session. The left arrow focuses the
  /// previous (always-loaded) stage; the right arrow focuses the next stage if
  /// it is derived, or — when it is the first not-yet-derived stage — triggers
  /// its derivation (the same as selecting it by tab or number key). Disabled at
  /// the ends or while a derivation is running.
  Widget _stageNav() {
    final int idx = _setup.displayStageIndex;
    final int n = _setup.nStages;
    final bool canPrev = idx > 0;
    final bool canNext = !_busy &&
        idx + 1 < n &&
        (_setup.isStageAvailable(idx + 1) ||
            // Only a recall walk derives the next stage on demand; during
            // background generation the next stage arrives on its own.
            (_setup.isRecallSession &&
                idx + 1 == _setup.firstUnderivedStage));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        IconButton(
          tooltip: 'Previous stage',
          onPressed: canPrev ? () => _selectStage(idx - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(idx == 0 ? 'Stage 0 — salt / pepper' : 'Stage $idx / ${n - 1}'),
        IconButton(
          tooltip: 'Next stage',
          onPressed: canNext ? () => _selectStage(idx + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  /// A subtle, non-blocking notice while later stages derive in the background
  /// (or a one-line warning if a background derivation failed). The stages
  /// already derived are fully navigable meanwhile; focus stays put.
  Widget _generationNotice() {
    final String? err = _setup.generationError;
    if (err != null) {
      return Text(err, style: const TextStyle(color: Colors.orangeAccent));
    }
    final int total = _setup.nStages - 1;
    final double? progress =
        _setup.argon2Total > 0 ? _setup.argon2Done / _setup.argon2Total : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Deriving stage ${_setup.generatingStage}/$total in the background — '
          'the stages already done are ready to study now.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: progress),
      ],
    );
  }

  /// The blind BIP39 seed-phrase copy. Operates on whatever has been recalled so
  /// far via [SetupController.exportMnemonic]; shown only where a decoded seed
  /// exists (the recall partial export and the recall-complete panel).
  Widget _bip39CopyButton() {
    return OutlinedButton.icon(
      onPressed: _copyMnemonic,
      icon: const Icon(Icons.content_copy),
      label: const Text('Copy seed phrase (BIP39)'),
    );
  }

  /// The master-secret export affordances for the **currently displayed** stage:
  /// an explanation, the optional per-stage export-label field (restricted
  /// `[A-Z0-9-]`, versioning the key), and the blind copy. The Argon2id pass
  /// covers stages `1..displayStageIndex` (DESIGN.md §"Master-Secret Export").
  List<Widget> _masterExportControls() {
    final int idx = _setup.displayStageIndex;
    return <Widget>[
      Text(
        'Key (master-secret export)',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 4),
      Text(
        'Argon2id over your setup so far (stages 1–$idx). Paste this key into '
        'another wallet, derive a non-BIP39 secret, or use it as a downstream '
        'pepper. The optional label versions the key (e.g. SIGNING-1) and is '
        'mixed into the hash. Press K to derive and copy; copied blind — never '
        'shown on screen.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _exportLabel,
        enabled: !_busy,
        maxLines: 1,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: <TextInputFormatter>[
          _SaltPepperFormatter(widget.core, _onExportLabelRestricted),
        ],
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          labelText: 'Export label (optional)',
          hintText: 'e.g. SIGNING-1',
          helperText: 'Uppercase letters, digits and hyphens; any length.',
          helperMaxLines: 2,
        ),
        style: const TextStyle(
          fontFamily: GreatWallTypography.fontFamily,
          fontFamilyFallback: <String>['monospace'],
        ),
        onChanged: (_) {
          _sounds.play(UiSound.click);
          setState(() {});
        },
      ),
      if (_exportLabelRestricted)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Adjusted to A–Z, 0–9 and "-" so it stays reproducible.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: (_busy || _exporting) ? null : _copyMasterSecret,
        icon: _exporting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.content_copy),
        label: Text(_exporting ? 'Deriving…' : 'Copy key (K)'),
      ),
    ];
  }

  Future<void> _copyMnemonic() async {
    final String? mnemonic = _setup.exportMnemonic();
    if (mnemonic == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    await Clipboard.setData(ClipboardData(text: mnemonic));
    if (!mounted) return;
    _sounds.play(UiSound.confirm);
    // Confirmation never echoes the secret itself.
    _toast('Seed phrase copied — paste it into your wallet, then clear the '
        'clipboard.');
  }

  Future<void> _copyMasterSecret() async {
    if (_exporting) return;
    final int idx = _setup.displayStageIndex;
    setState(() => _exporting = true);
    // The Argon2id pass runs off the UI isolate, so this awaits; the finally
    // clears the in-flight flag even if it fails, and we re-check `mounted`
    // after the await before touching the clipboard or UI.
    String? secret;
    try {
      secret = await _setup.exportMasterSecret(
        stageIndex: idx,
        label: _exportLabel.text,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (!mounted) return;
    if (secret == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    _sounds.play(UiSound.confirm);
    // Confirmation never echoes the secret itself.
    _toast('Key copied — paste it, then clear the clipboard.');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 1400), content: Text(msg)),
    );
  }

  Future<void> _start() async {
    _sounds.play(UiSound.click);
    _brightness.reset();
    setState(() => _selectMode = false);
    final String text = _stage0.text;
    if (_source == _SourceMode.import) {
      await _setup.beginFromMnemonic(
        _mnemonic.text,
        text: text,
        argon2Iterations: _iterations,
        profile: _profile,
      );
      // Setup is write-only on memory: once the phrase is encoded onto the
      // fractals, wipe the plaintext from the field (keep it on error so the
      // user can fix it).
      if (_setup.phase != SetupPhase.error) _mnemonic.clear();
    } else {
      final int n = _pointStages;
      await _setup.begin(
        pointStages: n,
        text: text,
        argon2Iterations: _iterations,
        profile: _profile,
      );
    }
    // The salt/pepper now lives in the chain; clear the input field on success
    // (the controller keeps its own copy for the in-session recall).
    if (_setup.phase != SetupPhase.error) _stage0.clear();
    if (mounted) {
      _sounds.play(
        _setup.phase == SetupPhase.error ? UiSound.deny : UiSound.confirm,
      );
    }
  }

  /// Start a cold-start recall from the entered salt: derive Stage 1, then drop
  /// straight into select mode so the user can click their first point.
  Future<void> _beginRecall() async {
    final int n = _pointStages;
    _sounds.play(UiSound.click);
    _brightness.reset();
    await _setup.beginRecall(
      pointStages: n,
      text: _stage0.text,
      argon2Iterations: _iterations,
      profile: _profile,
    );
    if (!mounted) return;
    if (_setup.phase == SetupPhase.error) {
      _sounds.play(UiSound.deny);
      return;
    }
    // The salt now lives in the controller for the in-session walk; clear the
    // field so it is not left on screen.
    _stage0.clear();
    _enterRecallSelect();
    _sounds.play(UiSound.confirm);
  }

  void _reset() {
    _sounds.play(UiSound.click);
    _setup.reset();
    _brightness.reset();
    _viewport.viewport = _initialViewport;
    _mnemonic.clear();
    _stage0.clear();
    _exportLabel.clear();
    setState(() {
      _selectMode = false;
      _stage0Hidden = true;
      _exportLabelRestricted = false;
    });
  }
}

/// Where the Setup session's root comes from: a freshly generated seed, an
/// imported BIP39 phrase, or a cold-start recall of an existing setup (derive
/// from the salt and reconstruct the seed from the user's clicks).
enum _SourceMode { fresh, import, recall }

/// Maps the number-row and numpad digit keys 0..8 to a stage index, so pressing
/// a number focuses that stage (when no text field holds the keystroke). 9 is
/// included so it produces the usual out-of-range cue rather than nothing.
///
/// Not `const`: [LogicalKeyboardKey] has no primitive `==`, so it cannot be a
/// constant map key — a lazily-initialised `final` map is the idiomatic form.
final Map<LogicalKeyboardKey, int> _digitKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
  LogicalKeyboardKey.digit6: 6,
  LogicalKeyboardKey.digit7: 7,
  LogicalKeyboardKey.digit8: 8,
  LogicalKeyboardKey.digit9: 9,
  LogicalKeyboardKey.numpad0: 0,
  LogicalKeyboardKey.numpad1: 1,
  LogicalKeyboardKey.numpad2: 2,
  LogicalKeyboardKey.numpad3: 3,
  LogicalKeyboardKey.numpad4: 4,
  LogicalKeyboardKey.numpad5: 5,
  LogicalKeyboardKey.numpad6: 6,
  LogicalKeyboardKey.numpad7: 7,
  LogicalKeyboardKey.numpad8: 8,
  LogicalKeyboardKey.numpad9: 9,
};

/// One numbered stage tab on the upper edge. Highlighted when it is the stage
/// under focus, dimmed and non-interactive when not yet reachable.
class _StageTab extends StatelessWidget {
  const _StageTab({
    required this.index,
    required this.selected,
    required this.available,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final bool available;

  /// `null` when the tab is not reachable (outside the setup, or before a
  /// session): the tab stays visible but greyed out and non-interactive.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color fg = selected
        ? scheme.onPrimary
        : available
            ? scheme.onSurface
            : scheme.onSurface.withOpacity(0.35);
    final Color bg = selected ? scheme.primary : Colors.transparent;
    return Tooltip(
      message: index == 0 ? 'Stage 0 — salt / pepper' : 'Stage $index',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Text(
            '$index',
            style: TextStyle(
              color: fg,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontFamily: GreatWallTypography.fontFamily,
              fontFamilyFallback: const <String>['monospace'],
            ),
          ),
        ),
      ),
    );
  }
}

/// Constrains the Stage-0 salt/pepper to a safe, reproducible ASCII subset:
/// uppercase letters, digits and hyphens. Lowercase is upper-cased; anything
/// else (spaces, underscores, punctuation, non-ASCII) is dropped as typed.
///
/// Rather than reimplement the rule, this delegates to the shared engine
/// ([GreatWallCore.canonicalizeSaltPepper], backed by
/// `bs_salt_pepper_canonicalize`) — the *same* canonicalisation that builds the
/// chain seed, so the field shows exactly the bytes that will be hashed. The
/// `[A-Z0-9-]` restriction (DESIGN.md "Strong text restrictions") exists so the
/// text reproduces identically across devices; a stray case/accent/look-alike
/// would silently fork the chain into an unrecoverable result.
///
/// [onResult] is called with whether the engine had to adjust the text, so the
/// field can flag the user — the divergence is never silent.
class _SaltPepperFormatter extends TextInputFormatter {
  _SaltPepperFormatter(this._core, this._onResult);

  final GreatWallCore _core;
  final void Function({required bool adjusted}) _onResult;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String canonical = _core.canonicalizeSaltPepper(newValue.text);
    if (canonical == newValue.text) {
      _onResult(adjusted: false);
      return newValue;
    }
    _onResult(adjusted: true);
    return TextEditingValue(
      text: canonical,
      selection: TextSelection.collapsed(offset: canonical.length),
    );
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
