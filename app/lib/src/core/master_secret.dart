import 'dart:typed_data';

import '../ffi/core_bindings.dart' show FixedRect;

/// One point stage's contribution to the **master-secret export transcript**:
/// its perturbation reservoirs `(o, p, q)` and the raw I4F60 centre of its
/// encoded point's leaf rectangle.
///
/// Under the chained protocol every non-0 stage carries exactly one of these.
/// They are an exact, order-preserving function of the setup so far, so the
/// transcript reproduces bit-for-bit on recovery (DESIGN.md §"Master-Secret
/// Export").
///
/// SECURITY: `(o, p, q)` and the leaf centre are coercion-relevant
/// (SCOPE.md "no logs of fractal coordinates / (o,p,q)"). The redacted
/// [toString] keeps them out of logs; they live only as ephemeral session
/// state.
class StageRecord {
  const StageRecord({
    required this.o,
    required this.p,
    required this.q,
    required this.leafReRaw,
    required this.leafImRaw,
  });

  /// This stage's perturbation reservoirs (raw `u64`, stored in Dart's signed
  /// 64-bit `int` — the bit pattern is what the transcript serialises).
  final int o;
  final int p;
  final int q;

  /// Raw I4F60 `i64` centre of the encoded point's leaf rectangle.
  final int leafReRaw;
  final int leafImRaw;

  @override
  String toString() => 'StageRecord(<redacted>)';
}

/// Builds and renders the **master-secret export** (protocol 0.3.0): a single
/// Argon2id pass over the reproducible setup transcript, replacing the `0.2.0`
/// `SHA512(seedphrase ‖ text)` carry-over.
///
/// This class owns only the **pure** parts — the transcript byte layout and the
/// default display formatting — so they are unit-testable without the engine.
/// The Argon2id pass itself (fixed salt `b"greatwall"`, `m = 64 MiB`, `t = 8`,
/// `p = 2`) lives in great-wall-core and is reached through
/// [GreatWallCore.argon2idMaster] / `bs_argon2id_master`.
///
/// Faithful port of great-wall-core's `burning_ship/protocol.py`
/// (`build_export_transcript` / `master_secret_display`): same field order,
/// same big-endian widths, same length prefixes — so an export produced here is
/// byte-identical to the standalone for the same setup.
class MasterSecret {
  MasterSecret._();

  /// Conventional default view: the first 32 hex characters of the Argon2id
  /// output (`MASTER_DISPLAY_CHARS`). The full 1024-byte output behind advanced
  /// options is a deferred TODO (DESIGN.md §"Output-size ergonomics").
  static const int displayChars = 32;

  /// The Argon2id output length `l` the protocol uses
  /// (`ARGON2ID_MASTER_OUTPUT_BYTES`). Excess output is ignored by the consumer.
  static const int outputBytes = 1024;

  /// The raw `(re, im)` I4F60 centre of a leaf [rect].
  ///
  /// Mirrors `_leaf_center_raw` / `_midpoint` in protocol.py — Rust's
  /// `Fixed::midpoint`: `(a >> 1) + (b >> 1) + (a & b & 1)`, an overflow-safe
  /// average of the two bounds.
  static ({int re, int im}) leafCentreRaw(FixedRect rect) => (
        re: _midpoint(rect.reMin, rect.reMax),
        im: _midpoint(rect.imMin, rect.imMax),
      );

  static int _midpoint(int a, int b) => (a >> 1) + (b >> 1) + (a & b & 1);

  /// Serialise the reproducible setup transcript for the master-secret export.
  ///
  /// Byte layout (big-endian; mirrors `build_export_transcript`):
  ///
  /// ```
  /// u16 len ‖ stage-0 text bytes (ASCII [A-Z0-9-])
  /// u32 iterations
  /// for each stage record (stages 1..k, in order):
  ///     u64 o ‖ u64 p ‖ u64 q
  ///     i64 leaf_centre_re ‖ i64 leaf_centre_im
  /// u16 len ‖ export-label bytes (ASCII [A-Z0-9-])
  /// ```
  ///
  /// [stage0Text] and [exportLabel] MUST already be canonicalised to the
  /// `[A-Z0-9-]` set (the engine's `bs_salt_pepper_canonicalize`); the
  /// restriction guarantees they are pure ASCII, so `codeUnits` are their
  /// transcript bytes. Length prefixes keep the message unambiguous so it
  /// reproduces bit-for-bit on recovery.
  static Uint8List buildExportTranscript({
    required String stage0Text,
    required int iterations,
    required List<StageRecord> records,
    required String exportLabel,
  }) {
    final BytesBuilder out = BytesBuilder();
    _writeText(out, stage0Text);
    _writeU32(out, iterations);
    for (final StageRecord r in records) {
      _write64(out, r.o);
      _write64(out, r.p);
      _write64(out, r.q);
      _write64(out, r.leafReRaw);
      _write64(out, r.leafImRaw);
    }
    _writeText(out, exportLabel);
    return out.toBytes();
  }

  /// The conventional default view of an Argon2id master-secret [raw] output:
  /// its first [displayChars] hex characters (mirrors `master_secret_display`).
  static String displayHex(Uint8List raw) {
    final int nBytes = (displayChars + 1) ~/ 2; // 2 hex chars per byte
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < nBytes && i < raw.length; i++) {
      sb.write(raw[i].toRadixString(16).padLeft(2, '0'));
    }
    final String hex = sb.toString();
    return hex.length > displayChars ? hex.substring(0, displayChars) : hex;
  }

  static void _writeText(BytesBuilder out, String text) {
    // Canonical [A-Z0-9-] is pure ASCII, so the code units are the bytes.
    final List<int> bytes = text.codeUnits;
    _writeU16(out, bytes.length);
    out.add(bytes);
  }

  static void _writeU16(BytesBuilder out, int v) {
    out.add((ByteData(2)..setUint16(0, v & 0xFFFF, Endian.big)).buffer
        .asUint8List());
  }

  static void _writeU32(BytesBuilder out, int v) {
    out.add((ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.big)).buffer
        .asUint8List());
  }

  /// Write a 64-bit value big-endian. Used for both the `u64` reservoirs and the
  /// `i64` leaf centres: the big-endian byte image of a 64-bit pattern is the
  /// same whether read as signed or unsigned, so [ByteData.setInt64] (which
  /// accepts Dart's full signed-`int` range) reproduces `struct.pack(">Q"/">q")`
  /// exactly for the same bits.
  static void _write64(BytesBuilder out, int v) {
    out.add((ByteData(8)..setInt64(0, v, Endian.big)).buffer.asUint8List());
  }
}
