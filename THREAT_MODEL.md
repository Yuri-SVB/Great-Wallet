# Great Wall Ecosystem — Threat Model (Draft)

This document records the security assumptions under which the Great
Wall ecosystem operates. The concrete threat-to-mitigation mapping
lives in [ARCHITECTURE.md § Security Model
Summary](./ARCHITECTURE.md#security-model-summary); this document
states what makes those mitigations hold, and what lies outside the
current release's scope.

Status: **first draft**. Parameters, framing, and wording are
expected to evolve alongside the protocol.

---

## Attacker Capabilities (Assumed)

The attacker:

- has full knowledge of the protocol, all source code, the user's
  setup choices, and every in-scope parameter (non-obscurity — one of
  the Four Properties);
- can seize any user device and read all state on it (vault blobs,
  TLP blobs, commitment scripts, SM-2 schedules);
- has unbounded compute within their effective wall-clock custody
  window (see [*Calibrating Argon2
  duration*](./ARCHITECTURE.md#calibrating-argon2-duration)),
  including the ability to hire `jade-clock` solvers;
- runs full Bitcoin and Lightning Network nodes, monitors the chain,
  and can participate in routing;
- may coerce users or heirs physically, for durations bounded by the
  wrench-attack incidents compiled in
  [jlopp/physical-bitcoin-attacks](https://github.com/jlopp/physical-bitcoin-attacks/).

## Trust Base (What Is Assumed Hard)

| Primitive / property                                 | Relied on for                           |
|------------------------------------------------------|------------------------------------------|
| Bitcoin consensus, PoW, secp256k1 signatures         | All on-chain settlement and key pairs    |
| RSA-2048 factoring hardness                          | RSW TLP (training vault, inheritance)    |
| Argon2 at the configured parameters                  | Stage-2 fractal derivation gating        |
| AES / HMAC-SHA512 at textbook strength               | Vault and TLP ciphertext                 |
| Bit-exact `great-wall-core` implementation (Rust, I4F60) | Stage-1 / stage-2 bijection          |
| Standard LN commitment-update + revocation semantics | Dead-man's-switch inheritance channel    |
| Tacit knowledge is non-transmissible (TKBA premise)  | Coercion-resistance (property 4)         |

## Out of Scope (This Release)

- **Adversarial-agent scenarios.** Testator / heir mutual distrust,
  or third parties maliciously interfering with rotation, require
  stronger monitoring and dispute machinery than this release
  targets. Future iterations may address.
- **Quantum adversaries.** Breaking secp256k1 or RSA-2048 factoring
  via quantum computation is not defended against directly. The
  inheritance path has a post-quantum escape hatch documented in
  [*TLP Enforcement*](./ARCHITECTURE.md#tlp-enforcement-off-chain-key-wrapping).
- **Device side-channels during active recall.** Timing, EM,
  acoustic, and similar attacks on the user's device while tacit
  recall is happening.
- **Long-horizon cryptographic erosion.** Century-plus hardness of
  RSA-2048 factoring and of Argon2 parameters against future
  hardware is not guaranteed.
- **Mass on-chain correlation attacks.** Beyond the privacy afforded
  by standard taproot outputs and private (non-routing) LN channels.

---

## Cross-Reference

See [ARCHITECTURE.md § Security Model
Summary](./ARCHITECTURE.md#security-model-summary) for the concrete
threat-to-mitigation table.
