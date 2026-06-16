/// I4F60 fixed-point conversions.
///
/// great-wall-core's determinism-critical engine represents coordinates as a
/// 64-bit signed fixed-point type, **I4F60** — 1 sign bit + 3 integer bits +
/// 60 fractional bits, covering `[-8, +8)` with uniform precision `2^-60`
/// (great-wall-docs/great-wallet/ARCHITECTURE.md §"Determinism guarantees").
///
/// Every coordinate that crosses the FFI for an encode/decode call is passed
/// as a **raw `i64`** (the bit pattern of the fixed-point value), never as a
/// float — exactly as the Python reference bridge does
/// (great-wall-core/burning_ship/burning_ship_engine.py: `fixed_from_f64`).
/// Passing floats would let platform rounding drift the bijection.
library;

/// Number of fractional bits in the engine's fixed-point type.
///
/// This is `60` for I4F60. It is also queryable at runtime from the engine via
/// [GreatWallCoreBindings.precision]; the two are asserted to agree at startup
/// so a future engine layout change is caught loudly rather than silently
/// corrupting coordinates.
const int kFracBits = 60;

/// The scale factor `2^kFracBits`. Multiplying a real value by this and
/// rounding yields the raw `i64`.
const int kFixedOne = 1 << kFracBits;

/// Convert a real value to its raw I4F60 `i64` representation.
///
/// Mirrors `fixed_from_f64` in the Python bridge: `int(v * 2^FRAC_BITS)`.
/// Dart `int` is 64-bit on the native (desktop/mobile) targets this app
/// supports, so the product fits without loss for the `[-8, +8)` domain.
int fixedFromDouble(double v) => (v * kFixedOne).round();

/// Convert a raw I4F60 `i64` back to a real value. For display/logging-free
/// arithmetic only — never feed a round-tripped float back into an encode.
double fixedToDouble(int raw) => raw / kFixedOne;
