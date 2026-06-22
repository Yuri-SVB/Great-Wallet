# great-wallet / app

The unified app's own UI and orchestration — **not a submodule** (it is the
one source tree great-wallet owns directly; the six libraries are flat
submodules around it). See
[`great-wall-docs/great-wallet/ARCHITECTURE.md`](../great-wall-docs/great-wallet/ARCHITECTURE.md)
§"7. great-wallet".

This pass implements **Setup** — the first of the four modes — by integrating
**great-wall-core** (the fractal encoder engine) with **great-wall-ux** (the
rendering / interaction layer).

## What the integration does

great-wall-ux deliberately does **not** compute fractals; it defines an
`EscapeCountSource` seam and leaves the engine to a consuming app
(`SCOPE.md`, dependency-matrix row `great-wall-ux → great-wall-core`). This app
supplies the production implementation of that seam and the Setup orchestration:

| Concern | File | Notes |
|---|---|---|
| C ABI binding to the Rust engine | `lib/src/ffi/core_bindings.dart` | Dart port of the Python `ctypes` bridge (`burning_ship_engine.py`): render, encode, `decode_full`, `argon2_single`. |
| Library discovery | `lib/src/ffi/library_loader.dart` | Finds `libburning_ship_engine` next to the exe or in the submodule's cargo output. |
| I4F60 fixed-point | `lib/src/ffi/fixed.dart` | Coordinates cross the FFI as raw `i64`, never floats (determinism). |
| **The UX seam** | `lib/src/core/core_escape_count_source.dart` | `EscapeCountSource` → engine. Maps the viewport to the raster call and converts the engine's `u8` buffer to the UX `Uint32List`. Renders **every** stage through the perturbed path (`escape_count_generic`) — the canonical stage 0 as `(0,0,0)` — because that is the formula `bs_encode` uses (it applies p's +1/8 baseline even at `(0,0,0)`); the pure-canonical `bs_render_viewport` would draw a different fractal and the points would appear to fall in the canonical hole. |
| `(o,p,q)` derivation | `lib/src/core/stage_params.dart` | `sha256(argon2_digest)` split into three `u64` reservoirs — port of `derive_stage2_params` (per-stage attribution, unchanged under the chained protocol). |
| Encode / decode / Argon2 facade | `lib/src/core/great_wall_core.dart` | One engine instance, shared `EscapeCountSource`. |
| Setup state machine | `lib/src/setup/setup_controller.dart` | Generate entropy → for each chained stage, derive its fractal from all preceding points (stage 0 canonical) and encode its one 32-bit point → memorise → wipe. |
| Setup screen | `lib/src/setup/setup_screen.dart` | Wires `FractalCanvas`, `HueWheel`, brightness, overlays. |

### The chained pipeline, end to end

Each stage carries exactly one 32-bit point (`nStages = entropyBits / 32`).
Stage 0 is the public canonical fractal; every later stage's fractal is the
memory-hard hash of *all preceding points*, so it cannot be formed until those
points are fixed (one stage = one fractal = one haystack; one point = one
needle).

```
random entropy ──split into 32-bit chunks (one per stage)──┐
                                                           │
stage 0:  encode chunk0 (o=p=q=0)  ───────────────→ point P0   (canonical fractal)
for k = 1 .. n-1:
   θ_k = SHA-256(Argon2^N(points P0..P_{k-1})) → (o,p,q)_k
   stage k:  encode chunk_k (o,p,q)_k ───────────→ point Pk    (perturbed fractal)

P0 ‖ P1 ‖ … ‖ P_{n-1}  →  entropy (32·n bits)  →  BIP39 mnemonic
```

Setup is *write-only on the user's memory*: the plaintext entropy is generated,
encoded onto the fractal as points to memorise, then wiped
(`ARCHITECTURE.md` §"Invariants"). Nothing is persisted or logged.

## Known seam gap

great-wall-ux's `StageParameters` carries three `double`s, but the engine's
perturbation is three raw `u64` reservoirs that don't fit losslessly in a
double. The app therefore keeps the authoritative reservoirs on
`CoreEscapeCountSource` and uses `StageParameters` only as a non-secret repaint
key. Widening the UX seam to carry the raw reservoirs is a sensible follow-up;
until then this is the minimal bridge that leaves the library untouched.

## Build & run

```bash
# from great-wallet/
git submodule update --init great-wall-core great-wall-ux great-wall-docs

# 1. Build the engine the FFI layer loads
app/native/build_core.sh

# 2. Run the app (desktop-first, per TECH_STACK.md)
cd app
flutter pub get
# one-time: generate the platform runner. Pass --org so the application id is
# not the Flutter default "com.example.*" (that id shows up in OS dialogs and
# window classes).
flutter create --platforms=linux --org org.greatwall --project-name great_wallet .
flutter run -d linux                 # or macos / windows
```

Only the Dart sources and project metadata are committed; the generated
platform runners (`linux/`, `macos/`, `windows/`, `build/`, `.dart_tool/`) are
produced by `flutter create` / `flutter pub get` and are git-ignored. The
`--org` flag above sets the application id (e.g. `org.greatwall.great_wallet`);
without it the runner is scaffolded as `com.example.great_wallet`.

If the engine library is missing, the app shows an actionable screen instead of
crashing.

## Test

```bash
cd app
flutter test
```

Pure-logic tests cover the parts that don't need a GPU or the engine: the
`u8`→count conversion and row flip, the `(o,p,q)` derivation (checked against
the great-wall-core reference vector), the entropy bit-packing, and the
I4F60 scale.
