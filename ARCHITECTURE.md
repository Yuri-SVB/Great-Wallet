# Great Wall Ecosystem — Multi-Repo Architecture

This document describes the repository structure, dependency graph,
naming conventions, cryptographic design, security model, and
inheritance protocol of the Great Wall ecosystem. It is written for
**collaborators and auditors**.

For an end-user overview of what Great Wallet is and how it is used,
see [README.md](./README.md).

---

## Overview

The ecosystem consists of seven repositories. Six are **libraries**
(no submodules, no dependencies on each other at the git level) and
one is the **app** that integrates everything. The naming blends
Chinese cultural motifs with a phoenix sub-theme for inheritance.

| # | Repo                        | Motif                      | Role                                      | Status          |
|---|-----------------------------|----------------------------|-------------------------------------------|-----------------|
| 1 | **great-wall-core**         | The Wall                   | Fractal encoder engine (Rust + Python)    | Beta (public)   |
| 2 | **tlp-core**                | (utility)                  | RSW time-lock puzzle library              | In development  |
| 3 | **great-wall-ux**           | The Wall's appearance      | Rendering, palettes, interaction, effects | In development  |
| 4 | **celestial-peace-nf-core** | Gate of Celestial Peace    | Spaced-repetition training logic (Anki)   | In development  |
| 5 | **jade-clock**              | Imperial timekeeping       | LN marketplace client for TLP solving     | In development  |
| 6 | **phoenix-scroll**          | Phoenix rebirth            | Inheritance protocol (LN + taproot)       | In development  |
| 7 | **great-wallet**            | Wall + wallet (pun)        | Unified end-user app                      | In development  |

Only `great-wall-core` is currently public. Everything marked
*In development* is non-public work-in-progress and may change
substantially before first release.

---

## Naming Conventions

- **Great Wall** — the core cryptographic system. Coercion-resistant
  seed storage via fractal encoding + Argon2 time-gating.
- **Celestial Peace: Never Forget (CPNF)** — the training companion.
  Named after the Gate of Celestial Peace (Tiananmen). The "NF" suffix
  ("Never Forget") avoids the cursed acronym "CP".
- **Jade Clock** — the Lightning Network marketplace for anonymous
  TLP-solving. Named after the jade clepsydra (ancient Chinese water
  clock). Chosen for brevity (2 syllables) so it combines cleanly with
  qualifiers: "Jade Clock client", "Jade Clock server",
  "Jade Clock market".
- **Phoenix Scroll** — the inheritance protocol. The phoenix's
  death-and-rebirth cycle mirrors the rotation mechanism (each
  rotation is a small rebirth; cessation triggers true succession).
  The scroll is the testament the phoenix carries across generations.
  Combines cleanly: "Phoenix Scroll channel", "Phoenix Scroll
  protocol", "Phoenix Scroll watchtower".
- **Great Wallet** — the unified app. A pun on Great Wall + wallet.

---

## Dependency Graph

```
great-wall-core          (no submodules)
tlp-core                 (no submodules)
great-wall-ux            (no submodules)
celestial-peace-nf-core  (no submodules)
jade-clock               (no submodules)
phoenix-scroll           (no submodules)

great-wallet             (six submodules, flat — the only repo with submodules)
  great-wall-core/
  tlp-core/
  great-wall-ux/
  celestial-peace-nf-core/
  jade-clock/
  phoenix-scroll/
  app/
```

### Submodule Rules

1. **Only the app repo (great-wallet) has submodules.** Library repos
   have zero submodules.
2. **No nested submodules.** Ever. All submodules in great-wallet are
   flat (one level deep).
3. **Version pinning is the app's responsibility.** great-wallet pins
   each library to a specific commit hash. Libraries declare
   dependencies on each other at the import/build level, but
   great-wallet ensures all six are at compatible versions.
4. **Libraries may depend on each other at the API level** (e.g.,
   great-wall-ux imports from great-wall-core, celestial-peace-nf-core
   imports from tlp-core) but never via submodules — the consuming app
   provides all libraries.

### Dependency Matrix

Which libraries does each library import from?

| Library                  | Imports from                          |
|--------------------------|---------------------------------------|
| great-wall-core          | (none)                                |
| tlp-core                 | (none)                                |
| great-wall-ux            | great-wall-core                       |
| celestial-peace-nf-core  | great-wall-core, tlp-core             |
| jade-clock               | tlp-core                              |
| phoenix-scroll           | tlp-core                              |

---

## Two-Stage Pipeline

Great Wall's fractal encoder operates in two sequential stages. The
two-stage split is what gives the system its defense-in-depth
properties and underlies the vocabulary (*stage-1 bits*, *stage-2
fractal*, *o, p, q*) used throughout this document.

### Stage 1 — canonical fractal

- **Fractal used:** the canonical Burning Ship fractal. Its parameters
  are fixed constants of the protocol; no stored state is needed to
  render it.
- **Input from the user:** tacit recall of the stage-1 locations the
  user learned at setup.
- **Output:** *stage-1 bits*, a user-derived share of entropy
  extracted by decoding the user-identified points through the
  bisection algorithm.
- **Offline-reproducible:** yes. The user (and only the user) can
  reconstruct stage-1 bits from memory alone, on any machine, without
  any stored data.

Because stage-1 uses the canonical fractal, stage-1 bits are the
entry point: every downstream secret — the stage-2 fractal's
perturbation parameters, vault keys, inheritance keys — is gated by
them.

### Stage 2 — perturbed fractal

- **Fractal used:** a user-specific *perturbation* of the Burning
  Ship fractal, parameterised by three numbers `(o, p, q)`. A
  different `(o, p, q)` produces a visually different landscape, so
  stage-2 is personal to each user.
- **Where `(o, p, q)` comes from:** `(o, p, q) = Argon2(stage-1 bits)`.
  The perturbation parameters are the deterministic output of a
  heavy Argon2 pass keyed by stage-1 bits. They are not memorised,
  and in regular operation are never shown to the user — they exist
  only as ephemeral state inside the app during a rendering session.
  Argon2's intentional slowness is what makes *rendering the stage-2
  fractal at all* a gated operation.
- **Input from the user:** tacit recall of the stage-2 locations the
  user learned at setup, rendered on that perturbed fractal.
- **Output:** *stage-2 bits*, which combined with stage-1 bits give
  the full BIP39 entropy (see *Key Derivation* below).

### How the two stages lock together

- **Vault as TLP-gated shortcut, not a primary store.** Without
  stage-1 recall, the Argon2 pre-image is unavailable, so
  `(o, p, q)` cannot be computed and the stage-2 fractal cannot
  even be rendered — let alone solved. `celestial-peace-nf-core`'s
  **vault** holds the already-computed `(o, p, q)`, the encoded
  stage-2 points, and the SM-2 scheduler state, encrypted under a
  key derived from stage-1 bits and sealed with an RSW time-lock
  puzzle (TLP). A legitimate user who has lost the vault can always
  fall back to Argon2 re-derivation from memory; the vault is a
  time-discounted shortcut for returning users, never the root of
  trust.
- **An attacker learns nothing from the vault.** They face both the
  stage-1 recall barrier (tacit, non-transmissible) and, on top of
  it, the TLP delay.

Sealing the vault with an RSW TLP — as opposed to any coarser
time-lock — buys four properties that are hard to replicate with any
other primitive:

1. **Per-session tunable security/convenience trade-off.** Each
   time the user exits a practice session, they choose the TLP
   duration for the *next* session: shorter if they expect to come
   back soon, longer if they want more time-cost to stand between
   an attacker and the vault until then. The trade-off is dialled
   afresh at every session boundary.

2. **Exact-fit spaced-repetition gating.** SM-2 dictates precise
   review intervals (hours, days, weeks, months). Because RSW TLP
   *setup* is O(1) in the chosen delay, the vault's seal can be
   dialled to exactly match the next scheduled review — no
   rounding down for crypto convenience, no bolted-on minimum
   duration. The training phase therefore runs at the theoretical
   maximum security SM-2 allows for.

3. **Paid time-barrier resolution without loss of self-custody.**
   RSW TLP solving is outsourceable: the `jade-clock` marketplace
   can solve the puzzle on the user's behalf for a Lightning
   payment. The TLP-gated ciphertext — the vault itself — never
   leaves the user's device. What the marketplace receives is only
   the TLP *setup*: the operand to be repeatedly squared and the
   RSW modulus `N`. It returns the raw solution and learns nothing
   about what that solution unlocks (or about the user's identity).
   The user gets time back without giving up custody.

4. **Integrity-checkable computation via milestones.** An RSW TLP
   solution is a long chain of iterative modular squarings:
   `x, x², x⁴, …, x^(2^t)`. At setup time — while φ(n) is still
   known — the puzzle constructor can cheaply (O(1)) precompute a
   digest of the intermediate value `x^(2^k)` at any chosen `k`.
   These **milestones** are kept private to the client; they are
   never shared with the solver. The client checks them offline
   after the solver returns. If a milestone disagrees with the
   delivered result, the client has self-contained evidence of the
   discrepancy — the original request `(N, x, t)`, the expected
   milestone digest, and the obtained result — which it presents
   to an arbiter to adjudicate whether the solver cheated,
   whether the client is repudiating honest work, or whether a
   computation error occurred mid-solve. No party has to re-run
   the full t-squaring to resolve the dispute.

   In effect, `M` milestones slice a single t-squaring puzzle into
   `M` sub-puzzles of `t/M` squarings each, diluting risk for both
   sides: any dispute localises to one segment (only that segment
   needs arbitration), and payments can be staged per milestone so
   neither client nor solver is ever exposed for more than `1/M`
   of the job at a time.

### Determinism guarantees

All stage-1 and stage-2 encoding/decoding paths must be bit-exact
across platforms, compilers, and releases. Any drift in the bisection
algorithm, PRNG, contraction arithmetic, or BFS neighbor order breaks
the bijection and invalidates existing encodings.

This is why `great-wall-core`'s determinism-critical code lives in
Rust and uses a custom **I4F60** fixed-point type instead of floating
point.

- **I4F60** is a 64-bit signed fixed-point format laid out as **1
  sign bit + 3 integer bits + 60 fractional bits**.
- It represents values in the half-open interval **[-8, +8)** with
  uniform precision **2⁻⁶⁰** (≈ 8.67 × 10⁻¹⁹).
- The tight range is deliberate: the Burning Ship fractal's
  non-escape region fits well within this box, and the narrower
  range buys more fractional bits — and therefore more precision —
  than a wider signed type of the same width would.
- Unlike IEEE-754 floats, I4F60 arithmetic has no platform-dependent
  rounding modes, no denormals, and no NaNs; results depend only on
  the input bit patterns and the specified operation, which is
  exactly what the bijection requires.

---

## Key Derivation

Every coercion-resistant secret in the Great Wall ecosystem —
spending keys, inheritance channel keys, vault keys, fallback
addresses, and any application-specific secret the user cares to
protect — is derived from a single user-held root whose entropy
is held only as tacit fractal recall.

```mermaid
flowchart TD
    R1["tacit recall<br/>(stage-1 points on canonical fractal)"] --> S1["stage-1 bits"]
    S1 --> A["Argon2<br/>(heavy, tunable)"]
    A --> OPQ["(o, p, q)"]
    OPQ --> F2["stage-2 fractal<br/>(user-specific perturbation)"]
    F2 --> R2["tacit recall<br/>(stage-2 points on that fractal)"]
    R2 --> S2["stage-2 bits"]
    S1 --> C["concat<br/>stage-1 || stage-2"]
    S2 --> C
    C --> E["raw entropy<br/>(128 or 256 bits)"]
    E --> B["BIP39 mnemonic<br/>(wire format for wallet<br/>interoperability; user<br/>never sees it)"]
    E --> OTH["any other 128/256-bit<br/>representation"]
    B --> P["PBKDF2-HMAC-SHA512<br/>(BIP39 stretching)"]
    P --> M["GW master secret<br/>(512-bit BIP39 seed)"]
    M --> X["BIP32 master xpriv"]
    M --> HA["hash(master_secret || salt_A)"]
    M --> HN["hash(master_secret || salt_N)"]
    X --> SP["spending keys"]
    X --> CH["channel keys<br/>(phoenix-scroll, per epoch)"]
    X --> FB["fallback keys<br/>(opaque taproot leaves)"]
    HA --> APA["app-specific secret A<br/>(e.g. password-manager<br/>master password)"]
    HN --> APN["app-specific secret N<br/>(any other coercion-<br/>resistant credential)"]
```

### Notes on the representation

- **BIP39 is a wire format, not the secret.** The mnemonic exists
  so the result can be pasted into any standard BIP39 wallet
  unchanged. It is the same entropy as the raw `stage-1 ||
  stage-2` bits, just in a human-readable encoding. The user never
  sees it either.
- **Derivation of non-Bitcoin secrets is built in.** `great-wall-core`
  already implements `hash(master_secret || salt)`-style derivation
  so that additional coercion-resistant secrets — passwords,
  signing keys, encryption keys for other systems — can be derived
  from the same fractal recall without rotating the fractal.
  Domain separation is by salt. A natural example is a master
  password for an off-the-shelf password manager: a single salted
  digest such as `hash(master_secret || "password-manager/v1")`
  yields a high-entropy string the user can paste into the
  manager's unlock field and never has to memorise — the manager
  itself keeps per-site credentials, and the one string that gates
  them inherits Great Wall's coercion-resistance for free.

### Invariants

- **The master secret is never shown to the user.** Raw entropy,
  mnemonic, 512-bit seed, xpriv, and all derived keys exist only as
  ephemeral state inside the app during a recall session.
  Memorising any explicit part would turn that part into
  verbalizable knowledge — coercible, and therefore outside TKBA's
  protection.
- **Setup is a write-only operation on the user's memory.** At
  setup the app generates a fresh entropy root, encodes it onto
  the user's fractal, then destroys the plaintext. The user leaves
  setup with tacit recall only — there is no mnemonic backup to
  write down, and none to lose.
- **Every participant should be a full GW user.** Testator, heirs, 
  and cascading heirs each can and should have their own independent
  fractal and entropy root. This keeps every leaf of the inheritance
  tree equally coercion-resistant: coercing any one party does not
  weaken anyone else's custody, and a successful inheritance event
  does not downgrade the security of the funds that pass through
  it.
- **All downstream keys are stateless.** Channel keys are derived
  deterministically from `(master_secret, derivation path, epoch
  number)`. Vault keys are derived from stage-1 bits.
  Application-specific secrets are derived from
  `(master_secret, salt)`. No derived key is ever stored long-term;
  losing a device loses no secrets.

---

## Repo Descriptions

### 1. great-wall-core

**Status:** Beta (public).

**The fractal encoder engine.** Bijective mapping between BIP39 mnemonic
seeds and Burning Ship fractal locations, with Argon2-based two-stage
pipeline. All determinism-critical computation is in Rust (I4F60
fixed-point arithmetic). Python FFI bridge via ctypes.

Key contents:
```
burning_ship/
  rust_engine/              Rust core (fractal, bisection, Argon2)
  burning_ship_engine.py    Python ctypes bridge
  bip39.py                  BIP39 mnemonic <-> bit conversion
  constants.py              Configuration, size presets
  encoding.py               BIP39 <-> fractal encode/decode orchestration
```

This repo must be treated with extreme care. Any change to the
bisection algorithm, PRNG, contraction arithmetic, or BFS neighbor
order breaks the deterministic bijection and invalidates all existing
encodings.

### 2. tlp-core

**Status:** In development.

**RSW time-lock puzzle library.** Pure cryptographic utility — no
dependency on any other repo in the ecosystem.

Responsibilities:
- RSA modulus generation
- TLP encryption (fast path via phi(n))
- TLP solving (sequential repeated squaring)
- Solution verification
- Puzzle serialization format
- Device speed calibration (squarings/sec measurement)

Why RSW TLP and not Argon2 for this role: RSW TLP allows for instant O(1) 
setup of puzzle of arbitrary time difficulty to cryptographically gate an
existing key, while numerous Argon2 iterations impose time for 
deterministic key derivation.

### 3. great-wall-ux

**Status:** In development.

**Rendering, palettes, and interaction layer.** Separated from
great-wall-core so that visual polish (color schemes, lighting effects,
leaf-area highlighting) and porting to different platforms/frameworks
does not touch the engine.

Responsibilities:
- Fractal rendering (viewport, zoom, pan)
- Color schemes and escape-count transforms
- Bisection area visualization (gated by debug mode, since this is 
  explicit knowledge whose memorization undermines TKBA) 
- Point markers and crosshairs
- Input handling (mouse, keyboard)
- Platform abstraction for portability (pygame today, potentially
  web/mobile in the future)

Imports from great-wall-core at the API level (calls the Rust engine
for escape counts, encode/decode). Does NOT submodule great-wall-core —
the consuming app provides both.

### 4. celestial-peace-nf-core

**Status:** In development.

**Spaced-repetition training logic.** Implements the "Celestial Peace:
Never Forget" training system that helps users consolidate tacit memory
of their fractal locations.

Responsibilities:
- SM-2 spaced repetition scheduler (Anki-like)
- Practice session orchestration and grading
- Vault format (serialization of stage-2 parameters, encoded points,
  scheduler state)
- Vault encryption/decryption (via tlp-core)
- Background TLP solver management with checkpointing

#### Core Concept

The user needs to practice recalling their fractal locations to
consolidate tacit memory. Between practice sessions, the saved
second-stage data (fractal parameters o, p, q and encoded points) is
encrypted under a TLP whose duration equals the Anki-scheduled interval
until next review.

Key properties:
- **TLP is gated by stage-1 bits.** The user must demonstrate stage-1
  recall (tacit knowledge) to unlock the vault. Without stage-1 bits,
  the vault is unconditionally sealed.
- **TLP duration < Argon2 duration, always.** TLP longer than Argon2
  is pointless because Argon2 re-derivation is always available to
  someone who knows stage-1 bits. TLP provides a time-discounted
  re-entry for legitimate users.
- **TLP duration grows with mastery.** Early sessions use short TLPs
  (hours). As the user's recall improves, intervals lengthen
  (days, weeks). Security of the stored data increases in lockstep
  with the user's decreasing need for it.
- **Graduation = green light.** Once memory consolidation is
  confirmed by the feature, app tells user it's now safe to use system
  to secure stash (risk of loss by forgetting became negligible).
  Regular maintenance reviews are still done following SM-2 doctrine.
- **Inheritance.** Deadlock by death, memory loss, or mental
  incapacitation is still guarded by companion inheritance protocol.

#### Practice Session Flow

```
Background TLP computation completes
  |
  v
App notifies user: "Practice session available"
  |
  v
STAGE 1 RECALL (canonical fractal, no stored data needed)
  User identifies stage-1 points -> decode_full() -> stage-1 bits
  |
  v
Stage-1 bits unlock TLP -> vault decrypted
  |
  v
STAGE 2 RECALL (perturbed fractal using stored o, p, q)
  User identifies stage-2 points -> decode_full() validates
  |
  v
Grade performance -> Anki scheduler -> next interval
  |
  v
New TLP generated (gated by stage-1 bits, new duration)
Vault re-encrypted, cleartext discarded
Begin background TLP computation
```

#### Grading Criteria

| Grade    | Meaning                                    | Effect on interval        |
|----------|--------------------------------------------|---------------------------|
| Again    | Failed to locate one or more points        | Reset to minimum          |
| Hard     | Found points but many attempts / hesitation | Interval x 1.2           |
| Good     | Found points with reasonable confidence    | Interval x ease_factor   |
| Easy     | Identified points immediately              | Interval x ease_factor x 1.3 |

Imports from great-wall-core (encode/decode for validation) and
tlp-core (TLP encrypt/decrypt/solve).

### 5. jade-clock

**Status:** In development.

**Lightning Network marketplace client for anonymous TLP solving.**
Allows users to outsource TLP computation to a marketplace of solvers,
paying via Lightning Network for anonymity.

Responsibilities:
- LN transport layer for marketplace messaging
- TLP job packaging and submission
- Solution retrieval and verification
- Order matching / bid logic
- Anonymity guarantees (onion routing, payment unlinkability)

Imports from tlp-core (TLP format, serialization, verification). Does
NOT depend on great-wall-core — it only needs to understand TLP
puzzles as opaque payloads, not fractal encoding.

Note: jade-clock's LN usage is transactional (submit job, pay, get
solution). The inheritance protocol's very different LN usage pattern
(decades-long dedicated channels with custom lockscripts) lives in
phoenix-scroll.

### 6. phoenix-scroll

**Status:** In development.

**Inheritance protocol.** Dead-man's switch bequest mechanism using
dedicated LN channels with TLP-gated lockscripts and recursive taproot
fallback trees. See the "Inheritance Protocol" section below for the
full design.

Responsibilities:
- Dedicated private LN channel management (long epochs, no routing)
- Deterministic channel key derivation from GW master secret
- Rotation logic (dead-man's switch driver)
- TLP-gated commitment transaction construction
- Taproot fallback tree construction (opaque addresses, recursive
  cascading inheritance)
- Heir-side monitoring and claim orchestration
- Channel watchtower (fraud detection during long punishment windows)
- Will parameter management (heirs, proportions, updates)
- Fee management at claim time (CPFP via anchor outputs,
  SIGHASH_ANYONECANPAY)

Imports from tlp-core. Does NOT depend on jade-clock — though both are
LN-adjacent "jade-*/phoenix-*" libraries wrapping tlp-core, they serve
fundamentally different interaction patterns with LN. Does NOT depend
on great-wall-core — inheritance only needs keys and TLP primitives,
which are derived/provided at the app layer.

### 7. great-wallet

**Status:** In development.

**The unified end-user application.** Integrates all six libraries
into a single app with four modes that flow naturally:

1. **Setup** — encode seed on fractal
   (great-wall-core + great-wall-ux)
2. **Train** — spaced repetition with TLP-gated practice
   (celestial-peace-nf-core + tlp-core + great-wall-ux)
3. **Accelerate** — outsource TLP solving via Lightning Network
   (jade-clock + tlp-core)
4. **Inherit** — configure and maintain inheritance channels
   (phoenix-scroll + tlp-core)

This is the only repo with submodules (all six libraries, flat).

```
great-wallet/
  great-wall-core/            <- submodule
  tlp-core/                   <- submodule
  great-wall-ux/              <- submodule
  celestial-peace-nf-core/    <- submodule
  jade-clock/                 <- submodule
  phoenix-scroll/             <- submodule
  app/                        Unified UI and orchestration
```

---

## The Four Properties

Great Wall provides four properties simultaneously:

1. **Knowledge-Based Authentication.** Your secret lives entirely in
   your memory — no device, physical vault, or geographic location
   required.
2. **Individual Custody.** You depend on no one else. The core premise
   of Bitcoin — full self-custody — is kept intact.
3. **Non-Obscurity.** The method is not a secret trick that fails the
   moment an attacker learns about it. Nor does it rely on convincing
   the attacker that the stash doesn't exist or is smaller than it
   really is.
4. **Coercion-Resistance.** The threat of violence is ineffective as a
   means to obtain the secret leading to the stash.

> **In one sentence:** it's all in your head (1), in nobody else's (2),
> the attacker is aware of that (3), and is nevertheless unable to rob
> it (4).

### Tacit Knowledge-Based Authentication (TKBA)

The four properties are logically coupled. A secret that is held only
in the owner's head (1), held by nobody else (2), and known to an
attacker to be there (3) can resist coercion (4) only if the secret
is *not transmissible* — it cannot be articulated, written down, or
extracted under duress, even by an attacker who fully understands the
protocol. By definition, such knowledge is **tacit**.

Great Wall is therefore an implementation of **Tacit Knowledge-Based
Authentication (TKBA)**. This is the theoretical basis of the system,
not an implementation detail: any design decision that replaces tacit
recall with explicit, verbalizable knowledge undermines TKBA and
weakens property 4. (For example, `great-wall-ux` gates bisection-area
visualization behind debug mode because surfacing it in normal use
would teach the user explicit facts whose memorization is coercible.)

TKBA additionally requires that the *interface* for deploying the
secret is cryptographically gated by an inescapably lengthy
computation — otherwise an attacker could repeatedly prompt "try
again" under duress until the secret leaks. In Great Wall this
gating is Argon2 (primary derivation) and, optionally, RSW time-lock
puzzles for instant setup of arbitrary, user-defined delay.

---

## Security Model Summary

| Threat                        | Mitigation                                                    |
|-------------------------------|---------------------------------------------------------------|
| Device theft (vault present)  | Vault is TLP-encrypted AND gated by stage-1 bits              |
| Device theft (vault absent)   | No stored state — nothing to steal                            |
| Coercion ($5 wrench attack)   | Tacit knowledge cannot be verbalized; stage-2 fractal         |
|                               | cannot be materialized before derivation or TLP (if present)  |
| Owner death/incapacitation    | Inheritance protocol: TLP-gated channel stops rotating,       |
|                               | heir claims after epoch + grace period                        |
| Cascading deaths              | Opaque fallback addresses propagate inheritance recursively   |
| Malicious LN counterparty     | Long `to_self_delay` aligned to TLP epoch; heir monitors      |
| LN infrastructure disappears  | TLP blobs are self-contained; fallback transport possible     |

---

## Inheritance Protocol (phoenix-scroll)

The inheritance protocol, implemented in **phoenix-scroll**, allows a
testator to bequeath Bitcoin to heirs using a dead-man's switch: the
testator periodically rotates TLP-gated inheritance channels. When
rotation stops (death or incapacitation), the most recent TLP
eventually unlocks and the heir claims the funds.

The phoenix metaphor: each rotation is a small death-and-rebirth of
the channel commitment. When rotation ceases for the last time, the
true succession occurs — the heir rises from the ashes.

### Statefulness Boundary

The owner's **own access** to their funds remains fully stateless —
tacit recall + Argon2, no device needed. The four properties hold for
the primary use case.

Inheritance is an **opt-in stateful extension** that adds operational
obligations (periodic rotation, LN channel maintenance) for the benefit
of heirs. The information itself remains stateless: both testator's and
heir's channel keys are deterministically derived from their respective
GW master secrets. Losing a device means re-deriving keys from memory
and reconstructing state from the chain.

The only genuinely new obligation is **liveness**: a process must
broadcast periodically. The knowledge required to do so is still all
in the testator's head.

### Dedicated Inheritance Channels

Inheritance uses **dedicated, private LN channels** that are not part
of the routing graph. These channels have fundamentally different
parameters from payment channels:

| Parameter          | Payment channel    | Inheritance channel         |
|--------------------|--------------------|-----------------------------|
| Typical lifetime   | Days to months     | Years to decades            |
| Closure urgency    | Minutes to hours   | Months is acceptable        |
| `to_self_delay`    | 1-2 weeks          | Matches TLP epoch (months)  |
| Routing            | Yes                | No (private, off-graph)     |
| Liquidity          | Active             | Static (inheritance amount) |
| Counterparty       | Any LN node        | The heir                    |

The long `to_self_delay` (months) is a feature, not a constraint. It
aligns the punishment window with the TLP epoch, giving the heir ample
time to detect and respond to fraudulent closure — even a completely
passive heir checking the chain once a month catches fraud. Traditional
inheritance bureaucracy routinely takes longer.

### Rotation (Dead-Man's Switch)

Each epoch (e.g., one month), the testator:

1. Moves the inheritance stash to a new address (rotation).
2. Constructs a new commitment transaction in the channel with the heir.
3. Revokes the previous epoch's commitment (standard LN revocation).
4. The new commitment includes a TLP-gated spending path for the heir.

When the testator dies or becomes incapacitated, rotation stops. The
heir notices the silence (no new rotation arrived), begins solving the
most recent epoch's TLP, and claims the funds via channel closure after
the computation completes.

The heir **can** solve the current TLP at any time but **doesn't have
to**. While the testator is alive and well, the presumed likelihood of
death in a given epoch is low, so the heir continuously solving TLP in
the background 'just in case' might not be worth it. If the heir
starts solving when rotation stops, the cost is one full epoch of
computation before the inheritance is accessible.

### Stash Adjustment

The testator can change the inheritance amount at any time via standard
LN splice operations (splice-in to increase, splice-out to decrease).
The channel stays open — no close/reopen cycle needed. The next
rotation simply commits to the new balance. The heir's side of the
channel holds zero (or near-zero) balance; only the testator controls
the funded side.

### Fee Management at Claim Time

The heir broadcasts the closing transaction after the testator is dead,
so the heir controls the fee at broadcast time. Two standard LN
mechanisms apply:

- **Anchor outputs.** The commitment transaction is signed with a
  minimal fee. The heir attaches a CPFP (Child Pays For Parent) child
  transaction with whatever fee the current mempool demands.
- **SIGHASH_ANYONECANPAY.** The commitment can be signed so the heir
  can add their own inputs to cover higher fees without pre-coordination
  with the (now dead) testator.

The testator does not need to guess future fee rates. The heir adjusts
at claim time, whether that is next month or twenty years from now.
This also applies to cascading fallbacks — each heir sets their own fee
independently.

### Channel Lockscript Structure

Each commitment transaction includes a tiered spending path:

```
Path 1: Heir claims with TLP_heir solution + heir_key
         (normal inheritance — heir is alive)
Path 2: After grace period G, funds go to heir_fallback_addr
         (heir is also dead — cascade to heir's heirs)
```

Path 1 is the normal case. Path 2 handles cascading death (see below).

### Stateless Key Derivation

Both sides' channel keys are deterministically derived from their
respective GW master secrets (seed + derivation path + epoch number).
This means:

- **Testator** can reconstruct their channel key from memory alone
  (GW recall + Argon2 + derivation).
- **Heir** can reconstruct their channel key from memory alone.
- **Channel state** is derivable from epoch number + both keys.
- No files, no backups, no hardware dependency.

The channel is a deterministic function of two GW secrets + epoch
counter. The only state is on-chain (public and permanent by design).

### Opaque Fallback Addresses (Cascading Inheritance)

A testator (A) may have multiple heirs (B, E, F), each with their own
channel. Each heir may in turn have their own heirs. If A and B die
simultaneously, A's inheritance to B must reach B's heirs (C, D)
according to B's will.

#### The problem

Baking B's heirs' keys directly into A's lockscript would couple A to
B's estate planning. A shouldn't need to know B's heirs, their
proportions, or when B changes their will.

#### The solution

Each rotation, B hands A a single **opaque fallback address** — a
taproot output that internally encodes B's current will. A doesn't
know or care what's inside. A's lockscript just says:

```
Path 1: B claims with TLP_B + B_key           (B alive)
Path 2: After grace G, funds go to B_fallback  (B dead)
```

Inside `B_fallback`, B has pre-committed a taproot tree encoding B's
own will:

```
B_fallback (taproot tree):
  Leaf 1: C claims 60% with TLP_C + C_key
  Leaf 2: After G', C's 60% goes to C_fallback   (C also dead)
  Leaf 3: D claims 40% with TLP_D + D_key
  Leaf 4: After G'', D's 40% goes to D_fallback  (D also dead)
```

C and D each provide B with their own opaque fallback addresses,
which B includes in the taproot tree. The pattern is recursive —
C_fallback and D_fallback can themselves contain further cascades.

#### Properties

- **Decoupled.** A sees one opaque address from B per rotation. B
  sees one opaque address from each of C and D. No participant ever
  needs to know more than one level down.
- **Updateable.** Every rotation is a new commitment. B provides a
  new fallback address each time, reflecting any changes to B's will
  (new heirs, changed proportions, removed heirs). A doesn't notice.
- **Independent.** Each heir has their own spending leaf gated by
  their own TLP. No cooperation between co-heirs needed. C claims
  C's portion, D claims D's portion.
- **On-chain enforced.** The split is baked into the taproot script
  tree. No trust between co-heirs required.
- **Stateless.** B derives the taproot tree deterministically from:
  B's GW secret + heir public keys + will parameters + epoch number.

#### Example: simultaneous death of A, B, and C

```
A has heir B (100%).
B has heirs C (60%) and D (40%).
C has heirs E (70%) and F (30%).

A, B, and C all die in the same epoch.

Month 1:  One epoch passes (TLP_B solvable). B is dead.
          Grace period G begins.
Month 2:  G expires. Funds go to B_fallback.
          B_fallback splits: 60% to C's leaf, 40% to D's leaf.
Month 3:  D solves TLP_D, claims 40%. Done for D.
          C's TLP_C is solvable. C is dead. Grace period G' begins.
Month 4:  G' expires. C's 60% goes to C_fallback.
          C_fallback splits: 70% to E's leaf, 30% to F's leaf.
Month 5:  E solves TLP_E, claims 70% of C's 60% (= 42% of total).
          F solves TLP_F, claims 30% of C's 60% (= 18% of total).
```

Worst-case delay for an N-level cascade where everyone dies
simultaneously: roughly `N * (TLP_epoch + grace_period)`. For a
4-level cascade with 1-month epochs and 1-month grace periods, the
deepest heir waits about 8 months. Faster than multi-jurisdictional
probate, no lawyers, no courts, fully self-custodial.

---

## License

The Great Wall ecosystem is dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))
- MIT License ([LICENSE-MIT](./LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the
Apache-2.0 license, shall be dual-licensed as above, without any
additional terms or conditions.
