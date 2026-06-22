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

  /// Focus node for the canvas/hotkey handler, so we can return keyboard focus
  /// to it after the user has been typing in a text field.
  final FocusNode _hotkeys = FocusNode(debugLabel: 'setup-hotkeys');

  /// Descriptive salt for the SHA-512 export at recall (e.g. "main wallet").
  /// Domain-separates one setup from another — see ARCHITECTURE.md §"Stage 0".
  final TextEditingController _salt = TextEditingController();

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
  SizePreset _preset = SizePreset.defaultPreset;
  Argon2Profile _profile = Argon2Profile.basic;
  int _iterations = 1;

  /// Configuration source: generate a fresh random seed, or import an existing
  /// (possibly sub-standard) BIP39 phrase and encode it onto the fractals.
  bool _importMode = false;

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
    _salt.dispose();
    _mnemonic.dispose();
    _stage0.dispose();
    _hotkeys.dispose();
    super.dispose();
  }

  bool get _busy =>
      _setup.phase == SetupPhase.encoding ||
      _setup.phase == SetupPhase.deriving;

  @override
  Widget build(BuildContext context) {
    final bool hasResult = _setup.phase == SetupPhase.memorise;
    return Focus(
      focusNode: _hotkeys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Row(
        children: <Widget>[
          Expanded(
            // Clicking anywhere on the canvas returns keyboard focus to the
            // hotkey handler, so S / R work again after the user has been
            // typing in a text field (salt, seed phrase). Listener is passive,
            // so it does not interfere with the canvas's own pan/zoom/select.
            child: Listener(
              onPointerDown: (_) => _hotkeys.requestFocus(),
              child: Stack(
                children: <Widget>[
                  // Stage 0 has no fractal/point — show the salt/pepper panel.
                  Positioned.fill(
                    child: _setup.isTextStage ? _textStagePanel() : _canvas(),
                  ),
                  if (_busy) Positioned.fill(child: _progressOverlay()),
                  if (_selectMode && !_setup.isTextStage)
                    const Positioned(
                      top: 12,
                      left: 12,
                      child: _Badge('Select mode — click a point (S to exit)'),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(width: 260, child: _controlPanel(hasResult)),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // While a text field (salt, seed phrase, …) holds focus, let it consume the
    // keystroke — never fire canvas shortcuts like S / R.
    if (_textInputHasFocus) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      _setSelectMode(!_selectMode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _resetView();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      _setup.cycleStage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  /// Toggle select (recall) mode. Entering it snaps the canvas to the stage the
  /// recall walk is on, so clicks land on the right fractal in chain order.
  void _setSelectMode(bool v) {
    setState(() => _selectMode = v);
    if (v) _setup.showRecallStage();
  }

  Widget _canvas() {
    final Stage stage = _setup.displayStage;
    return FractalCanvas(
      source: widget.core.source,
      controller: _viewport,
      palette: Palette.classicWithHue(_hue),
      brightness: _brightness,
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
      case SelectionOutcome.advancedStage:
        msg = 'Recalled — now on Stage '
            '${_setup.displayStageIndex}/${_setup.nStages - 1}.';
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
          else if (!hasResult)
            ..._configControls()
          else
            ..._memoriseControls(),

          const Divider(height: 32),
          // Always available: entering select mode snaps to the next fractal to
          // recall (Stage 0 is text, not selectable), and Reset returns to the
          // configuration screen without restarting the app.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Select mode'),
            subtitle: const Text('Click your points to recall (or press S)'),
            value: _selectMode,
            onChanged: _setSelectMode,
          ),
          if (_selectMode &&
              !_setup.isTextStage &&
              _setup.phase != SetupPhase.recallComplete)
            Text(
              'Recalling Stage ${_setup.displayStageIndex}/'
              '${_setup.nStages - 1} — click your one point to advance the '
              'chain.',
            ),

          // Blind export of the seed recalled so far — available at every stage
          // once a point has been recalled, not only at the end. Before the
          // final stage it is a partial, shorter-than-standard seed.
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
            ..._exportControls(),
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
            'scroll to zoom, drag to pan; press R to recenter, T to cycle '
            'stages, S to select.',
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
      SegmentedButton<bool>(
        segments: const <ButtonSegment<bool>>[
          ButtonSegment<bool>(value: false, label: Text('New seed')),
          ButtonSegment<bool>(value: true, label: Text('Import')),
        ],
        selected: <bool>{_importMode},
        onSelectionChanged: _busy
            ? null
            : (Set<bool> s) => setState(() => _importMode = s.first),
      ),
      const SizedBox(height: 16),
      if (!_importMode) ...<Widget>[
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
      ] else
        ..._mnemonicInput(),
      const SizedBox(height: 16),
      ..._stage0Input(),
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
        onPressed: (_busy || (_importMode && _mnemonic.text.trim().isEmpty))
            ? null
            : _start,
        child: Text(_importMode ? 'Encode phrase' : 'Generate'),
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
        onChanged: (_) => setState(() {}),
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
        onChanged: (_) => setState(() {}),
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

  List<Widget> _memoriseControls() {
    final int idx = _setup.displayStageIndex;
    final int n = _setup.nStages;
    return <Widget>[
      const Text('Memorise your points'),
      const SizedBox(height: 8),
      // Stage 0 is the salt/pepper text (no point); stages 1..N-1 are the
      // chain-derived fractals, one point each. Step through with the arrows / T.
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          IconButton(
            tooltip: 'Previous stage',
            onPressed: idx > 0 ? () => _setup.showStage(idx - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(idx == 0
              ? 'Stage 0 — salt / pepper'
              : 'Stage $idx / ${n - 1}'),
          IconButton(
            tooltip: 'Next stage',
            onPressed: idx < n - 1 ? () => _setup.showStage(idx + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text(
        'Stage 0 is the salt/pepper you entered; each later stage is its own '
        'fractal carrying one point. Study the marked location on every fractal '
        'until you can find it from memory. When confident, finish — the seed '
        'is then held only in your recall.',
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
        'Every stage was selected back and the seed was reconstructed from '
        'your points. It is never shown on screen — the buttons below copy it '
        'straight to the clipboard so you can paste it blind into another '
        "wallet's import wizard and continue without ever reading it.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      ..._exportControls(),
      const SizedBox(height: 24),
      FilledButton(onPressed: _reset, child: const Text('Done')),
    ];
  }

  /// The blind-copy affordances (BIP39 phrase + SHA-512(seed + salt)). Shared by
  /// the per-stage partial export and the recall-complete panel; both operate on
  /// whatever has been recalled so far via [SetupController.exportMnemonic].
  List<Widget> _exportControls() {
    return <Widget>[
      OutlinedButton.icon(
        onPressed: _copyMnemonic,
        icon: const Icon(Icons.content_copy),
        label: const Text('Copy seed phrase (BIP39)'),
      ),
      const SizedBox(height: 16),
      Text(
        'Or, for an app that accepts a non-BIP39 seed, copy '
        'SHA-512(seed + salt). The salt labels this setup (e.g. "main '
        'wallet") and keeps it distinct from your others; the long hex '
        'string is also far harder to memorise by accident.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _salt,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          labelText: 'Descriptive salt',
          hintText: 'e.g. main wallet',
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _copySaltedDigest,
        icon: const Icon(Icons.content_copy),
        label: const Text('Copy SHA-512(seed + salt)'),
      ),
    ];
  }

  Future<void> _copyMnemonic() async {
    final String? mnemonic = _setup.exportMnemonic();
    if (mnemonic == null) return;
    await Clipboard.setData(ClipboardData(text: mnemonic));
    if (!mounted) return;
    // Confirmation never echoes the secret itself.
    _toast('Seed phrase copied — paste it into your wallet, then clear the '
        'clipboard.');
  }

  Future<void> _copySaltedDigest() async {
    final String? digest = _setup.exportSaltedDigest(_salt.text);
    if (digest == null) return;
    await Clipboard.setData(ClipboardData(text: digest));
    if (!mounted) return;
    _toast('SHA-512 digest copied — paste it, then clear the clipboard.');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 1400), content: Text(msg)),
    );
  }

  Future<void> _start() async {
    _brightness.reset();
    setState(() => _selectMode = false);
    final String text = _stage0.text;
    if (_importMode) {
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
      await _setup.begin(
        preset: _preset,
        text: text,
        argon2Iterations: _iterations,
        profile: _profile,
      );
    }
    // The salt/pepper now lives in the chain; clear the input field on success
    // (the controller keeps its own copy for the in-session recall).
    if (_setup.phase != SetupPhase.error) _stage0.clear();
  }

  void _reset() {
    _setup.reset();
    _brightness.reset();
    _viewport.viewport = _initialViewport;
    _mnemonic.clear();
    _stage0.clear();
    setState(() {
      _selectMode = false;
      _stage0Hidden = true;
    });
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
