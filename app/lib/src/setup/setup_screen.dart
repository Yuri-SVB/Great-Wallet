import 'dart:async';
import 'dart:math' as math;

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
/// great-wall-ux's [FractalCanvas] / palette / brightness drive the visuals,
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

  /// Deep render mode (Alt+L). When on, the canvas escape-count cap rises from
  /// [EncodingConstants.renderMaxIterFast] to the engine's encode cap, so the
  /// rendered boundary matches where the encoder lands leaves. Off by default
  /// and reset per stage — it is an exceptional escape hatch for the rare leaf
  /// sitting deep in a high-escape-count void, and it makes interior rendering
  /// laggy (hence the persistent on-canvas marker).
  bool _deepRender = false;

  /// The displayed stage last seen, so deep render can snap back to fast when
  /// the view moves to a new stage (mirrors the per-stage brightness reset).
  int _shownStage = 0;

  /// UI sound cues. The canvas plays the tap "click"; the selection-outcome
  /// cues (select / confirm / deny) are dispatched from [_onCanvasSelect],
  /// where the decode result is known.
  final SoundBoard _sounds = SoundBoard();

  /// Focus node for the canvas/hotkey handler, so we can return keyboard focus
  /// to it after the user has been typing in a text field.
  final FocusNode _hotkeys = FocusNode(debugLabel: 'setup-hotkeys');

  // Focus nodes for the input controls. N/I/R focus the stages slider / import
  // field; C focuses the colour wheel; the rest are reached with Tab. Each field
  // is wrapped in _track(_Field…) so focus also drives the console help.
  final FocusNode _stage0Focus = FocusNode(debugLabel: 'salt');
  final FocusNode _iterationsFocus = FocusNode(debugLabel: 'iterations');
  final FocusNode _stagesFocus = FocusNode(debugLabel: 'stages');
  final FocusNode _profileFocus = FocusNode(debugLabel: 'profile');
  final FocusNode _mnemonicFocus = FocusNode(debugLabel: 'import');
  final FocusNode _exportLabelFocus = FocusNode(debugLabel: 'export-label');
  final FocusNode _hueFocus = FocusNode(debugLabel: 'hue');

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
      if (!mounted || _exportLabelRestricted == adjusted) return;
      setState(() => _exportLabelRestricted = adjusted);
      if (adjusted) {
        _warnOnConsole('Export label adjusted to A–Z, 0–9 and "-" so it stays '
            'reproducible.');
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
  /// the engine's canonicalisation. Tracks the state so the warning fires once
  /// per transition; the warning itself is surfaced on the console (DESIGN.md
  /// "Strong text restrictions": the divergence must be signalled to the user).
  bool _stage0Restricted = false;

  /// Called by [_SaltPepperFormatter] (during the edit pipeline) with whether
  /// the engine had to adjust the typed text. Defers the [setState] to a
  /// post-frame callback so it never runs mid-build, and fires even when the
  /// resolved text is unchanged (e.g. a lone disallowed char in an empty field,
  /// which would not trigger `onChanged`).
  void _onStage0Restricted({required bool adjusted}) {
    if (_stage0Restricted == adjusted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _stage0Restricted == adjusted) return;
      setState(() => _stage0Restricted = adjusted);
      if (adjusted) {
        _warnOnConsole('Salt / pepper adjusted to A–Z, 0–9 and "-" so it stays '
            'reproducible across devices.');
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

  // --- Bottom console ---------------------------------------------------------
  // The console at the foot of the screen is the app's single message surface:
  // toasts, the help text of whatever control is under focus, and confirmation
  // prompts all land here instead of as SnackBars / modal dialogs.

  /// Recent console lines, most recent last (capped).
  final List<String> _consoleLog = <String>[];

  /// The input control currently under focus; the console renders its help
  /// (label + live value) so the panel itself can stay label-free.
  _Field? _focusedField;

  /// Whether the hotkey manual is shown in the console. On at launch.
  bool _manualVisible = true;

  /// Whether the console and the stage-tab bar are collapsed to a thin status
  /// line. Toggled by the console's button (and, later, a hotkey).
  bool _chromeMinimized = false;

  /// A confirmation awaiting an inline answer in the console (replaces modal
  /// dialogs). Resolved by the console's action buttons.
  _ConsolePrompt? _prompt;

  @override
  void initState() {
    super.initState();
    _setup.addListener(_onSetupChanged);
  }

  void _onSetupChanged() {
    if (!mounted) return;
    // Snap deep render back to fast when the view moves to a new stage — it is a
    // per-view escalation, not a sticky preference (mirrors the brightness
    // per-stage reset).
    if (_setup.displayStageIndex != _shownStage) {
      _shownStage = _setup.displayStageIndex;
      _deepRender = false;
    }
    setState(() {});
  }

  @override
  void dispose() {
    // Release any awaiter blocked on an unanswered console prompt.
    if (_prompt != null && !_prompt!.completer.isCompleted) {
      _prompt!.completer.complete(false);
    }
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
    _stage0Focus.dispose();
    _iterationsFocus.dispose();
    _stagesFocus.dispose();
    _profileFocus.dispose();
    _mnemonicFocus.dispose();
    _exportLabelFocus.dispose();
    _hueFocus.dispose();
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

  /// Move keyboard focus to an input field by its node. If the field is not on
  /// screen in the current mode (`context == null`), say so in the console
  /// instead of silently doing nothing.
  void _focusField(FocusNode node, String label) {
    if (node.context == null) {
      _toast('The $label field is not available in this mode.');
      return;
    }
    _sounds.play(UiSound.focus);
    node.requestFocus();
  }

  /// Global shortcuts that fire even while a text field has focus (text fields
  /// do not consume these keys, so they bubble up to here): Esc leaves a field
  /// for the viewer, F1 is the manual, and F2–F5 switch top-level mode.
  Map<ShortcutActivator, VoidCallback> get _globalShortcuts =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _focusViewer,
        const SingleActivator(LogicalKeyboardKey.f1): _toggleManual,
        const SingleActivator(LogicalKeyboardKey.f2): () =>
            _gotoMode('Setup', here: true),
        const SingleActivator(LogicalKeyboardKey.f3): () =>
            _gotoMode('Train', here: false),
        const SingleActivator(LogicalKeyboardKey.f4): () =>
            _gotoMode('Accelerate', here: false),
        const SingleActivator(LogicalKeyboardKey.f5): () =>
            _gotoMode('Inherit', here: false),
      };

  /// Switch top-level mode (F2 Setup · F3 Train · F4 Accelerate · F5 Inherit).
  /// Only Setup exists in this app today; the others announce themselves so the
  /// keys (and muscle memory) are correct from the start.
  void _gotoMode(String name, {required bool here}) {
    if (here) {
      _toast('$name (current mode).');
    } else {
      _sounds.play(UiSound.deny);
      _toast('$name mode is not available yet.');
    }
  }

  /// Return keyboard focus to the fractal viewer (and so out of any text field),
  /// re-enabling the single-key hotkeys. The non-directional counterpart to Tab.
  void _focusViewer() => _hotkeys.requestFocus();

  /// Toggle the hotkey manual, restoring the console if it was minimized so the
  /// manual is actually visible. Bound to H and F1.
  void _toggleManual() {
    _sounds.play(UiSound.click);
    setState(() {
      _manualVisible = !_manualVisible;
      if (_manualVisible) _chromeMinimized = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool hasResult = _setup.phase == SetupPhase.memorise;
    return CallbackShortcuts(
      bindings: _globalShortcuts,
      child: Focus(
      focusNode: _hotkeys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  // Clicking anywhere on the canvas returns keyboard focus to the
                  // hotkey handler; the Listener is passive.
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
                            top: 56,
                            left: 12,
                            child: _Badge('Recall — click your point'),
                          ),
                        // Deep render reminder: explains the lag while the high
                        // escape-count cap is active, and how to turn it off.
                        if (_deepRender && !_setup.isTextStage)
                          const Positioned(
                            top: 56,
                            right: 12,
                            child: _Badge('Deep render · Alt+L to exit'),
                          ),
                        // Stage tabs hover over the top of the viewer with a
                        // transparent background, so they never squeeze the
                        // canvas. Hidden when the chrome is minimized.
                        if (!_chromeMinimized)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _stageTabs(),
                          ),
                        // The console always floats over the foot of the viewer
                        // (expanded or as a thin minimized bar) — it never takes
                        // a layout row, so the view is never squeezed.
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: _console(),
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
      ),
    );
  }

  /// The upper-edge stage tabs: a **fixed** bar of nine numbered tabs (0..8,
  /// the protocol ceiling) spanning the fractal-view width. Stage 0 is the
  /// salt/pepper text; 1..N-1 are the chain-derived fractals. The stage under
  /// focus is highlighted; tabs that are not currently reachable — outside this
  /// setup's stage count, not yet derived, or before any session — stay visible
  /// but greyed out and inert. Tapping a reachable tab focuses it (the same as
  /// pressing its number key).
  Widget _stageTabs() {
    const int maxTab = SetupController.maxPointStages; // 0..8 → nine fixed tabs
    final int current = _setup.displayStageIndex;
    // Transparent so the tabs hover over the fractal (no opaque bar).
    return Material(
      type: MaterialType.transparency,
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
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // While a text field (salt, seed phrase, …) holds focus, let it consume the
    // keystroke — never fire canvas shortcuts. Press Esc to leave the field and
    // return to the viewer (handled globally below).
    if (_textInputHasFocus) return KeyEventResult.ignored;
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    // V + ↑/↓ — sound volume. A held-key chord (not a Scheme-A single key), so
    // it is handled before the key-down-only guard below and may auto-repeat
    // while the arrow is held, ramping the level. Level 0 is silence == muted.
    if (kb.isLogicalKeyPressed(LogicalKeyboardKey.keyV)) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _changeVolume(up: true);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _changeVolume(up: false);
        return KeyEventResult.handled;
      }
    }
    // Scheme A: all hotkeys are single, unmodified keys, active when the viewer
    // (not a text field) has focus, fired once per press. If a modifier is held,
    // bail so OS combos are left alone.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Alt hotkeys — exceptional actions that take Alt by design; handled before
    // the modifier bail just below. Each is the rare/advanced counterpart of a
    // plain key: Alt+L deep render (vs the fast default), Alt+K the full export
    // digest (vs K's conventional first 32 chars).
    if (kb.isAltPressed && !kb.isControlPressed && !kb.isMetaPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyL) {
        _toggleDeepRender();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyK) {
        if (!_busy) _copyMasterSecret(full: true);
        return KeyEventResult.handled;
      }
    }
    if (kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // H — show / hide the hotkey manual (F1 is an alias, handled globally).
    if (event.logicalKey == LogicalKeyboardKey.keyH) {
      _toggleManual();
      return KeyEventResult.handled;
    }
    // M — minimize / restore the console + stage tabs.
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      final bool minimizing = !_chromeMinimized;
      _sounds.play(minimizing ? UiSound.chromeDown : UiSound.chromeUp);
      setState(() => _chromeMinimized = minimizing);
      return KeyEventResult.handled;
    }
    // C — focus the colour wheel (then ← → cycle hues).
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _focusField(_hueFocus, 'colour wheel');
      return KeyEventResult.handled;
    }
    // N / I / R — choose the source and focus its input (config screen).
    if (event.logicalKey == LogicalKeyboardKey.keyN) {
      _setSource(_SourceMode.fresh, focusInput: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyI) {
      _setSource(_SourceMode.import, focusInput: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      _setSource(_SourceMode.recall, focusInput: true);
      return KeyEventResult.handled;
    }
    // Field focus (uniform coverage): S salt/export · P profile · D derivation
    // steps. The salt (config) and export-label (session) fields never coexist,
    // so S covers whichever is on screen. Each no-ops with a console note if its
    // field is not in the current mode.
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      if (_stage0Focus.context != null) {
        _focusField(_stage0Focus, 'salt / pepper');
      } else {
        _focusField(_exportLabelFocus, 'export label');
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyP) {
      _focusField(_profileFocus, 'Argon2 profile');
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyD) {
      _focusField(_iterationsFocus, 'derivation steps');
      return KeyEventResult.handled;
    }
    // A — abort an in-progress derivation, behind a console confirmation
    // (foreground Stage-1 or background generation). TLP solving hooks in later.
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      _abortDerivation();
      return KeyEventResult.handled;
    }
    // Z — reset, behind a console confirmation so a stray keypress cannot wipe a
    // setup.
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _confirmReset();
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

  /// Step the UI sound-cue volume one level (bound to `V` + ↑/↓). Plays a cue at
  /// the new level as feedback — silent at level 0, which *is* the cue that the
  /// app is now muted — and notes the level in the console.
  void _changeVolume({required bool up}) {
    final int level = up ? _sounds.volumeUp() : _sounds.volumeDown();
    _sounds.play(up ? UiSound.adjustUp : UiSound.adjustDown);
    _toast(level == 0 ? 'Volume muted.' : 'Volume $level/$kMaxVolumeLevel.');
  }

  /// Current render escape-count cap: the fast default, or the engine's encode
  /// cap when deep render (Alt+L) is on.
  int get _renderMaxIter => _deepRender
      ? widget.core.encodeParams.maxIter
      : EncodingConstants.renderMaxIterFast;

  /// Toggle deep render mode (Alt+L). Raises/lowers the canvas escape-count cap
  /// so the rendered boundary matches the encoder in high escape-count voids;
  /// laggy while on (see the on-canvas marker).
  void _toggleDeepRender() {
    setState(() => _deepRender = !_deepRender);
    _sounds.play(_deepRender ? UiSound.modeOn : UiSound.modeOff);
    _toast(_deepRender
        ? 'Deep render ON — ${widget.core.encodeParams.maxIter} iterations '
            '(slower in voids).'
        : 'Deep render off — ${EncodingConstants.renderMaxIterFast} iterations.');
  }

  /// Select stage [index]: focus it if it is already available (Stage 0, or a
  /// fractal already derived), or — if it is the first not-yet-derived stage —
  /// trigger that stage's derivation. Anything else (out of range, or a gap
  /// beyond the next stage) sounds a deny cue and explains why.
  void _selectStage(int index) {
    if (_busy || !_hasSession) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    if (index == _setup.displayStageIndex) {
      // Re-selecting the current stage zooms to its point (if any).
      _focusPoint(index);
      return;
    }
    if (index < 0 || index >= _setup.nStages) {
      _sounds.play(UiSound.denyBlocked);
      _toast('This setup has ${_setup.nStages - 1} stage'
          '${_setup.nStages - 1 == 1 ? '' : 's'} (0–${_setup.nStages - 1}).');
      return;
    }
    // Already derived (or the Stage-0 text) — focus it and recenter the view.
    if (_setup.isStageAvailable(index)) {
      _sounds.play(UiSound.navStage);
      _setup.showStage(index);
      _recenter();
      return;
    }
    // Not derived yet because generation is still running in the background —
    // it will open on its own when ready.
    if (_setup.isGenerating) {
      _sounds.play(UiSound.denyPending);
      _toast('Stage $index is still deriving — it will open when ready.');
      return;
    }
    // Not derived. Only the very next stage can be derived, and only once the
    // previous stage carries a selected point.
    if (index != _setup.firstUnderivedStage) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Recall the earlier stages first.');
      return;
    }
    if (!_setup.hasSelectedPoint(index - 1)) {
      _sounds.play(UiSound.denyBlocked);
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
        _sounds.play(UiSound.stageReady);
        _recenter(); // land centred on the fresh fractal
        _toast('Stage ${_setup.displayStageIndex} derived — recall your point.');
      case DeriveOutcome.noPriorPoint:
        _sounds.play(UiSound.denyBlocked);
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

  /// Soft-coded target: a focused point's leaf should occupy this fraction of
  /// the view's (shorter-axis) span — half by default.
  static const double _kFocusLeafRatio = 0.5;

  /// Recenter the canvas to the default position/zoom and reset brightness,
  /// without touching the session. Triggered automatically on arriving at a
  /// stage (the old `R` behaviour, now folded into stage selection).
  void _recenter() {
    _viewport.viewport = _initialViewport;
    _brightness.reset();
    setState(() {});
  }

  /// Zoom-to-fit the point of [index] ("focus"): centre on its coordinates and
  /// set the zoom so the leaf's largest dimension is [_kFocusLeafRatio] of the
  /// view's shorter-axis span. No-op (deny) if that stage has no point.
  void _focusPoint(int index) {
    final ({double re, double im, double leafW, double leafH})? t =
        _setup.focusTargetAt(index);
    if (t == null) {
      _sounds.play(UiSound.denyBlocked);
      _toast('No point on Stage $index to focus yet.');
      return;
    }
    final double leafMax = math.max(t.leafW, t.leafH);
    final FractalViewport cur = _viewport.viewport;
    // half-extent is half the shorter-axis span; choose it so leafMax /
    // (2*halfExtent) == ratio. Fall back to the current zoom if the leaf size is
    // unknown.
    final double half =
        leafMax > 0 ? leafMax / (2 * _kFocusLeafRatio) : cur.halfExtent;
    _sounds.play(UiSound.navZoom);
    _viewport.viewport = cur.copyWith(
      centreRe: t.re,
      centreIm: t.im,
      halfExtent: half,
    );
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
      maxIterations: _renderMaxIter,
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
        _sounds.play(UiSound.denyMiss);
        msg = 'No encodable leaf there — zoom in and click closer.';
      case SelectionOutcome.marked:
        _sounds.play(UiSound.selectPoint);
        final int k = _setup.displayStageIndex;
        msg = k < _setup.nStages - 1
            ? 'Point marked on Stage $k/${_setup.nStages - 1} — '
                'select Stage ${k + 1} to derive it.'
            : 'Point marked on Stage $k/${_setup.nStages - 1}.';
      case SelectionOutcome.complete:
        _sounds.play(UiSound.finalReady);
        msg = 'Recall complete — seed reconstructed.';
      case SelectionOutcome.needsConfirm:
      case SelectionOutcome.busy:
        msg = null;
    }
    if (msg == null) return;
    _toast(msg);
  }

  /// Show an inline console confirmation and complete with the user's choice
  /// when they press a button. Shared by every confirm flow (re-derive, abort,
  /// reset). Ensures the console is expanded so the prompt is visible.
  Future<bool> _consoleConfirm({
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
  }) {
    final Completer<bool> completer = Completer<bool>();
    _resolvePrompt(false); // decline any already-pending prompt first
    _sounds.play(UiSound.warn); // a destructive confirmation is being raised
    setState(() {
      _chromeMinimized = false; // make sure the prompt is visible
      _prompt = _ConsolePrompt(
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        completer: completer,
      );
    });
    return completer.future;
  }

  /// Confirm a point re-selection that will discard the later fractals already
  /// derived from this stage. The confirmation is shown **inline in the
  /// console** (not a modal dialog); the returned future completes when the user
  /// presses one of the console's action buttons.
  Future<bool> _confirmReselect() => _consoleConfirm(
        message: 'Re-derive later stages? This stage already has a point and '
            'later stages were derived from it. Choosing a new point discards '
            'those later stages — you will re-derive and re-select them.',
        confirmLabel: 'Discard & re-select',
      );

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
                child: const Text('Abort'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- Console ----------------------------------------------------------------

  /// The hotkey manual, shown in the console (on by default at launch, toggled
  /// with `H`). Lists every shortcut the setup screen handles.
  static const List<String> _manualLines = <String>[
    'F1 manual · F2 Setup · F3 Train · F4 Accelerate · F5 Inherit',
    'Esc  return to the fractal (leave a text field) · Tab cycles fields',
    'H  manual   M  minimize / restore chrome   Z  reset (asks first)',
    '0–8  go to that stage (recenters); press again to zoom to its point',
    'N / I / R  New seed / Import / Recall (also focuses its input)',
    'S salt / export label · P profile · D derivation steps · C colour',
    'Enter  start (Generate / Encode / Begin recall) from a field',
    'K  copy the master secret ("the key")    A  abort a running derivation',
    'V+↑/↓  sound volume (level 0 = muted)',
    'Alt+K  copy the full export digest (not just the first 32 chars)',
    'Alt+L  deep render — reveal leaves in escape-count voids (slower)',
    'L+scroll brightness · scroll zoom · drag pan (over the canvas)',
  ];

  /// Console palette: "Gunmetal" — a cool, near-neutral blue-grey, translucent
  /// over the canvas so the fractal faintly bleeds through. The slight blue cast
  /// (channels offset a few levels from pure grey) reads as a *material* rather
  /// than an abstract flat grey; it stays unsaturated enough to sit neutrally
  /// against all six fractal hue schemes. See great-wall-ux/SCOPE.md
  /// §"Console palette" for the rationale.
  static const Color _kConsoleBg = Color(0xE6131519); // ~90% opaque gunmetal
  static const Color _kConsoleFg = Color(0xFFE9EDF2); // cool off-white
  static const Color _kConsoleAccent = Color(0xFFB8C2CC); // brighter, same cast
  static const TextStyle _termStyle = TextStyle(
    color: _kConsoleFg,
    fontFamily: GreatWallTypography.fontFamily,
    fontFamilyFallback: <String>['monospace'],
    fontSize: 13,
    height: 1.3,
  );

  /// The bottom console — the single surface for toasts, focus help, and inline
  /// confirmations. Collapses to a one-line status bar when minimized. Styled as
  /// a terminal: saturated green on black.
  Widget _console() {
    final String? focusHelp =
        _focusedField != null ? _fieldHelp(_focusedField!) : null;
    final String status = _prompt != null
        ? _prompt!.message
        : focusHelp ?? (_consoleLog.isEmpty ? 'Ready.' : _consoleLog.last);
    return Material(
      color: _kConsoleBg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _kConsoleAccent.withOpacity(0.35))),
        ),
        child: SafeArea(
          top: false,
          child: DefaultTextStyle(
            style: _termStyle,
            child: IconTheme(
              data: const IconThemeData(color: _kConsoleFg, size: 16),
              child: _chromeMinimized
                  ? _consoleStatusBar(status)
                  : _consoleExpanded(),
            ),
          ),
        ),
      ),
    );
  }

  /// The collapsed console: one status line plus a restore button.
  Widget _consoleStatusBar(String status) {
    return Row(
      children: <Widget>[
        const SizedBox(width: 12),
        const Icon(Icons.terminal),
        const SizedBox(width: 8),
        Expanded(
          child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        IconButton(
          tooltip: 'Restore console (M)',
          color: _kConsoleFg,
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: () => setState(() => _chromeMinimized = false),
        ),
      ],
    );
  }

  /// The expanded console: header, optional inline prompt, focus help, the
  /// recent log, and the optional hotkey manual.
  Widget _consoleExpanded() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header.
        Row(
          children: <Widget>[
            const SizedBox(width: 12),
            const Icon(Icons.terminal),
            const SizedBox(width: 8),
            Text('Console',
                style: _termStyle.copyWith(
                    color: _kConsoleAccent, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
              tooltip: _manualVisible ? 'Hide manual (H)' : 'Show manual (H)',
              color: _kConsoleFg,
              icon: Icon(_manualVisible ? Icons.help : Icons.help_outline),
              onPressed: () => setState(() => _manualVisible = !_manualVisible),
            ),
            IconButton(
              tooltip: 'Minimize console & tabs (M)',
              color: _kConsoleFg,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => setState(() => _chromeMinimized = true),
            ),
          ],
        ),
        Divider(height: 1, color: _kConsoleAccent.withOpacity(0.25)),
        // Live region — pinned above the scroll so a confirmation prompt or the
        // focused-field help is always visible (never scrolled behind the
        // manual).
        if (_prompt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _consolePromptBlock(),
          ),
        if (_prompt == null && _focusedField != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.info_outline, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(_fieldHelp(_focusedField!))),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final String line in _consoleLog) Text('› $line'),
                if (_manualVisible) ...<Widget>[
                  const SizedBox(height: 8),
                  Text('Hotkeys',
                      style: _termStyle.copyWith(
                          color: _kConsoleAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  for (final String line in _manualLines) Text(line),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The inline confirmation block (replaces modal dialogs): the prompt message
  /// plus Cancel / Confirm buttons that complete the pending future. Styled to
  /// match the terminal (green on black).
  Widget _consolePromptBlock() {
    final _ConsolePrompt p = _prompt!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _kConsoleFg.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _kConsoleFg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(p.message),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                style: TextButton.styleFrom(foregroundColor: _kConsoleFg),
                onPressed: () => _resolvePrompt(false),
                child: Text(p.cancelLabel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _kConsoleFg,
                  foregroundColor: _kConsoleBg,
                ),
                onPressed: () => _resolvePrompt(true),
                child: Text(p.confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlPanel(bool hasResult) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: <Widget>[

          if (_setup.phase == SetupPhase.recallComplete)
            ..._recallCompleteControls()
          else if (_setup.isRecallSession && hasResult)
            ..._recallControls()
          else if (!hasResult)
            ..._configControls()
          else
            ..._memoriseControls(),

          // (Stage navigation lives in the fixed 0–8 tab bar above the canvas;
          // the redundant "< Stage k / N >" row was dropped.)

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
          // Colour wheel: focus with C, cycle hues with ← →. The scheme name is
          // shown in the console (focus _Field.hue), not labelled here. No rotate
          // buttons — the arrows replace them.
          Center(
            child: _track(
              _Field.hue,
              _HueWheelControl(
                value: _hue,
                focusNode: _hueFocus,
                onChanged: (HueOffset h) {
                  _sounds.play(UiSound.click);
                  setState(() => _hue = h);
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'engine ${widget.core.engineVersion}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Choose the config source (New seed / Import / Recall) — from the segmented
  /// button or the N / I / R hotkeys. Only meaningful on the config screen.
  void _setSource(_SourceMode mode, {bool focusInput = false}) {
    if (_hasSession) return;
    _sounds.play(UiSound.click);
    setState(() => _source = mode);
    _toast(_sourceBlurb(mode));
    if (focusInput) {
      // Jump straight to the mode's primary input (the import field, or the
      // stages slider for New seed / Recall) once the rebuild has placed it.
      final FocusNode node =
          mode == _SourceMode.import ? _mnemonicFocus : _stagesFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && node.context != null) node.requestFocus();
      });
    }
  }

  /// Submit the config form from an input field's Enter key: run the action that
  /// the enabled button would (Generate / Encode phrase / Begin recall), if its
  /// preconditions hold. Focus returns to the viewer when the action starts.
  void _submitConfig() {
    if (_busy || _hasSession || !_iterationsValid) return;
    if (_source == _SourceMode.recall) {
      _beginRecall();
    } else if (_source == _SourceMode.import) {
      if (_mnemonic.text.trim().isNotEmpty) _start();
    } else {
      _start();
    }
  }

  /// One-line description of a source mode, shown in the console when selected
  /// (instead of an inline paragraph in the panel).
  String _sourceBlurb(_SourceMode mode) {
    switch (mode) {
      case _SourceMode.fresh:
        return 'New seed: generate fresh entropy and encode it onto the '
            'fractals to memorise.';
      case _SourceMode.import:
        return 'Import: encode an existing BIP39 phrase onto the fractals.';
      case _SourceMode.recall:
        return 'Recall: enter the same salt, number of stages and Argon2 '
            'settings, then click your memorised point on each stage. Nothing '
            'is encoded — the seed is rebuilt from your clicks.';
    }
  }

  List<Widget> _configControls() {
    return <Widget>[
      SegmentedButton<_SourceMode>(
        showSelectedIcon: false,
        segments: const <ButtonSegment<_SourceMode>>[
          ButtonSegment<_SourceMode>(
              value: _SourceMode.fresh, label: Text('New seed')),
          ButtonSegment<_SourceMode>(
              value: _SourceMode.import, label: Text('Import')),
          ButtonSegment<_SourceMode>(
              value: _SourceMode.recall, label: Text('Recall')),
        ],
        selected: <_SourceMode>{_source},
        onSelectionChanged:
            _busy ? null : (Set<_SourceMode> s) => _setSource(s.first),
      ),
      const SizedBox(height: 16),
      // Keep the source-specific input the same height (the import field vs the
      // stages slider) so switching New seed / Import / Recall does not shift the
      // controls below it. Each builder returns a single widget.
      SizedBox(
        height: 56,
        child: Align(
          child: _source == _SourceMode.import
              ? _mnemonicInput().single
              : _stagesInput().single,
        ),
      ),
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
    // Label and value live in the console (focus _Field.stages); the panel keeps
    // only the slider to save vertical space.
    return <Widget>[
      _track(
        _Field.stages,
        Row(
          children: <Widget>[
            _sliderLabel('Stages'),
            Expanded(
              child: Slider(
                focusNode: _stagesFocus,
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
                        _sounds.play(UiSound.tickSoft);
                        setState(() => _pointStages = next);
                      },
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// A fixed-width label placed to the left of a slider, so the label adds no
  /// vertical height (layout stays put) and never shifts horizontally.
  Widget _sliderLabel(String text) => SizedBox(
        width: 58,
        child: Text(text, style: Theme.of(context).textTheme.labelMedium),
      );

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
    // Label/help live in the console (focus _Field.iterations); keep only the
    // field (with its validation error) in the panel.
    return <Widget>[
      _track(
        _Field.iterations,
        TextField(
          controller: _iterationsField,
          focusNode: _iterationsFocus,
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
            labelText: 'Derivation steps / stage',
            hintText: 'e.g. 1',
            errorText: invalid ? 'Enter a whole number (0 or more).' : null,
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            final int? v = int.tryParse(_iterationsField.text.trim());
            if (v != null && v >= 0) _iterations = v;
            setState(() {});
          },
          onSubmitted: (_) => _submitConfig(),
        ),
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
    // Profile name lives in the console (focus _Field.profile); the slider thumb
    // label still shows it on drag.
    return _track(
      _Field.profile,
      Row(
        children: <Widget>[
          _sliderLabel('Memory'),
          Expanded(
            child: Slider(
              focusNode: _profileFocus,
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
                      _sounds.play(UiSound.tickSoft);
                      setState(() => _profile = next);
                    },
            ),
          ),
        ],
      ),
    );
  }

  /// The obscured BIP39 import field. The phrase is secret, so the field is
  /// blind (asterisks) by default with an eye toggle; it is never echoed back.
  /// The instruction and live word-count are shown in the console on focus
  /// ([_fieldHelp]).
  List<Widget> _mnemonicInput() {
    return <Widget>[
      _track(
        _Field.mnemonic,
        TextField(
          controller: _mnemonic,
          focusNode: _mnemonicFocus,
          obscureText: _mnemonicHidden,
          enabled: !_busy,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: 'Import phrase (BIP39)',
            hintText: 'word1 word2 …',
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
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },
          onSubmitted: (_) => _submitConfig(),
        ),
      ),
    ];
  }

  /// The Stage-0 salt/pepper field: obscured by default with a reveal toggle,
  /// constrained to a safe ASCII subset (uppercase letters, digits, hyphen).
  /// One field, one scheme — the user decides whether it is a public label or a
  /// secret pepper. The restriction (and why it exists) is explained inline.
  List<Widget> _stage0Input() {
    // Label/help live in the console (focus _Field.salt). The reveal toggle and
    // the restriction warning stay on the field.
    return <Widget>[
      _track(
        _Field.salt,
        TextField(
          controller: _stage0,
          focusNode: _stage0Focus,
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
            labelText: 'Stage 0 — salt / pepper',
            hintText: 'e.g. MAIN-STASH',
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
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },
          onSubmitted: (_) => _submitConfig(),
        ),
      ),
      // The formatting warning (when the engine adjusts the text) is conveyed on
      // the console, which expands and pops to the foreground — see
      // _onStage0Restricted / _warnOnConsole.
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
      // chain-derived fractals, one point each. Step through with the 0–8 tab
      // bar or number keys (press a stage again to zoom to its point).
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
    // Heading + explanation live in the console (focus _Field.exportLabel).
    return <Widget>[
      _track(
        _Field.exportLabel,
        TextField(
          controller: _exportLabel,
          focusNode: _exportLabelFocus,
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
          ),
          style: const TextStyle(
            fontFamily: GreatWallTypography.fontFamily,
            fontFamilyFallback: <String>['monospace'],
          ),
          onChanged: (_) {
            _sounds.play(UiSound.tickSoft);
            setState(() {});
          },
        ),
      ),
      // Formatting warning is conveyed on the console (see
      // _onExportLabelRestricted / _warnOnConsole).
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
    _sounds.play(UiSound.exportOk);
    // Confirmation never echoes the secret itself.
    _toast('Seed phrase copied — paste it into your wallet, then clear the '
        'clipboard.');
  }

  /// Export and copy the master secret for the focused stage. `K` copies the
  /// conventional first-32-chars view; `Alt+K` ([full]) copies the entire digest
  /// (all [MasterSecret.outputBytes] as hex).
  Future<void> _copyMasterSecret({bool full = false}) async {
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
        full: full,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    if (!mounted) return;
    if (secret == null) {
      _sounds.play(UiSound.deny);
      return;
    }
    final int chars = secret.length;
    await Clipboard.setData(ClipboardData(text: secret));
    if (!mounted) return;
    _sounds.play(UiSound.exportOk);
    // Confirmation never echoes the secret itself.
    _toast(full
        ? 'Full key copied ($chars chars) — paste it, then clear the clipboard.'
        : 'Key copied — paste it, then clear the clipboard.');
  }

  /// Append a line to the console log (the app's toast surface).
  void _toast(String msg) {
    if (!mounted) return;
    setState(() {
      _consoleLog.add(msg);
      if (_consoleLog.length > 50) _consoleLog.removeRange(0, _consoleLog.length - 50);
    });
  }

  /// Surface a warning on the console and make sure it is seen: expand the
  /// console and hide the hotkey manual so the message leads, then log it.
  void _warnOnConsole(String message) {
    if (!mounted) return;
    setState(() {
      _chromeMinimized = false; // expand the console
      _manualVisible = false; // hide the hotkeys menu so the warning leads
    });
    _toast(message);
  }

  /// Set the focus-help line when a control gains focus. Deferred to a
  /// post-frame callback so it never runs mid-build (focus changes fire during
  /// layout).
  void _gainFocus(_Field f) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusedField == f) return;
      setState(() => _focusedField = f);
    });
  }

  /// Clear the focused-field marker when a control loses focus — but only if it
  /// is still this control (so the gain of the next control wins regardless of
  /// callback order).
  void _loseFocus(_Field f) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusedField != f) return;
      setState(() => _focusedField = null);
    });
  }

  /// Wrap [child] so that, while it (or a descendant text field/slider) holds
  /// focus, the console shows field [f]'s help. The wrapper is not a tab stop.
  Widget _track(_Field f, Widget child) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool has) => has ? _gainFocus(f) : _loseFocus(f),
      child: child,
    );
  }

  /// The console help for an input field: its label plus the current value, so
  /// the panel itself can omit both. Computed live, so it tracks edits while the
  /// field stays focused.
  String _fieldHelp(_Field f) {
    switch (f) {
      case _Field.stages:
        return 'Number of stages: $_pointStages (0–8). 0 = Stage-0 text only; '
            '8 = 24 words / 256 bits. ← → or drag to change.';
      case _Field.iterations:
        final String n = _iterationsField.text.trim();
        return 'Derivation steps between stages (Argon2 N) = '
            '${n.isEmpty ? '—' : n} (0…∞). Higher = a longer, stronger '
            'derivation (hours to weeks).';
      case _Field.profile:
        final int idx =
            _profiles.indexOf(_profile).clamp(0, _profiles.length - 1);
        return 'Argon2 profile: ${_profileLabels[idx]} — memory per pass. '
            '← → or drag to change.';
      case _Field.salt:
        return 'Stage 0 salt/pepper: seeds the fractal chain. A public label or '
            'a secret pasted pepper (uppercase letters, digits, hyphen).';
      case _Field.mnemonic:
        final int wc = _mnemonic.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((String w) => w.isNotEmpty)
            .length;
        if (wc == 0) {
          return 'Import phrase: type or paste your existing BIP39 seed phrase '
              '(kept hidden).';
        }
        if (wc % 3 != 0 || wc > 24) {
          return 'Import phrase: $wc words — must be a multiple of 3 (3–24).';
        }
        final bool standard = <int>{12, 15, 18, 21, 24}.contains(wc);
        return 'Import phrase: $wc words → ${wc ~/ 3} stages'
            '${standard ? '' : ' (sub-standard length)'}.';
      case _Field.exportLabel:
        final int idx = _setup.displayStageIndex;
        return 'Key (master-secret export): Argon2id over your setup so far '
            '(stages 1–$idx). Paste into another wallet or use as a downstream '
            'pepper. This optional label versions the key (e.g. SIGNING-1, '
            'uppercase/digits/hyphen). Press K to derive and copy — blind, '
            'never shown.';
      case _Field.hue:
        return 'Colour scheme: ${_hue.name}. ← → to cycle through the six hues.';
    }
  }

  /// Answer the pending console confirmation, completing its future.
  void _resolvePrompt(bool ok) {
    final _ConsolePrompt? p = _prompt;
    if (p == null) return;
    setState(() => _prompt = null);
    if (!p.completer.isCompleted) p.completer.complete(ok);
  }

  Future<void> _start() async {
    _sounds.play(UiSound.click);
    _focusViewer(); // leave the input field; hotkeys act on the viewer now
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
    _focusViewer(); // leave the input field; clicks/hotkeys act on the viewer
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

  /// Reset behind an inline console confirmation, so the Z hotkey (or a stray
  /// keypress) cannot discard a setup by accident.
  Future<void> _confirmReset() async {
    final bool ok = await _consoleConfirm(
      message: 'Reset and discard the current setup? Un-memorised points and '
          'any entered text will be lost.',
      confirmLabel: 'Reset',
    );
    if (ok && mounted) _reset();
  }

  /// Abort a running derivation behind a console confirmation (the A hotkey).
  /// No-op with a deny cue when nothing is deriving.
  Future<void> _abortDerivation() async {
    if (!_busy && !_setup.isGenerating) {
      _sounds.play(UiSound.deny);
      return;
    }
    final bool ok = await _consoleConfirm(
      message: 'Abort the running derivation? Progress on the current stage is '
          'lost (stages already derived are kept).',
      confirmLabel: 'Abort',
    );
    if (ok && mounted && (_busy || _setup.isGenerating)) {
      _setup.requestStop();
      _toast('Derivation aborted.');
    }
  }

  void _reset() {
    _sounds.play(UiSound.click);
    _resolvePrompt(false); // drop any pending console confirmation
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
    _focusViewer(); // back on the config screen; hotkeys act on the viewer
  }
}

/// Where the Setup session's root comes from: a freshly generated seed, an
/// imported BIP39 phrase, or a cold-start recall of an existing setup (derive
/// from the salt and reconstruct the seed from the user's clicks).
enum _SourceMode { fresh, import, recall }

/// The input controls whose label + live value are conveyed in the console while
/// focused (so the panel itself can stay label-free).
enum _Field { stages, iterations, profile, salt, mnemonic, exportLabel, hue }

/// A compact, focusable colour wheel: six hue sectors, no rotate buttons (←/→
/// cycle while focused) and no inline name (it is shown in the console). Tapping
/// a sector selects it and focuses the wheel.
class _HueWheelControl extends StatelessWidget {
  const _HueWheelControl({
    required this.value,
    required this.onChanged,
    required this.focusNode,
    this.diameter = 84,
  });

  final HueOffset value;
  final ValueChanged<HueOffset> onChanged;
  final FocusNode focusNode;
  final double diameter;

  void _step(int dir) {
    final List<HueOffset> order = HueOffset.values;
    final int i = (value.index + dir) % order.length;
    onChanged(order[i < 0 ? i + order.length : i]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Let the V + ↑/↓ volume chord bubble up to the screen handler instead of
    // cycling the hue, so volume works the same while the wheel holds focus.
    if (HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.keyV)) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTapDown(TapDownDetails details) {
    final double r = diameter / 2;
    final Offset v = details.localPosition - Offset(r, r);
    if (v.distance < r * 0.25) return; // ignore the hub
    double angle = math.atan2(v.dx, -v.dy);
    if (angle < 0) angle += 2 * math.pi;
    final int n = HueOffset.values.length;
    final int sector = (angle / (2 * math.pi) * n).floor() % n;
    onChanged(HueOffset.values[sector]);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: Semantics(
        label: 'Colour wheel: ${value.name}',
        button: true,
        child: GestureDetector(
          onTapDown: (TapDownDetails d) {
            focusNode.requestFocus();
            _handleTapDown(d);
          },
          child: CustomPaint(
            size: Size.square(diameter),
            painter: _HuePainter(value, focusNode.hasFocus),
          ),
        ),
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter(this.selected, this.focused);

  final HueOffset selected;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final Offset c = Offset(r, r);
    final int n = HueOffset.values.length;
    final double sweep = 2 * math.pi / n;
    for (int i = 0; i < n; i++) {
      final double start = -math.pi / 2 + i * sweep;
      final Paint fill = Paint()
        ..style = PaintingStyle.fill
        ..color = HSVColor.fromAHSV(
          1.0,
          HueOffset.values[i].degrees.toDouble() % 360.0,
          1.0,
          1.0,
        ).toColor();
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: r), start, sweep, true, fill);
      if (HueOffset.values[i] == selected) {
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r - 2),
          start,
          sweep,
          true,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4.0
            ..color = Colors.white,
        );
      }
    }
    if (focused) {
      canvas.drawCircle(
        c,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = Colors.white70,
      );
    }
    canvas.drawCircle(c, r * 0.22, Paint()..color = Colors.black87);
  }

  @override
  bool shouldRepaint(_HuePainter old) =>
      old.selected != selected || old.focused != focused;
}

/// A confirmation rendered inline in the console (instead of a modal dialog).
/// The console's action buttons complete [completer] with the user's choice.
class _ConsolePrompt {
  _ConsolePrompt({
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.completer,
  });

  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final Completer<bool> completer;
}

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
