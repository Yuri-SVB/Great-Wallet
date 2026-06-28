import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:great_wall_ux/great_wall_ux.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart' as qr;

import '../core/encoding_constants.dart';
import '../core/great_wall_core.dart';
import '../ffi/core_bindings.dart';
import 'desktop_qr_scanner.dart';
import 'setup_controller.dart';
import 'setup_crypto.dart';

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
        _warnOnConsole('Export salt adjusted to A–Z, 0–9 and "-" so it stays '
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
  _ImportFormat _importFormat = _ImportFormat.words;

  /// Select mode: when on, tapping the canvas decodes the point under the
  /// cursor instead of panning. Toggled by the panel button or the `S` key.
  bool _selectMode = false;

  /// True while the user is picking a replacement point for the displayed stage
  /// (the `R` edit): the next canvas click sets the new point. Esc cancels.
  bool _editPointMode = false;

  /// The stage whose point is being replaced by import (the `I` edit), or null
  /// when the inline bit editor is closed.
  int? _pointImportStage;
  _ImportFormat _pointImportFmt = _ImportFormat.words;
  final TextEditingController _pointImport = TextEditingController();
  final FocusNode _pointImportFocus = FocusNode(debugLabel: 'point-import');

  /// The point-stage count a pending expansion would grow to, while the method
  /// picker (New / Import / Manual) is open in the console. Null otherwise.
  int? _expandTarget;

  /// The point-stage count an in-progress import expansion will reach, while its
  /// inline m-point bit editor is open. Reuses the [_pointImport] field/focus
  /// (the two import editors are mutually exclusive). Null otherwise.
  int? _expandImportTarget;

  /// True during a **manual** expansion (the R method): the new stages derive
  /// one at a time and the user clicks each point on its fresh fractal. Canvas
  /// selection is enabled while this is on; [_expandManualTarget] is the
  /// point-stage count the walk grows to.
  bool _expandManualActive = false;
  int? _expandManualTarget;

  /// Provisional-key save/load: the destination/source file path. The
  /// provisional key itself is never kept in a screen field — it is entered,
  /// shown, or copied only inside the Write/Open dialogs. [_vaultBusy] disables
  /// the controls while an encrypt/decrypt pass runs.
  final TextEditingController _vaultPath = TextEditingController();
  final FocusNode _vaultPathFocus = FocusNode(debugLabel: 'vault-path');
  bool _vaultBusy = false;

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

  /// Whether the console is collapsed to a thin status line (the `M` hotkey /
  /// the console's button). Independent of the stage-tab bar.
  bool _chromeMinimized = false;

  /// Whether the stage-tab bar is hidden (the `9` hotkey). Independent of the
  /// console so the user can dismiss either alone.
  bool _stageBarHidden = false;

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
      _editPointMode = false; // cancel an armed point edit if the view moved
      if (_pointImportStage != null) {
        _pointImport.clear();
        _pointImportStage = null;
      }
      // A moved view also dismisses an open expansion picker / import editor.
      _expandTarget = null;
      if (_expandImportTarget != null) {
        _pointImport.clear();
        _expandImportTarget = null;
      }
    }
    _updateEta();
    setState(() {});
  }

  // --- Derivation ETA estimate ------------------------------------------------
  // Timed off the controller's per-pass notifications: every point stage runs
  // the same N passes at ~the same cost, so a running average of completed-pass
  // durations projects both "this stage" and "to the last stage" honestly.

  final Stopwatch _passWatch = Stopwatch();
  int _etaStage = 0; // stage the watch is timing (0 = none)
  int _etaPass0 = 0; // argon2Done when the watch started
  int _etaLastDone = 0; // argon2Done at the last completed pass
  int _etaLastMs = 0; // watch elapsed at that pass (avg is over completed passes)

  /// Refresh the pass-timing watch from the controller's current state. Resets
  /// when the deriving stage changes; records a timestamp when a pass completes.
  void _updateEta() {
    final int? ds = _setup.derivingStageIndex;
    if (ds == null) {
      if (_passWatch.isRunning) _passWatch.stop();
      _passWatch.reset();
      _etaStage = 0;
      return;
    }
    if (ds != _etaStage) {
      _etaStage = ds;
      _etaPass0 = _setup.argon2Done;
      _etaLastDone = _setup.argon2Done;
      _etaLastMs = 0;
      _passWatch
        ..reset()
        ..start();
    } else if (_setup.argon2Done > _etaLastDone) {
      _etaLastDone = _setup.argon2Done;
      _etaLastMs = _passWatch.elapsedMilliseconds;
    }
  }

  /// Average completed-pass duration in ms, or null until a pass has completed
  /// since timing began ("estimating…").
  double? _avgPassMs() {
    final int passes = _etaLastDone - _etaPass0;
    if (passes <= 0 || _etaLastMs <= 0) return null;
    return _etaLastMs / passes;
  }

  /// Estimated time left on the deriving stage.
  Duration? _stageEta() {
    final double? avg = _avgPassMs();
    if (avg == null) return null;
    final int remaining =
        (_setup.argon2Total - _setup.argon2Done).clamp(0, _setup.argon2Total);
    return Duration(milliseconds: (remaining * avg).round());
  }

  /// Estimated time left until the batch's last stage finishes.
  Duration? _totalEta() {
    final double? avg = _avgPassMs();
    final Duration? stage = _stageEta();
    final int? ds = _setup.derivingStageIndex;
    if (avg == null || stage == null || ds == null) return null;
    final int last = _setup.nStages - 1;
    final int fullAfter = (last - ds).clamp(0, last);
    return stage +
        Duration(milliseconds: (fullAfter * _setup.argon2Total * avg).round());
  }

  /// Estimated time until stage [k] finishes (null if it is already done or
  /// not yet estimable).
  Duration? _etaToStage(int k) {
    final int? ds = _setup.derivingStageIndex;
    final double? avg = _avgPassMs();
    final Duration? stage = _stageEta();
    if (ds == null || avg == null || stage == null || k < ds) return null;
    final Duration fullStage =
        Duration(milliseconds: (_setup.argon2Total * avg).round());
    return stage + fullStage * (k - ds);
  }

  /// Compact duration: `4h 50m` / `33m 12s` / `45s`.
  String _fmtEta(Duration d) {
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  /// A stage tab's hover label: its name, plus its own ETA while deriving.
  String _tabTooltip(int i) {
    final String base = i == 0 ? 'Stage 0 — salt / pepper' : 'Stage $i';
    final Duration? eta = _etaToStage(i);
    return eta == null ? base : '$base — ETA ~${_fmtEta(eta)}';
  }

  /// One-line derivation status for the console, or null when nothing derives.
  String? _derivationStatus() {
    final int? ds = _setup.derivingStageIndex;
    if (ds == null) return null;
    final Duration? t = _totalEta();
    final String eta = t == null ? 'estimating…' : '~${_fmtEta(t)} left';
    final int last = _setup.nStages - 1;
    return 'Deriving Stage $ds/$last — pass ${_setup.argon2Done}/'
        '${_setup.argon2Total} · $eta';
  }

  /// The two-line derivation block for the expanded console: the live pass and
  /// the stage / batch ETAs.
  Widget _derivationBlock() {
    final int? ds = _setup.derivingStageIndex;
    final int last = _setup.nStages - 1;
    final Duration? s = _stageEta();
    final Duration? t = _totalEta();
    final String line2 = (s == null || t == null)
        ? 'estimating…'
        : '~${_fmtEta(s)} to this stage · ~${_fmtEta(t)} to Stage $last';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.hourglass_top, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Deriving Stage $ds/$last — pass ${_setup.argon2Done}/'
                '${_setup.argon2Total}',
                style: _termStyle.copyWith(
                    color: _kConsoleAccent, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Text(line2),
        ),
      ],
    );
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
    _pointImport.dispose();
    _pointImportFocus.dispose();
    _vaultPath.dispose();
    _vaultPathFocus.dispose();
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

  /// Whether in-app webcam QR scanning is available — only on the platforms
  /// `mobile_scanner` implements (Android / iOS / macOS). Linux/Windows hide the
  /// Scan button and fall back to typing the key.
  bool get _scanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Whether the desktop (flutter_webrtc + zxing2) scan path applies — Linux and
  /// Windows, where `mobile_scanner` has no backend. Best-effort: the camera may
  /// fail to open on some setups, in which case the user falls back to hex-load.
  bool get _desktopScanSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows);

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
  void _focusViewer() {
    // Esc also cancels an armed manual point edit and any open expansion picker
    // or import editor.
    if (_editPointMode) setState(() => _editPointMode = false);
    if (_expandTarget != null) setState(() => _expandTarget = null);
    if (_expandImportTarget != null) {
      _pointImport.clear();
      setState(() => _expandImportTarget = null);
    }
    if (_expandManualActive) _endManualExpand();
    _hotkeys.requestFocus();
  }

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
                          Positioned(
                            top: 56,
                            left: 12,
                            child: _Badge(_expandManualActive
                                ? 'Add stage — click your point'
                                : 'Recall — click your point'),
                          ),
                        if (_editPointMode && !_setup.isTextStage)
                          const Positioned(
                            top: 56,
                            left: 12,
                            child: _Badge('Click the new point · Esc to cancel'),
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
                        // canvas. Toggled independently of the console (key 9).
                        if (!_stageBarHidden)
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
    final int? deriving = _setup.derivingStageIndex;
    final double progress = _setup.stageProgress;
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
                      // In the (possibly slider-previewed) setup, so it shows as
                      // a real box rather than an out-of-setup ghost slot.
                      inSetup: i < _setup.nStages,
                      selected: _hasSession && i == current,
                      available: _hasSession && _setup.isStageAvailable(i),
                      deriving: deriving == i,
                      progress: progress,
                      tooltip: _tabTooltip(i),
                      // Tappable for a stage in the active setup; a ghost slot
                      // beyond it is tappable too when the setup can grow, to
                      // start an expansion up to that slot.
                      onTap: (_hasSession && i < _setup.nStages)
                          ? () => _selectStage(i)
                          : (_hasSession &&
                                  _setup.canExpand &&
                                  i >= _setup.nStages &&
                                  i <= SetupController.maxPointStages)
                              ? () => _beginExpand(i)
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
      // Alt+I — the hex counterpart of plain I (BIP39 words): on a live editable
      // stage it opens the point-import editor in hex; on the config screen it
      // selects the Import source pre-toggled to hex.
      if (event.logicalKey == LogicalKeyboardKey.keyI) {
        if (_expandTarget != null) {
          _expandImport(hex: true);
        } else if (_setup.canEditCurrentPoint) {
          _changePointImport(hex: true);
        } else {
          _setSource(_SourceMode.import, focusInput: true);
          setState(() => _importFormat = _ImportFormat.hex);
        }
        return KeyEventResult.handled;
      }
      // Alt+V — reveal / hide the obscured sensitive text fields together (the
      // visibility counterpart of V's volume control).
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        _toggleSensitiveVisibility();
        return KeyEventResult.handled;
      }
    }
    if (kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // H — halt an in-progress derivation, behind a console confirmation (keeps
    // the work done so far). The hotkey manual lives on F1 only now.
    if (event.logicalKey == LogicalKeyboardKey.keyH) {
      _abortDerivation();
      return KeyEventResult.handled;
    }
    // M — collapse / restore the console (independent of the stage bar).
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      final bool minimizing = !_chromeMinimized;
      _sounds.play(minimizing ? UiSound.chromeDown : UiSound.chromeUp);
      setState(() => _chromeMinimized = minimizing);
      return KeyEventResult.handled;
    }
    // 9 — show / hide the stage-tab bar (independent of the console).
    if (event.logicalKey == LogicalKeyboardKey.digit9 ||
        event.logicalKey == LogicalKeyboardKey.numpad9) {
      final bool hiding = !_stageBarHidden;
      _sounds.play(hiding ? UiSound.chromeDown : UiSound.chromeUp);
      setState(() => _stageBarHidden = hiding);
      return KeyEventResult.handled;
    }
    // X — exclude the displayed stage and every stage above it (truncate).
    if (event.logicalKey == LogicalKeyboardKey.keyX) {
      _truncate();
      return KeyEventResult.handled;
    }
    // C — focus the colour wheel (then ← → cycle hues).
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      _focusField(_hueFocus, 'colour wheel');
      return KeyEventResult.handled;
    }
    // N / I / R — on the config screen, choose the source and focus its input.
    // On a live, editable point stage they instead change that stage's point:
    // N = new random, R = manual click. (I — blind import — lands with the
    // expansion work, which shares the inline bit editor.)
    if (event.logicalKey == LogicalKeyboardKey.keyN) {
      if (_expandTarget != null) {
        _expandNew();
      } else if (_setup.canEditCurrentPoint) {
        _changePointGenerated();
      } else {
        _setSource(_SourceMode.fresh, focusInput: true);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyI) {
      if (_expandTarget != null) {
        _expandImport(hex: false);
      } else if (_setup.canEditCurrentPoint) {
        _changePointImport(hex: false);
      } else {
        _setSource(_SourceMode.import, focusInput: true);
        setState(() => _importFormat = _ImportFormat.words);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyR) {
      if (_expandTarget != null) {
        _expandManual();
        return KeyEventResult.handled;
      }
      if (_setup.canEditCurrentPoint) {
        _changePointManual();
      } else {
        _setSource(_SourceMode.recall, focusInput: true);
      }
      return KeyEventResult.handled;
    }
    // Field focus (uniform coverage): S salt/export · P profile · D derivation
    // steps. The salt (config screen) and export-label (live setup) fields never
    // coexist, so pick by session state rather than a focus node's context
    // (which could be stale): a live setup means the export label.
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      if (_hasSession) {
        _focusField(_exportLabelFocus, 'export salt');
      } else {
        _focusField(_stage0Focus, 'salt / pepper');
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
    // (A is currently unbound — freed from its old "abort" duty, now on H.)
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
    // Provisional-key panel (when shown): F focus file path · W write/save ·
    // O open setup file · T blank template. W/O/T no-op while a vault pass runs.
    if (_vaultPanelShown) {
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        _focusVaultPath();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyW) {
        if (!_vaultBusy) _writeSetup();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyO) {
        if (!_vaultBusy) _openSetup();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyT) {
        if (!_vaultBusy) _exportBlankTemplate();
        return KeyEventResult.handled;
      }
    }
    // 0–8 — select that stage: focus it, or derive it if it is next.
    final int? digit = _digitKeys[event.logicalKey];
    if (digit != null) {
      _selectStage(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Alt+V — reveal or hide the obscured sensitive text fields (the salt/pepper
  /// and the import phrase/hex) together: if any is hidden, reveal all; if all
  /// are shown, hide all. The counterpart of V's volume control.
  void _toggleSensitiveVisibility() {
    final bool reveal = _stage0Hidden || _mnemonicHidden;
    _sounds.play(UiSound.click);
    setState(() {
      _stage0Hidden = !reveal;
      _mnemonicHidden = !reveal;
    });
    _toast(reveal ? 'Sensitive text revealed.' : 'Sensitive text hidden.');
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
      // A ghost slot beyond the setup starts an expansion up to it (if the setup
      // can grow); anything else is out of range.
      if (index >= _setup.nStages &&
          index <= SetupController.maxPointStages &&
          _setup.canExpand) {
        _beginExpand(index);
        return;
      }
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
      onSelect: (_selectMode || _editPointMode)
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
      // Sit a little above centre so the derivation progress overlay (which sits
      // a little below centre) never lands on top of this text.
      child: Align(
        alignment: const Alignment(0, -0.3),
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
    // Editing the displayed stage's point (the R edit): the click sets the new
    // point and the tail (if any) was already confirmed when arming the mode.
    if (_editPointMode) {
      final SelectionOutcome o = _setup.changeCurrentPointAt(sel);
      final int k = _setup.displayStageIndex;
      switch (o) {
        case SelectionOutcome.invalid:
          _sounds.play(UiSound.denyMiss);
          _toast('No encodable leaf there — zoom in and click closer.');
        case SelectionOutcome.marked:
          setState(() => _editPointMode = false);
          _sounds.play(UiSound.changePoint);
          _toast('Stage $k point changed.');
        default:
          setState(() => _editPointMode = false);
      }
      return;
    }
    // During a manual expansion, only the fresh (point-less) new stages accept a
    // click; an existing stage's point is never clobbered by a stray tap.
    if (_expandManualActive && _setup.hasPointAt(_setup.displayStageIndex)) {
      _sounds.play(UiSound.denyBlocked);
      _toast('Stage ${_setup.displayStageIndex} already has its point.');
      return;
    }
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
        // Manual expansion: the click set this new stage's point; advance to the
        // next new stage (deriving it) until the target is reached.
        if (_expandManualActive) {
          final int g = _expandManualTarget ?? k;
          if (k < g) {
            _toast('Point set on Stage $k — deriving Stage ${k + 1}…');
            await _deriveNextStage();
          } else {
            _endManualExpand();
            _sounds.play(UiSound.finalReady);
            _toast('Expansion complete — Stage $g added.');
          }
          return;
        }
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
    final bool deriving = _setup.phase == SetupPhase.deriving;
    // The stage-tab strip (above this scrim) is the progress bar and the console
    // carries the live text + ETA, so the overlay avoids a third copy: while
    // deriving it shows only Halt; for the brief encode (no Halt) it shows a
    // short label so the dim is not blank.
    return ColoredBox(
      color: Colors.black54,
      // Sit a little below centre so it clears the Stage-0 text panel (which
      // sits a little above centre) during the foreground Stage-1 derivation.
      child: Align(
        alignment: const Alignment(0, 0.3),
        child: deriving
            ? TextButton(
                onPressed: _setup.halt,
                child: const Text('Halt'),
              )
            : Text(
                _setup.phase == SetupPhase.encoding ? 'Encoding…' : 'Working…',
                style: const TextStyle(color: Colors.white),
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
    'M  console   9  stage bar   Z  reset (asks first)',
    '0–8  go to that stage (recenters); press again to zoom to its point',
    'N / I / R  New seed / Import / Recall (config) · on a stage: change its point',
    'I import = BIP39 words · Alt+I import = hex (config & point edit alike)',
    'Click/press a ghost slot past the last stage to grow the setup (N/I/R)',
    'S salt / export salt · P profile · D derivation steps · C colour',
    'Enter  start (Generate / Encode / Begin recall) from a field',
    'K  copy the master secret ("the key")    H  halt derivation (keeps progress)',
    'X  exclude this stage & above (shorten the setup)',
    'Vault: F file path · W write/save · O open file · T blank templates',
    'In Write: Q QR · Alt+Q copy · press again to switch 128/256-bit · I own key',
    'In Open: Q scan QR · Alt+Q type key (32 or 64 hex) · Esc cancel',
    'V+↑/↓  sound volume (level 0 = muted) · Alt+V reveal/hide sensitive text',
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
  /// Memorise-mode guidance. Lives in the console (not the control panel) so the
  /// panel stays a stable, compact action surface.
  static const String _memoriseHelp =
      'Memorise your points. Stage 0 is the salt/pepper you entered; each later '
      'stage is its own fractal carrying one point. Study the marked location on '
      'every fractal until you can find it from memory, then finish — the seed '
      'is then held only in your recall.';

  /// Whether the user is studying a settled generated/imported setup (the state
  /// the [_memoriseHelp] guidance applies to).
  bool get _inMemoriseStudy =>
      _setup.phase == SetupPhase.memorise &&
      !_setup.isGenerating &&
      !_setup.isRecallSession;

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
        : _expandTarget != null
            ? 'Add stages — N new · I import · Esc cancel.'
            : _derivationStatus() ??
            focusHelp ??
            (_inMemoriseStudy ? _memoriseHelp : null) ??
            (_consoleLog.isEmpty ? 'Ready.' : _consoleLog.last);
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
              tooltip: _manualVisible ? 'Hide manual (F1)' : 'Show manual (F1)',
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
        if (_prompt == null && _expandTarget != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _expandPickerBlock(),
          ),
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _derivationBlock(),
          ),
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex == null &&
            _focusedField != null)
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
        // Memorise guidance — relocated here from the control panel so the panel
        // stays stable. Shown only when nothing more urgent is.
        if (_prompt == null &&
            _expandTarget == null &&
            _setup.derivingStageIndex == null &&
            _focusedField == null &&
            _inMemoriseStudy)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.menu_book, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(_memoriseHelp)),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
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
                  const SizedBox(height: 4),
                  _manualColumns(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The hotkey manual laid out in two columns. The lines are short and the
  /// console is wide, so a single column wasted the horizontal space and ran
  /// tall enough to scroll; splitting in half roughly halves the height and
  /// fits comfortably without scrolling.
  Widget _manualColumns() {
    final int half = (_manualLines.length + 1) ~/ 2;
    Widget column(Iterable<String> lines) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(line),
              ),
          ],
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: column(_manualLines.take(half))),
        const SizedBox(width: 20),
        Expanded(child: column(_manualLines.skip(half))),
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

          // A halted generation: its progress is preserved; offer to resume.
          if (_setup.canResume) ...<Widget>[
            const Divider(height: 32),
            _haltedNotice(),
          ],

          // Inline editor for replacing the displayed stage's point by import.
          if (_pointImportStage != null) ...<Widget>[
            const Divider(height: 32),
            _pointImportEditor(),
          ],

          // Inline editor for importing the points of an expansion's new stages.
          if (_expandImportTarget != null) ...<Widget>[
            const Divider(height: 32),
            _expandImportEditor(),
          ],

          // Truncation: delete the displayed stage and every stage above it.
          if (_setup.canTruncateFromDisplayed) ...<Widget>[
            const Divider(height: 32),
            _truncateControl(),
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
              _expandManualActive
                  ? 'Adding Stage ${_setup.displayStageIndex}/'
                      '${_expandManualTarget ?? _setup.nStages - 1} — click your '
                      'point on this fractal; the next stage then derives '
                      'automatically.'
                  : 'Recalling Stage ${_setup.displayStageIndex}/'
                      '${_setup.nStages - 1} — click your point to mark it, then '
                      'select the next stage (tab or number key) to derive it.',
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

          // Provisional-key save / load: an encrypted on-disk copy of the setup
          // for the consolidation window. Save needs a settled setup; Load is
          // offered on the config screen too (to restore one).
          if (_setup.phase == SetupPhase.idle ||
              _setup.canExportVault) ...<Widget>[
            const Divider(height: 32),
            _vaultControls(),
          ],

          const Divider(height: 32),

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
      // The source-specific input: the import builder (format toggle + field) or
      // the stages slider. Each builder returns one or more widgets, laid out in
      // a column so switching New seed / Import / Recall swaps the whole block.
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _source == _SourceMode.import
            ? _mnemonicInput()
            : _stagesInput(),
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
          child: Text(_source == _SourceMode.import
              ? (_importFormat == _ImportFormat.hex
                  ? 'Encode hex'
                  : 'Encode phrase')
              : 'Generate'),
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
    final bool hex = _importFormat == _ImportFormat.hex;
    return <Widget>[
      SegmentedButton<_ImportFormat>(
        segments: const <ButtonSegment<_ImportFormat>>[
          ButtonSegment<_ImportFormat>(
              value: _ImportFormat.words, label: Text('Words')),
          ButtonSegment<_ImportFormat>(
              value: _ImportFormat.hex, label: Text('Hex')),
        ],
        selected: <_ImportFormat>{_importFormat},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        onSelectionChanged: (Set<_ImportFormat> s) {
          setState(() {
            _importFormat = s.first;
            _mnemonic.clear(); // the two formats are not interchangeable
          });
        },
      ),
      const SizedBox(height: 8),
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
          // Hex is constrained to grouped uppercase 0-9 A-F; words are free text.
          inputFormatters: hex
              ? <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                  TextInputFormatter.withFunction(
                    (TextEditingValue o, TextEditingValue n) =>
                        n.copyWith(text: n.text.toUpperCase()),
                  ),
                ]
              : null,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText:
                hex ? 'Import hex (8 digits / stage)' : 'Import phrase (BIP39)',
            hintText: hex ? 'A1B2C3D4 …' : 'word1 word2 …',
            suffixIcon: IconButton(
              tooltip: _mnemonicHidden ? 'Show' : 'Hide',
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
    // The "what to do" guidance lives in the console now (see _memoriseHelp), so
    // the panel stays a stable, compact action surface.
    return <Widget>[
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
    // Progress now reads off the stage-tab strip (the deriving stage's box
    // fills), so this notice is just the explanatory line.
    return Text(
      'Deriving stage ${_setup.generatingStage}/$total in the background — '
      'the stages already done are ready to study now.',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  /// The halted-derivation notice: how much of the stalled stage was preserved,
  /// and a button to resume it (and the rest of the chain).
  Widget _haltedNotice() {
    final int k = _setup.haltedStage;
    final int last = _setup.nStages - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Halted at Stage $k/$last — pass ${_setup.haltedPass}/'
          '${_setup.haltedTotal} kept. Resume picks up where it stopped.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _resumeDerivation,
          icon: const Icon(Icons.play_arrow),
          label: Text('Resume Stage $k'),
        ),
      ],
    );
  }

  void _resumeDerivation() {
    _sounds.play(UiSound.select);
    _setup.resumeDerivation();
  }

  /// Provisional-key save / load: an encrypted on-disk copy of the setup, kept
  /// only across the memorisation window and destroyed at graduation.
  Widget _vaultControls() {
    final bool canSave = _setup.canExportVault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Heading + explanation live in the console (focus _Field.vault); the
        // panel keeps only the inputs and actions for a stable layout.
        _track(
          _Field.vault,
          TextField(
            controller: _vaultPath,
            focusNode: _vaultPathFocus,
            enabled: !_vaultBusy,
            maxLines: 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              labelText: 'File path  (F)',
              hintText: '/path/to/setup.gwvault',
            ),
          ),
        ),
        const SizedBox(height: 8),
        // The provisional key is entered / shown / copied only inside the
        // Write and Open dialogs — never in a panel field — so it is never an
        // idle on-screen artifact. F focuses the path; W writes; O opens; T
        // prints a blank template.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            // Always present (greyed out when there is nothing to save yet) so
            // the panel layout stays stable.
            FilledButton.icon(
              onPressed: (_vaultBusy || !canSave) ? null : _writeSetup,
              icon: const Icon(Icons.save_alt),
              label: const Text('Write (save)  (W)'),
            ),
            OutlinedButton.icon(
              onPressed: _vaultBusy ? null : _openSetup,
              icon: const Icon(Icons.lock_open),
              label: const Text('Open setup file  (O)'),
            ),
            OutlinedButton.icon(
              onPressed: _vaultBusy ? null : _exportBlankTemplate,
              icon: const Icon(Icons.print),
              label: const Text('Blank templates  (T)'),
            ),
            if (_vaultBusy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ],
    );
  }

  /// Move keyboard focus to the vault file-path field (F).
  void _focusVaultPath() => _focusField(_vaultPathFocus, 'vault file path');

  /// Whether the provisional-key panel is on screen — the config screen (to open
  /// a saved setup) or a settled setup (to write one). Gates the F/W/O/T keys.
  bool get _vaultPanelShown =>
      _setup.phase == SetupPhase.idle || _setup.canExportVault;

  /// Write (save) the settled setup to the file path, encrypted under a fresh
  /// app-generated 128-bit key, then open the key dialog (W). The key can be
  /// overridden with the user's own entropy from inside that dialog.
  Future<void> _writeSetup() async {
    if (!_setup.canExportVault) {
      _sounds.play(UiSound.denyInput);
      _toast('Finish a setup first — there is nothing to write yet.');
      return;
    }
    final String path = _vaultPath.text.trim();
    if (path.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path.');
      return;
    }
    setState(() => _vaultBusy = true);
    final ({String? error, Uint8List? key}) result =
        await _setup.saveVaultToFile(path);
    if (!mounted) return;
    setState(() => _vaultBusy = false);
    if (result.error != null || result.key == null) {
      _sounds.play(UiSound.denyInput);
      _toast(result.error ?? 'Could not save.');
      return;
    }
    _sounds.play(UiSound.exportOk);
    await _showKeyDialog(path, result.key!);
  }

  /// Open (load) a saved setup from the file path (O): scan the QR (Q) or type
  /// the 32-hex key (Alt+Q focuses the field, Enter loads), Esc to cancel. The
  /// key is never displayed.
  Future<void> _openSetup() async {
    final String path = _vaultPath.text.trim();
    if (path.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path.');
      return;
    }
    final bool canScan = _scanSupported || _desktopScanSupported;
    final TextEditingController hexInput = TextEditingController();
    final FocusNode hexFocus = FocusNode(debugLabel: 'open-hex');
    Uint8List? keyBytes;

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        void loadHex() {
          try {
            keyBytes = SetupCrypto.hexToKey(hexInput.text);
          } on FormatException catch (e) {
            _sounds.play(UiSound.denyInput);
            _toast(e.message);
            return;
          }
          Navigator.of(ctx).pop();
        }

        Future<void> scan() async {
          final Uint8List? k = await _scanKey();
          if (k == null) return;
          keyBytes = k;
          if (ctx.mounted) Navigator.of(ctx).pop();
        }

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (canScan) const SingleActivator(LogicalKeyboardKey.keyQ): scan,
            const SingleActivator(LogicalKeyboardKey.keyQ, alt: true): () =>
                hexFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(ctx).pop(),
          },
          child: Focus(
            autofocus: true,
            child: AlertDialog(
              title: const Text('Open setup file'),
              content: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      canScan
                          ? 'Q — scan the QR with the camera.  Alt+Q — type the '
                              '32-hex key instead.  Esc — cancel.'
                          : 'Alt+Q — type the 32-hex key (live scanning needs a '
                              'camera this platform does not expose).  '
                              'Esc — cancel.',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: hexInput,
                      focusNode: hexFocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLines: 1,
                      onSubmitted: (_) => loadHex(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        labelText: 'Key — 32 hex digits',
                        hintText: 'paste from your manager, then Enter',
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                if (canScan)
                  TextButton.icon(
                    onPressed: scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan (Q)'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loadHex,
                  child: const Text('Load'),
                ),
              ],
            ),
          ),
        );
      },
    );
    hexInput.dispose();
    hexFocus.dispose();
    if (!mounted || keyBytes == null) return;
    await _loadWithBytes(path, keyBytes!);
  }

  /// Scan the provisional-key QR, returning the 16 raw key bytes or null. Uses
  /// `mobile_scanner` where it has a backend, else the flutter_webrtc + zxing2
  /// desktop scanner.
  Future<Uint8List?> _scanKey() => _desktopScanSupported
      ? DesktopKeyScanner.show(context)
      : _scanWithMobileScanner();

  /// The `mobile_scanner` dialog (Android / iOS / macOS): returns the 16 raw key
  /// bytes from the QR's byte segment, or null if cancelled.
  Future<Uint8List?> _scanWithMobileScanner() async {
    Uint8List? keyBytes;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Scan provisional key'),
        content: SizedBox(
          width: 320,
          height: 320,
          child: MobileScanner(
            onDetect: (BarcodeCapture capture) {
              if (keyBytes != null || capture.barcodes.isEmpty) return;
              final Uint8List? raw = capture.barcodes.first.rawBytes;
              if (raw == null || !SetupCrypto.isValidKeyLen(raw.length)) return;
              keyBytes = Uint8List.fromList(raw);
              Navigator.of(ctx).pop();
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    return keyBytes;
  }

  /// Shared decrypt+restore from a file path and 16-byte key, wiping the key.
  Future<void> _loadWithBytes(String path, Uint8List keyBytes) async {
    setState(() => _vaultBusy = true);
    final String? err = await _setup.loadVaultFromFile(path, keyBytes);
    _wipeBytes(keyBytes);
    if (!mounted) return;
    setState(() => _vaultBusy = false);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    _sounds.play(UiSound.confirm);
    _toast('Setup loaded.');
  }

  /// After a write, present the provisional [keyBytes] for the file at [path]:
  /// reveal the byte-mode v1 QR to hand-copy (Q), copy the 32-hex key blind to
  /// the clipboard for a password manager (Alt+Q), or overwrite the key with the
  /// user's own 32-hex entropy (I focuses the field, Enter applies). Esc closes.
  /// The key is never shown as text — only as a QR or copied blind — and the
  /// in-memory copy is wiped when the dialog closes.
  Future<void> _showKeyDialog(String path, Uint8List keyBytes) async {
    Uint8List key = keyBytes;
    int keyLen = key.length; // 16 (128-bit) or 32 (256-bit)
    qr.QrImage matrix = _keyMatrix(key);
    bool showQr = false;
    bool copiedOnce = false;
    bool busy = false;
    final TextEditingController hexInput = TextEditingController();
    final FocusNode hexFocus = FocusNode(debugLabel: 'write-hex');

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setLocal) {
          void copyHex() {
            Clipboard.setData(ClipboardData(text: SetupCrypto.keyToHex(key)));
            _toast('${keyLen * 8}-bit key copied. The clipboard is not '
                'air-gapped — clear it after pasting into your manager.');
          }

          // Re-seal the file with either the user's own key or a fresh
          // [newLen]-byte generated key, overwriting the previous key + file,
          // and redraw. Shared by the 128↔256 toggle and the own-key path.
          Future<bool> reseal({Uint8List? ownKey, required int newLen}) async {
            setLocal(() => busy = true);
            final ({String? error, Uint8List? key}) r = await _setup
                .saveVaultToFile(path, providedKey: ownKey, genLenBytes: newLen);
            if (ownKey != null) _wipeBytes(ownKey);
            if (!ctx.mounted) return false;
            if (r.error != null || r.key == null) {
              setLocal(() => busy = false);
              _sounds.play(UiSound.denyInput);
              _toast(r.error ?? 'Could not save.');
              return false;
            }
            _wipeBytes(key); // drop the superseded key
            _sounds.play(UiSound.exportOk);
            setLocal(() {
              key = r.key!;
              keyLen = key.length;
              matrix = _keyMatrix(key);
              busy = false;
            });
            return true;
          }

          int otherLen() => keyLen == SetupCrypto.keyLenBytes
              ? SetupCrypto.keyLenBytes256
              : SetupCrypto.keyLenBytes;

          Future<void> applyOwnKey() async {
            Uint8List ownKey;
            try {
              ownKey = SetupCrypto.hexToKey(hexInput.text);
            } on FormatException catch (e) {
              _sounds.play(UiSound.denyInput);
              _toast(e.message);
              return;
            }
            if (await reseal(ownKey: ownKey, newLen: ownKey.length)) {
              setLocal(hexInput.clear);
              _toast('Re-saved with your own ${keyLen * 8}-bit key.');
            }
          }

          // Q reveals the QR; pressing it again switches 128↔256 (a fresh key,
          // overwriting the file). Alt+Q copies; pressing it again switches too.
          void onShowQr() {
            if (busy) return;
            if (!showQr) {
              setLocal(() => showQr = true);
            } else {
              reseal(newLen: otherLen());
            }
          }

          void onCopy() {
            if (busy) return;
            if (!copiedOnce) {
              copyHex();
              setLocal(() => copiedOnce = true);
            } else {
              reseal(newLen: otherLen()).then((bool ok) {
                if (ok && ctx.mounted) copyHex();
              });
            }
          }

          final int version = keyLen > SetupCrypto.keyLenBytes ? 2 : 1;
          return CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.keyQ): onShowQr,
              const SingleActivator(LogicalKeyboardKey.keyQ, alt: true): onCopy,
              const SingleActivator(LogicalKeyboardKey.keyI): () =>
                  hexFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(ctx).pop(),
            },
            child: Focus(
              autofocus: true,
              child: AlertDialog(
                title: Text('Provisional key — ${keyLen * 8}-bit'),
                content: SizedBox(
                  width: 340,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'Saved. Keep the key OFFLINE and destroy it at '
                          'graduation (shred / burn). Lose it and the file is '
                          'unrecoverable — that is the point.',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Q — show the QR to hand-copy onto a printed blank '
                          'template (T).  Alt+Q — copy the key for a password '
                          'manager (blind).  Press Q or Alt+Q again to switch to '
                          '${otherLen() * 8}-bit (a fresh key, overwriting the '
                          'file).  I — use your own 32- or 64-hex key (Enter).  '
                          'Esc — close.',
                          style: const TextStyle(fontSize: 11),
                        ),
                        if (showQr) ...<Widget>[
                          const SizedBox(height: 12),
                          Center(
                            child: Container(
                              color: Colors.white,
                              padding: const EdgeInsets.all(12),
                              child: CustomPaint(
                                size: const Size(252, 252),
                                painter: _QrPainter(matrix, _QrView.scan),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${keyLen * 8}-bit · QR v$version. Do this alone, no '
                            'cameras. At EC-L the code still scans with up to ~2 '
                            'stray mis-coloured cells, so work carefully.',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: hexInput,
                          focusNode: hexFocus,
                          enabled: !busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLines: 1,
                          onSubmitted: (_) => applyOwnKey(),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            labelText:
                                'Your own key — 32 or 64 hex digits (optional)',
                            hintText: 'from dice etc., then Enter to apply',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: <Widget>[
                  TextButton.icon(
                    onPressed: busy ? null : onShowQr,
                    icon: const Icon(Icons.qr_code_2),
                    label: Text(showQr ? 'Switch bits (Q)' : 'Show QR (Q)'),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : onCopy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy key (Alt+Q)'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    hexInput.dispose();
    hexFocus.dispose();
    _wipeBytes(key); // recorded or abandoned — drop our copy
  }

  /// Byte-mode QR matrix for a provisional key: v1 (21×21) for the 16-byte
  /// key, v2 (25×25) for the 32-byte 256-bit key, both at EC level L.
  qr.QrImage _keyMatrix(Uint8List key) {
    final int version = key.length > SetupCrypto.keyLenBytes ? 2 : 1;
    return qr.QrImage(
      qr.QrCode(version, qr.QrErrorCorrectLevel.L)
        ..addByteData(ByteData.sublistView(key)),
    );
  }

  static void _wipeBytes(Uint8List b) {
    for (int i = 0; i < b.length; i++) {
      b[i] = 0;
    }
  }

  /// Export both reusable **blank** hand-fill templates (the key-independent
  /// skeleton: finders, timing, dark module, the v2 alignment pattern, over a
  /// highlighted module grid) as PNGs in the vault path's folder — one per key
  /// size, named `128-bit-…` / `256-bit-provisional-key-qr-template.png` so the
  /// size leads the file name. They hold no secret; print and hand-colour.
  Future<void> _exportBlankTemplate() async {
    final String base = _vaultPath.text.trim();
    if (base.isEmpty) {
      _sounds.play(UiSound.denyInput);
      _toast('Enter a file path first; the templates save in its folder.');
      return;
    }
    final String dir = File(base).parent.path;
    final String sep = Platform.pathSeparator;
    try {
      final List<String> saved = <String>[];
      for (final int lenBytes in <int>[
        SetupCrypto.keyLenBytes,
        SetupCrypto.keyLenBytes256,
      ]) {
        final Uint8List png = await _renderBlankTemplatePng(lenBytes);
        final String name =
            '${lenBytes * 8}-bit-provisional-key-qr-template.png';
        await File('$dir$sep$name').writeAsBytes(png, flush: true);
        saved.add(name);
      }
      if (!mounted) return;
      _sounds.play(UiSound.exportOk);
      _toast('Blank templates saved in $dir: ${saved.join(', ')}');
    } catch (e) {
      if (mounted) _toast('Could not save the templates (${e.runtimeType}).');
    }
  }

  /// Render the blank hand-fill skeleton PNG for a [lenBytes]-byte key (v1 for
  /// 16, v2 for 32). A dummy all-zero key yields only the module geometry; only
  /// the key-independent cells are drawn, so it leaks nothing.
  Future<Uint8List> _renderBlankTemplatePng(int lenBytes) async {
    final qr.QrImage matrix = _keyMatrix(Uint8List(lenBytes));
    // 24 px per module, including the painter's 4-module quiet zone each side.
    final int px = (matrix.moduleCount + 2 * _QrPainter.quiet) * 24;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    _QrPainter(matrix, _QrView.blank)
        .paint(canvas, Size(px.toDouble(), px.toDouble()));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(px, px);
    final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (png == null) throw StateError('template render failed');
    return png.buffer.asUint8List();
  }

  /// Common message tail for a point edit: what gets discarded above stage [k].
  String _editTail(int k) {
    final int last = _setup.nStages - 1;
    return k < last ? ' and discard Stages ${k + 1}–$last' : '';
  }

  /// Change the displayed stage's point to fresh random entropy (the `N` edit).
  Future<void> _changePointGenerated() async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Replace Stage $k\'s point with new random entropy'
          '${_editTail(k)}? This cannot be undone.',
      confirmLabel: 'Replace',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    _setup.changeCurrentPointGenerated();
    _sounds.play(UiSound.changePoint);
    _toast('Stage $k point regenerated.');
  }

  /// Arm the manual point edit (the `R` edit): the next canvas click sets the
  /// new point for the displayed stage.
  Future<void> _changePointManual() async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Click a new point for Stage $k${_editTail(k)}? '
          'This cannot be undone.',
      confirmLabel: 'Pick new point',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    setState(() => _editPointMode = true);
    _sounds.play(UiSound.click);
    _toast('Click the new point on Stage $k (Esc to cancel).');
  }

  /// Open the inline bit editor to replace the displayed stage's point by import
  /// (the `I` edit): 3 words → 32 bits (plain I) or 8 hex digits (Alt+I). The
  /// format toggle in the editor still lets the user switch after opening.
  Future<void> _changePointImport({required bool hex}) async {
    final int k = _setup.displayStageIndex;
    final bool ok = await _consoleConfirm(
      message: 'Replace Stage $k\'s point by import${_editTail(k)}? '
          'This cannot be undone.',
      confirmLabel: 'Import',
    );
    if (!ok || !mounted || !_setup.canEditCurrentPoint) return;
    _pointImport.clear();
    setState(() {
      _pointImportFmt = hex ? _ImportFormat.hex : _ImportFormat.words;
      _pointImportStage = k;
    });
    _pointImportFocus.requestFocus();
  }

  void _applyPointImport() {
    final String text = _pointImport.text;
    final String? err = _pointImportFmt == _ImportFormat.hex
        ? _setup.changeCurrentPointHex(text)
        : _setup.changeCurrentPointWords(text);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    final int k = _setup.displayStageIndex;
    _cancelPointImport();
    _sounds.play(UiSound.changePoint);
    _toast('Stage $k point changed.');
  }

  void _cancelPointImport() {
    _pointImport.clear();
    setState(() => _pointImportStage = null);
    _focusViewer();
  }

  /// The inline editor shown while replacing a stage's point by import.
  Widget _pointImportEditor() {
    final int k = _pointImportStage!;
    return _importEditorBody(
      title: 'Import a new point for Stage $k${_editTail(k)}.',
      words: 3,
      hexDigits: 8,
      onApply: _applyPointImport,
      onCancel: _cancelPointImport,
    );
  }

  /// The inline editor shown while importing the points for an expansion's new
  /// stages: one point per added stage ([m] points → 3·m words / 8·m hex).
  Widget _expandImportEditor() {
    final int g = _expandImportTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    return _importEditorBody(
      title: 'Import $m point${m == 1 ? '' : 's'} for new '
          'Stage${m == 1 ? ' $g' : 's $firstNew–$g'}.',
      words: 3 * m,
      hexDigits: 8 * m,
      onApply: _applyExpandImport,
      onCancel: _cancelExpandImport,
    );
  }

  /// Shared inline import editor: a Words/Hex toggle, a masked field, and
  /// Apply/Cancel. [words]/[hexDigits] size the labels for the expected bit
  /// count (one point = 3 words / 8 hex; m points scale both). Reused by the
  /// single-point I edit and the multi-point import expansion (mutually
  /// exclusive, so they share [_pointImport] / [_pointImportFocus]).
  Widget _importEditorBody({
    required String title,
    required int words,
    required int hexDigits,
    required VoidCallback onApply,
    required VoidCallback onCancel,
  }) {
    final bool hex = _pointImportFmt == _ImportFormat.hex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<_ImportFormat>(
          segments: <ButtonSegment<_ImportFormat>>[
            ButtonSegment<_ImportFormat>(
                value: _ImportFormat.words, label: Text('$words words')),
            ButtonSegment<_ImportFormat>(
                value: _ImportFormat.hex, label: Text('$hexDigits hex')),
          ],
          selected: <_ImportFormat>{_pointImportFmt},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (Set<_ImportFormat> s) {
            setState(() {
              _pointImportFmt = s.first;
              _pointImport.clear();
            });
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pointImport,
          focusNode: _pointImportFocus,
          obscureText: _mnemonicHidden,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: hex
              ? <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F ]')),
                  TextInputFormatter.withFunction(
                    (TextEditingValue o, TextEditingValue n) =>
                        n.copyWith(text: n.text.toUpperCase()),
                  ),
                ]
              : null,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: hex ? '$hexDigits hex digits' : '$words words',
            hintText: hex ? 'A1B2C3D4' : 'word word word',
            suffixIcon: IconButton(
              tooltip: _mnemonicHidden ? 'Show' : 'Hide',
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
          onSubmitted: (_) => onApply(),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            FilledButton(onPressed: onApply, child: const Text('Apply')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  // --- Expansion (grow the setup with more point stages) ---------------------

  /// Open the method picker (in the console) to grow the setup to [g] point
  /// stages: New (random), Import, or Manual. No-op unless the setup can grow.
  void _beginExpand(int g) {
    if (!_setup.canExpand ||
        g < _setup.firstExpansionStage ||
        g > SetupController.maxPointStages) {
      _sounds.play(UiSound.denyBlocked);
      return;
    }
    // The expansion editors are mutually exclusive with the point-edit one.
    if (_pointImportStage != null) _cancelPointImport();
    setState(() {
      _expandImportTarget = null;
      _expandTarget = g;
    });
    _sounds.play(UiSound.navStage);
  }

  /// Expand with fresh random points for every new stage (the N method), behind
  /// a console confirmation (each new stage costs a full derivation).
  Future<void> _expandNew() async {
    final int? g = _expandTarget;
    if (g == null) return;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    setState(() => _expandTarget = null);
    final bool ok = await _consoleConfirm(
      message: 'Add $m new stage${m == 1 ? '' : 's'} '
          '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) with fresh random '
          'points? Each derives in turn (~the usual per-stage time).',
      confirmLabel: 'Add',
    );
    if (!ok || !mounted || !_setup.canExpand) return;
    _setup.expandGenerated(g);
    _sounds.play(UiSound.confirm);
    _toast('Deriving $m new stage${m == 1 ? '' : 's'} '
        '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'})…');
  }

  /// Switch from the picker to the inline import editor (the I method), in
  /// [hex] or words.
  void _expandImport({required bool hex}) {
    final int? g = _expandTarget;
    if (g == null) return;
    _pointImport.clear();
    setState(() {
      _pointImportFmt = hex ? _ImportFormat.hex : _ImportFormat.words;
      _expandTarget = null;
      _expandImportTarget = g;
    });
    _pointImportFocus.requestFocus();
  }

  void _applyExpandImport() {
    final int g = _expandImportTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    final String text = _pointImport.text;
    final String? err = _pointImportFmt == _ImportFormat.hex
        ? _setup.expandImportedHex(g, text)
        : _setup.expandImportedWords(g, text);
    if (err != null) {
      _sounds.play(UiSound.denyInput);
      _toast(err);
      return;
    }
    _cancelExpandImport();
    _sounds.play(UiSound.confirm);
    _toast('Deriving $m new stage${m == 1 ? '' : 's'} '
        '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'})…');
  }

  void _cancelExpandImport() {
    _pointImport.clear();
    setState(() => _expandImportTarget = null);
    _focusViewer();
  }

  /// The console method picker shown while an expansion target is chosen.
  Widget _expandPickerBlock() {
    final int g = _expandTarget!;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Add $m new stage${m == 1 ? '' : 's'} '
            '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) — choose how to fill '
            'the new point${m == 1 ? '' : 's'}:'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            _expandPickButton('New (N)', _expandNew),
            _expandPickButton('Import (I)', () => _expandImport(hex: false)),
            _expandPickButton('Manual (R)', _expandManual),
            _expandPickButton('Cancel (Esc)', _cancelExpand),
          ],
        ),
      ],
    );
  }

  Widget _expandPickButton(String label, VoidCallback onTap) => TextButton(
        style: TextButton.styleFrom(foregroundColor: _kConsoleFg),
        onPressed: onTap,
        child: Text(label),
      );

  void _cancelExpand() {
    setState(() => _expandTarget = null);
    _focusViewer();
  }

  /// Grow the setup by hand (the R method): derive each new stage in turn and
  /// click its point on the fresh fractal. Confirms first, grows empty stages,
  /// enables canvas selection, and derives the first new stage; each click then
  /// advances to the next ([_onCanvasSelect]).
  Future<void> _expandManual() async {
    final int? g = _expandTarget;
    if (g == null) return;
    final int firstNew = _setup.firstExpansionStage;
    final int m = g - firstNew + 1;
    setState(() => _expandTarget = null);
    final bool ok = await _consoleConfirm(
      message: 'Add $m new stage${m == 1 ? '' : 's'} '
          '(Stage${m == 1 ? ' $g' : 's $firstNew–$g'}) by hand? Each derives in '
          'turn; click your chosen point on every new fractal.',
      confirmLabel: 'Add',
    );
    if (!ok || !mounted || !_setup.canExpand) return;
    _setup.beginManualExpansion(g);
    setState(() {
      _expandManualActive = true;
      _expandManualTarget = g;
      _selectMode = true; // enable canvas point selection on the new stages
    });
    _sounds.play(UiSound.confirm);
    await _deriveNextStage(); // derive Stage firstNew; the user clicks its point
  }

  /// Leave manual-expansion mode (completed or cancelled), disabling selection.
  void _endManualExpand() {
    setState(() {
      _expandManualActive = false;
      _expandManualTarget = null;
      _selectMode = false;
    });
  }

  /// Truncation control: exclude the displayed stage and every stage above it.
  /// The explanation lives in the console (focus _Field.truncate); the panel
  /// keeps only the action button for a stable, compact layout.
  Widget _truncateControl() {
    final int k = _setup.displayStageIndex;
    return Align(
      alignment: Alignment.centerLeft,
      child: _track(
        _Field.truncate,
        OutlinedButton.icon(
          onPressed: _truncate,
          icon: const Icon(Icons.content_cut),
          label: Text('Exclude Stage $k & above (X)'),
        ),
      ),
    );
  }

  /// Exclude the displayed stage and every stage above it. Bound to the `X`
  /// hotkey and the truncate button; denies when the displayed stage cannot be
  /// truncated (Stage 0, or a not-yet-settled / recall setup).
  Future<void> _truncate() async {
    if (!_setup.canTruncateFromDisplayed) {
      _sounds.play(UiSound.deny);
      return;
    }
    final int k = _setup.displayStageIndex;
    final int last = _setup.nStages - 1;
    final String kept =
        k == 1 ? 'only the salt/pepper text' : 'Stages 0–${k - 1}';
    final bool ok = await _consoleConfirm(
      message: k == last
          ? 'Exclude Stage $k? The setup keeps $kept. This cannot be undone.'
          : 'Exclude Stages $k–$last? The setup keeps $kept. '
              'This cannot be undone.',
      confirmLabel: 'Exclude',
    );
    if (!ok || !mounted) return;
    _setup.truncateFrom(k);
    _sounds.play(UiSound.undo);
    _toast(k - 1 >= 1
        ? 'Excluded — setup now has ${k - 1} stage${k - 1 == 1 ? '' : 's'}.'
        : 'Excluded down to the salt/pepper text (no point stages).');
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
            labelText: 'Export salt (optional)',
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
        if (_importFormat == _ImportFormat.hex) {
          final int digits = _mnemonic.text.replaceAll(RegExp(r'\s'), '').length;
          if (digits == 0) {
            return 'Import hex: paste uppercase 0–9 A–F from a randomness source '
                'you trust over the device (kept hidden). 8 digits = one stage.';
          }
          if (digits % 8 != 0) {
            return 'Import hex: $digits digits — must be a multiple of 8 '
                '(8 = 32 bits = one stage).';
          }
          return 'Import hex: $digits digits → ${digits ~/ 8} stages.';
        }
        final int wc = _mnemonic.text
            .trim()
            .split(RegExp(r'\s+'))
            .where((String w) => w.isNotEmpty)
            .length;
        if (wc == 0) {
          return 'Import phrase: type or paste your existing BIP39 seed phrase '
              '(kept hidden). 3 words = one stage.';
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
            'pepper. This optional salt versions the key (e.g. SIGNING-1, '
            'uppercase/digits/hyphen). Press K to derive and copy — blind, '
            'never shown.';
      case _Field.hue:
        return 'Colour scheme: ${_hue.name}. ← → to cycle through the six hues.';
      case _Field.vault:
        return 'Provisional key: encrypt this setup to a file (AES-256-GCM) for '
            'the memorisation window — a transient crutch, not a backup; delete '
            'it at graduation. Protect it with your own password (managed/deleted '
            'in a password manager) or an app-generated key shown as a small QR '
            'to print and keep OFFLINE. The file is useless without its secret.';
      case _Field.truncate:
        final int k = _setup.displayStageIndex;
        final int last = _setup.nStages - 1;
        return k == last
            ? 'Shorten the setup by excluding this last stage (Stage $k), '
                'keeping Stages 0–${k - 1}. Cannot be undone.'
            : 'Shorten the setup: exclude Stage $k and every stage above it '
                '(Stages $k–$last), keeping Stages 0–${k - 1}. Cannot be undone.';
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
      if (_importFormat == _ImportFormat.hex) {
        await _setup.beginFromHex(
          _mnemonic.text,
          text: text,
          argon2Iterations: _iterations,
          profile: _profile,
        );
      } else {
        await _setup.beginFromMnemonic(
          _mnemonic.text,
          text: text,
          argon2Iterations: _iterations,
          profile: _profile,
        );
      }
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

  /// Halt a running derivation behind a console confirmation (the A hotkey).
  /// Kills only the current Argon2 pass; every completed intermediary digest of
  /// the working stage is kept, as are the stages already derived. No-op with a
  /// deny cue when nothing is deriving.
  Future<void> _abortDerivation() async {
    if (!_busy && !_setup.isGenerating) {
      _sounds.play(UiSound.deny);
      return;
    }
    final bool ok = await _consoleConfirm(
      message: 'Halt the running derivation? Only the current pass (~1 min) is '
          'dropped — every digest completed so far on this stage is kept, and '
          'the stages already derived stay usable.',
      confirmLabel: 'Halt',
    );
    if (ok && mounted && (_busy || _setup.isGenerating)) {
      _setup.halt();
      _toast('Halted — progress kept.');
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

/// How imported entropy is entered: BIP39 words, or blind uppercase hex (for
/// users who trust an external randomness source over the device RNG).
enum _ImportFormat { words, hex }

/// The input controls whose label + live value are conveyed in the console while
/// focused (so the panel itself can stay label-free).
enum _Field {
  stages,
  iterations,
  profile,
  salt,
  mnemonic,
  exportLabel,
  hue,
  vault,
  truncate,
}

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
/// One stage's box in the top strip. The strip doubles as the derivation
/// progress bar: each box is a stage-sized segment, so filled boxes are elapsed
/// work and empty ones are still to come.
///
/// States: **available/selected** (lit) · **deriving** (filling left→right) ·
/// **pending** — requested but not derived (grey) · **ghost** — a slot outside
/// the current setup (a hollow frame the chain can still grow into).
class _StageTab extends StatelessWidget {
  const _StageTab({
    required this.index,
    required this.inSetup,
    required this.selected,
    required this.available,
    required this.deriving,
    required this.progress,
    required this.tooltip,
    required this.onTap,
  });

  final int index;

  /// Hover label — the stage name, plus its ETA while a chain is deriving.
  final String tooltip;

  /// Whether this stage belongs to the current (or slider-previewed) setup
  /// (`index < nStages`). Out-of-setup slots render as empty ghost frames.
  final bool inSetup;

  final bool selected;
  final bool available;

  /// This stage's fractal is deriving right now: the box fills as [progress].
  final bool deriving;

  /// Fill fraction in [0, 1] while [deriving].
  final double progress;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: deriving ? _derivingFace(scheme) : _restingFace(scheme),
      ),
    );
  }

  /// A non-deriving box: ghost (out of setup), pending (grey), or lit
  /// (available / selected).
  Widget _restingFace(ColorScheme scheme) {
    if (!inSetup) {
      // Ghost: a faint hollow slot — an open quest the chain can grow into.
      return _box(
        bg: Colors.transparent,
        border: scheme.outlineVariant.withOpacity(0.25),
        fg: scheme.onSurface.withOpacity(0.15),
        bold: false,
      );
    }
    final Color fg = selected
        ? scheme.onPrimary
        : available
            ? scheme.onSurface
            : scheme.onSurface.withOpacity(0.35); // pending (requested) grey
    return _box(
      bg: selected ? scheme.primary : Colors.transparent,
      border: selected ? scheme.primary : scheme.outlineVariant,
      fg: fg,
      bold: selected,
    );
  }

  /// The deriving wipe: the left [progress] fraction shows the lit face (dark
  /// digit on the light-blue fill); the rest shows the unlit face (light digit
  /// on transparent). Painting the digit on both faces and clipping at the fill
  /// edge keeps it readable across the boundary — a late-90s scan-line reveal.
  Widget _derivingFace(ColorScheme scheme) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _box(
          bg: Colors.transparent,
          border: scheme.primary,
          fg: scheme.onSurface,
          bold: false,
        ),
        ClipRect(
          clipper: _LeftFractionClipper(progress),
          child: _box(
            bg: scheme.primary,
            border: scheme.primary,
            fg: scheme.onPrimary,
            bold: false,
          ),
        ),
      ],
    );
  }

  Widget _box({
    required Color bg,
    required Color border,
    required Color fg,
    required bool bold,
  }) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          color: fg,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontFamily: GreatWallTypography.fontFamily,
          fontFamilyFallback: const <String>['monospace'],
        ),
      ),
    );
  }
}

/// Clips a child to its left [fraction] of width — the moving edge of a stage
/// tab's derivation fill.
class _LeftFractionClipper extends CustomClipper<Rect> {
  const _LeftFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction.clamp(0.0, 1.0), size.height);

  @override
  bool shouldReclip(_LeftFractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
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

/// Paints the provisional-key QR. In **scan** mode it draws the plain scannable
/// code (solid black/white modules) — what the user reveals to hand-copy or to
/// scan back. In **blank** mode it draws the reusable hand-fill skeleton: only
/// the key-independent cells (the three finder patterns + separators, the timing
/// patterns, and the dark module) are inked, every cell sits in a clearly drawn
/// grid so the user can see exactly which squares to colour, and the data/EC
/// cells are left empty to fill in by reading the scan code. (Byte-mode v1 has
/// no alignment patterns.) Both views include the spec's 4-module quiet zone.
class _QrPainter extends CustomPainter {
  _QrPainter(this.image, this.view);

  final qr.QrImage image;
  final _QrView view;

  /// QR spec mandates a clear margin of at least 4 modules around the symbol;
  /// without it decoders often fail to lock onto the finder patterns.
  static const int quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = image.moduleCount; // 21 for version 1
    final double cell = size.width / (n + 2 * quiet);
    final double off = quiet * cell; // top-left offset of the symbol proper
    final Paint inked = Paint()..color = Colors.black;
    // A visible grid so the hand-filler can tell the module divisions apart.
    final Paint grid = Paint()
      ..color = const Color(0xFF9E9E9E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        final Rect rect = Rect.fromLTWH(off + c * cell, off + r * cell, cell, cell);
        final bool dark = image.isDark(r, c);
        switch (view) {
          case _QrView.scan:
            if (dark) canvas.drawRect(rect, inked);
          case _QrView.blank:
            // Key-independent skeleton only — the user inks the rest by hand,
            // reading the scan code, guided by the highlighted module grid.
            if (dark && _isFixed(r, c, n)) canvas.drawRect(rect, inked);
            canvas.drawRect(rect, grid);
        }
      }
    }
  }

  /// Key-independent modules: the three 8×8 finder+separator corners, the timing
  /// rows/cols, the dark module, and (at v2, n == 25) the single 5×5 alignment
  /// pattern centred at (n-7, n-7). v1 has no alignment pattern.
  bool _isFixed(int r, int c, int n) {
    bool corner(int r0, int c0) =>
        r >= r0 && r < r0 + 8 && c >= c0 && c < c0 + 8;
    if (corner(0, 0) || corner(0, n - 8) || corner(n - 8, 0)) return true;
    if (r == 6 || c == 6) return true; // timing patterns
    if (r == n - 8 && c == 8) return true; // dark module
    if (n >= 25) {
      final int a = n - 7; // alignment-pattern centre (18 at v2)
      if ((r - a).abs() <= 2 && (c - a).abs() <= 2) return true; // 5×5 ring
    }
    return false;
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.view != view;
}

/// How [_QrPainter] renders: the plain scannable code, or the reusable blank
/// skeleton (only the key-independent cells, over a highlighted module grid,
/// printed for hand-colouring).
enum _QrView { scan, blank }
