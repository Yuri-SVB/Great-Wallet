# Great Wallet

**Remember your Bitcoin — carry nothing.**

Great Wallet is a self-custody Bitcoin wallet whose seed lives only in
your memory, protected by a fractal that is easy for *you* to recall
and prohibitively expensive for anyone else to search. Nothing to
steal, nothing to seize, nothing to lose in a fire.

> It's all in your head, in nobody else's, the attacker is aware of
> that, and is nevertheless unable to rob it.

---

## The four properties

Great Wallet gives you four guarantees at the same time:

1. **Knowledge-Based Authentication.** Your secret lives entirely in
   your memory. No device, physical vault, or geographic location is
   required to access your funds.
2. **Individual Custody.** You depend on no one else. The core
   premise of Bitcoin — full self-custody — is kept intact.
3. **Non-Obscurity.** The method is public. It does not rely on
   hiding how it works, and it does not rely on convincing an
   attacker that your stash doesn't exist or is smaller than it is.
4. **Coercion-Resistance.** Threats and violence cannot extract the
   secret, because the knowledge that unlocks it is *tacit* (cannot
   be verbalized on demand) and the mechanism that deploys it is
   gated by an inescapably lengthy computation.

---

## How you use it

Great Wallet has four modes that flow naturally into one another:

1. **Setup** — encode a fresh Bitcoin seed onto a fractal you will
   learn to remember.
2. **Train** — spaced-repetition practice that turns the encoding
   into reliable tacit recall.
3. **Accelerate** *(optional)* — outsource the waiting-time part of
   the computation over Lightning Network, anonymously, whenever you
   need faster access.
4. **Inherit** *(optional)* — configure a dead-man's-switch channel
   so your heirs can receive your funds if you can no longer unlock
   them yourself.

Setup and Train are the core flow. Accelerate and Inherit are opt-in
and can be added later.

---

## Status

The fractal encoder engine (`great-wall-core`) is public and in
**beta**. The rest of the ecosystem — training, Lightning
integration, inheritance protocol, and the unified app — is under
active development and not yet public.

---

## Learn more

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — repository structure,
  cryptographic design, security model, and the inheritance protocol.
  Written for collaborators and auditors.

---

## License

Great Wallet is dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](./LICENSE-APACHE))
- MIT License ([LICENSE-MIT](./LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the
Apache-2.0 license, shall be dual-licensed as above, without any
additional terms or conditions.
